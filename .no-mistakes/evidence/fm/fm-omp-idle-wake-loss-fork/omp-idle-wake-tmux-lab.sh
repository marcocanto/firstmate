#!/usr/bin/env bash
# Test-phase live driver: the idle case of tests/fm-omp-interrupt-live-e2e.test.sh
# adapted to a private tmux socket, because bin/fm-herdr-lab.sh provision
# refuses on this host (its fleet-state tripwire needs a running default Herdr
# session, and the live default session must not be touched).
# Usage: omp-idle-wake-tmux-lab.sh <worktree> <new|base> [idle-secs]
#   new   the extension at the worktree's HEAD
#   base  the extension at the base commit fc52ee99 (the pre-fix behavior)
set -u
ROOT=$1 VARIANT=$2 IDLE=${3:-190}
MODEL=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6-astra}
OMP_BIN=$(command -v omp)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-idlewake-$VARIANT.XXXXXX")
HOME_ROOT="$LAB/root"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX NO_MISTAKES_GATE FM_TASK_ID FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
mkdir -p "$TMUX_TMPDIR"
T=lab:0.0
WHO="omp $("$OMP_BIN" --version | head -1) ($MODEL) via tmux, extension=$VARIANT"
. "$ROOT/bin/fm-composer-lib.sh"

