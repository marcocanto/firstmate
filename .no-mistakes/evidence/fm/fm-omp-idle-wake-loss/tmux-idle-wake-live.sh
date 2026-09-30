#!/usr/bin/env bash
# Tmux-socket port of the idle case of tests/fm-omp-interrupt-live-e2e.test.sh
# (Herdr lab unavailable: its tripwire needs a running default session).
# Usage: tmux-idle-wake-live.sh <worktree> [extension-rev]  (rev overrides the watch extension, for a pre-fix control)
set -u
ROOT=$1; EXT_REV=${2:-}
EV=$(cd "$(dirname "$0")" && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
export TMUX_TMPDIR="$LAB/tmux"; mkdir -p "$TMUX_TMPDIR"
T() { tmux -L fm-lab "$@"; }
. "$ROOT/bin/fm-composer-lib.sh"
MODEL=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6-astra}
IDLE_SECS=${IDLE_SECS:-190}
OMP_BIN=$(command -v omp); WHO="omp $($OMP_BIN --version | head -1) ($MODEL) via tmux lab"
cleanup() { T kill-server 2>/dev/null; for p in $(ps -axo pid=,command= | awk -v l="$LAB" 'index($0,l){print $1}'); do kill -TERM $p 2>/dev/null; done; rm -rf "$LAB"; }
trap cleanup EXIT
fail() { echo "not ok - $1"; echo "# pane:"; T capture-pane -p -t primary -S -40 | sed 's/^/#   /'; echo "# probe log:"; sed 's/^/#   /' "$H/state/.lab-probe.log" 2>/dev/null; exit 1; }
note() { echo "# $1"; }
H="$LAB/idle/root"; mkdir -p "$H"
git -C "$ROOT" ls-files -z --cached | (cd "$ROOT" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$H"
[ -n "$EXT_REV" ] && git -C "$ROOT" show "$EXT_REV:.omp/extensions/fm-primary-omp-watch.ts" > "$H/.omp/extensions/fm-primary-omp-watch.ts"
printf 'labmate\n' > "$H/.fm-secondmate-home"; mkdir -p "$H/state" "$H/config" "$H/data"
printf 'advisor:\n  enabled: false\n' >> "$H/.omp/fm-worker-overlay.yml"
cp "$EV/fm-lab-idle-probe.ts" "$H/.omp/extensions/fm-lab-idle-probe.ts"
screen() { T capture-pane -p -t primary 2>/dev/null; }
busy() { screen | grep -Eq "$FM_DELIVERY_OMP_BUSY_REGEX_DEFAULT"; }
settled_idle() { ! busy && sleep 2 && ! busy; }
type_line() { T send-keys -t primary -l "$1"; sleep 0.5; T send-keys -t primary Enter; }
wait_until() { local l=$1 i=0; shift; while [ $i -lt $l ]; do "$@" && return 0; sleep 1; i=$((i+1)); done; return 1; }
reply_seen() { screen | grep -Eq "^[^[:alnum:]]*$1[[:space:]]*\$"; }
watcher_live() { local p; p=$(cat "$H/state/.watch.lock/pid" 2>/dev/null) || return 1; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
queue_rows() { [ -s "$H/state/.wake-queue" ] && wc -l < "$H/state/.wake-queue" | tr -d ' ' || printf 0; }
queue_drained() { [ "$(queue_rows)" = 0 ]; }
probe_state() { cat "$H/state/.lab-probe.json" 2>/dev/null || echo none; }
probe_log() { cat "$H/state/.lab-probe.log" 2>/dev/null; }
advisor_note_idle() { [ "$(probe_state)" = 'idle=true last=custom_message/advisor' ]; }
wake_started() { probe_log | grep -q '^wake '; }
closes_seen() { local n; n=$(grep -c 'labtask.status' "$H/state/.watch-deliveries.log" 2>/dev/null); printf '%s' "${n:-0}"; }
closes_above() { [ "$(closes_seen)" -gt "$1" ]; }
long_reply_seen() { probe_log | grep -q '^reply .*LONGTURN-DONE'; }
midrun_order() { probe_log | awk '/^user Use the bash tool/ { p = NR } p && !r && /^reply .*LONGTURN-DONE/ { r = NR } /^wake / { if (p && !r) early = 1; else if (r) late = 1 } END { print early ? "early" : late ? "ok" : "pending" }'; }
midrun_settled() { [ "$(midrun_order)" != pending ]; }

T new-session -d -s primary -x 160 -y 50 -c "$H" "env -u NO_MISTAKES_GATE -u CLAUDECODE -u FM_TASK_ID -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE GIT_CEILING_DIRECTORIES='$LAB' FM_HOME='$H' FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 '$OMP_BIN' --config '$H/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$H' --no-session --model '$MODEL' --thinking low"
note "extension: ${EXT_REV:-worktree HEAD}; $WHO"
sleep 8
type_line 'Reply with exactly LAB-READY and nothing else. Do not run any tool.'
wait_until 120 test -e "$H/state/.lock" || fail "native session start never took the lab lock"
wait_until 120 reply_seen LAB-READY || fail "first turn never replied"
wait_until 120 settled_idle || fail "never idle after first turn"
watcher_live || type_line '/fm-watch-arm-omp'
wait_until 60 watcher_live || fail "watcher never armed"
wait_until 120 settled_idle || fail "never idle after arming"
: > "$H/state/.lab-advisor-note"
type_line 'Reply with exactly NOTE-READY and nothing else. Do not run any tool.'
wait_until 120 reply_seen NOTE-READY || fail "NOTE-READY turn never replied"
wait_until 60 advisor_note_idle || fail "precondition: omp did not settle idle behind the advisor note ($(probe_state))"
note "idle precondition held: $(probe_state)"
sleep "$IDLE_SECS"
advisor_note_idle || fail "left advisor-note idle state during ${IDLE_SECS}s ($(probe_state))"
wake_started && fail "a wake started before one was sent"
: > "$H/state/labtask.meta"; printf 'done: lab idle wake\n' >> "$H/state/labtask.status"
start=$(date +%s)
wait_until 30 closes_above 0 || fail "watcher never closed on the idle wake"
wait_until 60 wake_started || fail "$WHO: after ${IDLE_SECS}s idle behind an advisor note, the wake started no turn within 60s ($(queue_rows) durable rows, $(probe_state)); omp is holding an idle wake until someone types"
note "idle wake started a turn $(( $(date +%s) - start ))s after its status line"
wait_until 300 queue_drained || fail "idle wake queue never drained ($(queue_rows) rows)"
wait_until 180 settled_idle || fail "never idle after idle wake"
echo "ok - idle wake: $WHO started a turn for a wake after ${IDLE_SECS}s idle behind an advisor note; durable queue drained"
closes=$(closes_seen)
type_line 'Use the bash tool to run exactly this command and nothing else: sleep 40 ; echo LONGTURN-SLEPT . After it returns, reply with exactly LONGTURN-DONE and nothing else.'
wait_until 60 busy || fail "long turn never showed busy"
printf 'done: lab mid-run wake\n' >> "$H/state/labtask.status"
wait_until 30 closes_above "$closes" || fail "watcher never closed on mid-run wake"
long_reply_seen && fail "long turn replied before mid-run wake closed"
wait_until 150 midrun_settled || fail "neither final reply nor later wake arrived"
[ "$(midrun_order)" = ok ] || fail "a mid-run wake interrupted the run"
wait_until 300 queue_drained || fail "mid-run queue never drained"
echo "ok - mid-run wake: $WHO held a wake closing during a busy tool turn until the run's final reply, then delivered it; durable queue drained"
echo "# final probe log:"; probe_log | sed 's/^/#   /'
echo "# final pane:"; screen | sed 's/^/#   /'
type_line '/quit'