cleanup() { tmux kill-server 2>/dev/null; sleep 1; pkill -f "$LAB" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$1"; printf '# pane:\n'; screen | tail -25 | sed 's/^/#   /'; printf '# probe log:\n'; sed 's/^/#   /' "$HOME_ROOT/state/.lab-probe.log" 2>/dev/null; exit 1; }
note() { printf '# [%s] %s\n' "$(date -u +%H:%M:%S)" "$1"; }
screen() { tmux capture-pane -p -t "$T" 2>/dev/null; }
busy() { screen | grep -Eq "$FM_DELIVERY_OMP_BUSY_REGEX_DEFAULT"; }
settled_idle() { ! busy && sleep 2 && ! busy; }
type_line() { tmux send-keys -t "$T" -l "$1"; sleep 0.5; tmux send-keys -t "$T" Enter; }
wait_until() { local limit=$1 i=0; shift; while [ "$i" -lt "$limit" ]; do "$@" && return 0; sleep 1; i=$((i+1)); done; return 1; }
queue_rows() { [ -s "$HOME_ROOT/state/.wake-queue" ] && wc -l < "$HOME_ROOT/state/.wake-queue" | tr -d ' ' || printf 0; }
queue_drained() { [ "$(queue_rows)" = 0 ]; }
watcher_live() { local pid; pid=$(cat "$HOME_ROOT/state/.watch.lock/pid" 2>/dev/null) || return 1; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
reply_seen() { screen | grep -Eq "^[^[:alnum:]]*$1[[:space:]]*\$"; }
probe_state() { cat "$HOME_ROOT/state/.lab-probe.json" 2>/dev/null || echo 'no probe snapshot'; }
probe_log() { cat "$HOME_ROOT/state/.lab-probe.log" 2>/dev/null; }
advisor_note_idle() { [ "$(probe_state)" = 'idle=true last=custom_message/advisor' ]; }
wake_started() { probe_log | grep -q '^wake '; }
closes_seen() { local n; n=$(grep -c 'labtask.status' "$HOME_ROOT/state/.watch-deliveries.log" 2>/dev/null); printf '%s' "${n:-0}"; }
closes_above() { [ "$(closes_seen)" -gt "$1" ]; }
long_reply_seen() { probe_log | grep -q '^reply .*LONGTURN-DONE'; }
midrun_order() {
  probe_log | awk '/^user Use the bash tool/ { p = NR } p && !r && /^reply .*LONGTURN-DONE/ { r = NR }
    /^wake / { if (p && !r) early = 1; else if (r) late = 1 }
    END { print early ? "early" : late ? "ok" : "pending" }'
}
midrun_settled() { [ "$(midrun_order)" != pending ]; }

# Second-mate home from the worktree's tracked files, as the Herdr guard builds it.
mkdir -p "$HOME_ROOT"
git -C "$ROOT" ls-files -z --cached | (cd "$ROOT" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$HOME_ROOT"
[ "$VARIANT" = base ] && git -C "$ROOT" show fc52ee990304a5060b980d75992c2271ff557654:.omp/extensions/fm-primary-omp-watch.ts > "$HOME_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
printf 'labmate\n' > "$HOME_ROOT/.fm-secondmate-home"
mkdir -p "$HOME_ROOT/state" "$HOME_ROOT/config" "$HOME_ROOT/data"
# Same lab-only advisor-note probe the Herdr guard installs (copied from install_idle_probe).
printf 'advisor:\n  enabled: false\n' >> "$HOME_ROOT/.omp/fm-worker-overlay.yml"
sed -n '/^install_idle_probe()/,/^TS$/p' "$ROOT/tests/fm-omp-interrupt-live-e2e.test.sh" | sed -n "/<<'TS'/,/^TS\$/p" | sed '1d;$d' > "$HOME_ROOT/.omp/extensions/fm-lab-idle-probe.ts"
[ -s "$HOME_ROOT/.omp/extensions/fm-lab-idle-probe.ts" ] || fail "could not install the probe"

tmux new-session -d -s lab -x 160 -y 50 -c "$HOME_ROOT" \
  "env -u CLAUDECODE -u OMPCODE -u FM_TASK_ID GIT_CEILING_DIRECTORIES='$LAB' FM_HOME='$HOME_ROOT' FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 FM_OMP_INTERRUPT_SETTLE_MS=8000 '$OMP_BIN' --config '$HOME_ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$HOME_ROOT' --no-session --model '$MODEL' --thinking low" \
  || fail "could not start omp"
note "$WHO launched in $LAB"
sleep 8
type_line 'Reply with exactly LAB-READY and nothing else. Do not run any tool.'
wait_until 120 reply_seen LAB-READY || fail "first turn never replied"
wait_until 120 settled_idle || fail "never idle after first turn"
watcher_live || type_line '/fm-watch-arm-omp'
wait_until 60 watcher_live || fail "watcher never armed"
wait_until 120 settled_idle || fail "never idle after arming"
note "watcher armed (pid $(cat "$HOME_ROOT/state/.watch.lock/pid"))"
: > "$HOME_ROOT/state/.lab-advisor-note"
type_line 'Reply with exactly NOTE-READY and nothing else. Do not run any tool.'
wait_until 120 reply_seen NOTE-READY || fail "note turn never replied"
wait_until 60 advisor_note_idle || fail "never settled idle behind the advisor note ($(probe_state))"
note "idle precondition held: $(probe_state); idling ${IDLE}s"
sleep "$IDLE"
advisor_note_idle || fail "left the advisor-note idle state during the idle stretch ($(probe_state))"
wake_started && fail "a wake started before one was sent"
: > "$HOME_ROOT/state/labtask.meta"
printf 'done: lab idle wake\n' >> "$HOME_ROOT/state/labtask.status"
start=$(date +%s)
wait_until 30 closes_above 0 || fail "watcher never closed on the idle wake"
note "watcher closed on the idle wake; durable rows=$(queue_rows)"
if ! wait_until 60 wake_started; then
  note "after 60s: rows=$(queue_rows) $(probe_state)"
  screen | tail -12 | sed 's/^/#   /'
  fail "$WHO: after ${IDLE}s idle behind an advisor note, the wake started no turn within 60s ($(queue_rows) durable rows, $(probe_state))"
fi
note "idle wake started a turn $(( $(date +%s) - start ))s after its status line"
wait_until 300 queue_drained || fail "idle wake's queue never drained ($(queue_rows) rows)"
wait_until 180 settled_idle || fail "never idle after the idle wake"
note "durable queue drained; omp idle"
closes=$(closes_seen)
type_line 'Use the bash tool to run exactly this command and nothing else: sleep 40 ; echo LONGTURN-SLEPT . After it returns, reply with exactly LONGTURN-DONE and nothing else.'
wait_until 60 busy || fail "long turn never showed busy"
printf 'done: lab mid-run wake\n' >> "$HOME_ROOT/state/labtask.status"
wait_until 30 closes_above "$closes" || fail "watcher never closed on the mid-run wake"
long_reply_seen && fail "long turn replied before the mid-run wake closed"
note "mid-run wake closed while omp was busy"
wait_until 150 midrun_settled || fail "neither final reply nor a later wake arrived"
[ "$(midrun_order)" = ok ] || fail "a mid-run wake interrupted the run (order=$(midrun_order))"
wait_until 300 queue_drained || fail "mid-run wake queue never drained ($(queue_rows) rows)"
wait_until 180 settled_idle || fail "never idle after the mid-run wake"
note "probe log (message order):"
probe_log | sed 's/^/#   /'
printf '# final pane:\n'; screen | grep -v '^\s*$' | tail -20 | sed 's/^/#   /'
type_line '/quit'
printf 'ok - %s: wake started a turn after %ss idle behind an advisor note; mid-run wake followed the run final reply; queue drained with no key\n' "$WHO" "$IDLE"
