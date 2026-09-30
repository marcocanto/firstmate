#!/usr/bin/env bash
# Live tmux-lab driver for the omp idle-wake-behind-advisor-note scenario.
# Usage: idle-wake-tmux-lab.sh <label> <git-rev-for-home>
# Mirrors run_idle_case in tests/fm-omp-interrupt-live-e2e.test.sh, but runs a
# real omp second mate on a private fm-lab tmux socket in a marked lab home.
set -u
LABEL=$1 REV=$2
WT=<worktree>
MODEL=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6-astra}
IDLE=${IDLE_SECS:-190}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
TD="$LAB/tmux"; mkdir -p "$TD"
T() { env -u TMUX TMUX_TMPDIR="$TD" tmux -L fm-lab "$@"; }
say() { printf '[%s %s] %s\n' "$(date -u +%H:%M:%S)" "$LABEL" "$*"; }
cleanup() { T kill-server 2>/dev/null; for p in $(ps -axo pid=,command= | awk -v l="$LAB" 'index($0,l){print $1}'); do kill "$p" 2>/dev/null; done; rm -rf "$LAB"; }
trap cleanup EXIT
H=$LAB
git -C "$WT" archive "$REV" | tar -xf - -C "$H"
printf 'labmate\n' > "$H/.fm-secondmate-home"
printf 'advisor:\n  enabled: false\n' >> "$H/.omp/fm-worker-overlay.yml"
# Probe extension copied verbatim from the live test's install_idle_probe.
awk '/cat > "\$HOME_ROOT\/.omp\/extensions\/fm-lab-idle-probe.ts" <<.TS./{f=1;next} /^TS$/{f=0} f' "$WT/tests/fm-omp-interrupt-live-e2e.test.sh" > "$H/.omp/extensions/fm-lab-idle-probe.ts"
[ -s "$H/.omp/extensions/fm-lab-idle-probe.ts" ] || { say "probe extract failed"; exit 1; }
say "home $H from $REV; omp $(omp --version); model $MODEL"
T new-session -d -s primary -x 200 -y 50 -c "$H" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE -u FM_TASK_ID GIT_CEILING_DIRECTORIES='$LAB' FM_HOME='$H' FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 omp --config '$H/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$H' --no-session --model '$MODEL' --thinking low"
screen() { T capture-pane -p -t primary -S -200 2>/dev/null; }
typ() { T send-keys -t primary -l "$1"; sleep 0.5; T send-keys -t primary Enter; }
wu() { local l=$1 i=0; shift; while [ $i -lt $l ]; do "$@" && return 0; sleep 1; i=$((i+1)); done; return 1; }
probe() { cat "$H/state/.lab-probe.json" 2>/dev/null || echo none; }
plog() { cat "$H/state/.lab-probe.log" 2>/dev/null; }
rows() { [ -s "$H/state/.wake-queue" ] && wc -l < "$H/state/.wake-queue" | tr -d ' ' || echo 0; }
wlive() { local p; p=$(cat "$H/state/.watch.lock/pid" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
reply() { plog | grep -q "^reply .*$1"; }
idle_note() { [ "$(probe)" = 'idle=true last=custom_message/advisor' ]; }
idle_any() { probe | grep -q '^idle=true'; }
fin() { say "FINAL probe: $(probe); queue rows: $(rows)"; say "probe log:"; plog | sed 's/^/    /'; say "pane tail:"; screen | grep -v '^\s*$' | tail -25 | sed 's/^/    /'; }
sleep 8
typ 'Reply with exactly LAB-READY and nothing else. Do not run any tool.'
wu 120 reply LAB-READY || { say "FAIL first turn never replied"; fin; exit 2; }
wu 60 idle_any; sleep 3
wlive || typ '/fm-watch-arm-omp'
wu 60 wlive || { say "FAIL watcher never armed"; fin; exit 2; }
say "watcher armed pid $(cat "$H/state/.watch.lock/pid")"
sleep 10; wu 120 idle_any
: > "$H/state/.lab-advisor-note"
typ 'Reply with exactly NOTE-READY and nothing else. Do not run any tool.'
wu 120 reply NOTE-READY || { say "FAIL note turn never replied"; fin; exit 2; }
wu 60 idle_note || { say "FAIL precondition: $(probe)"; fin; exit 2; }
say "precondition held: $(probe); idling ${IDLE}s"
sleep "$IDLE"
say "after idle: $(probe); wakes started so far: $(plog | grep -c '^wake ')"
: > "$H/state/labtask.meta"; printf 'done: lab idle wake\n' >> "$H/state/labtask.status"
start=$(date +%s)
wu 30 grep -q labtask.status "$H/state/.watch-deliveries.log" || { say "FAIL watcher never closed"; fin; exit 2; }
say "watcher closed on the wake; queue rows $(rows)"
if wu 60 sh -c "awk 'f&&/^wake /{w=1} /^note/{f=1} END{exit !w}' '$H/state/.lab-probe.log'"; then
  say "PASS idle wake started a turn $(( $(date +%s)-start ))s after the status line"
  wu 180 sh -c "[ ! -s '$H/state/.wake-queue' ]" && say "queue drained" || say "queue NOT drained ($(rows) rows)"
  if [ "${MIDRUN:-0}" = 1 ]; then
    wu 180 idle_any; sleep 5
    closes=$(grep -c labtask.status "$H/state/.watch-deliveries.log")
    typ 'Use the bash tool to run exactly this command and nothing else: sleep 40 ; echo LONGTURN-SLEPT . After it returns, reply with exactly LONGTURN-DONE and nothing else.'
    wu 60 sh -c "grep -q '^user Use the bash tool' '$H/state/.lab-probe.log'" || { say "FAIL long turn never started"; fin; exit 2; }
    sleep 8
    printf 'done: lab mid-run wake\n' >> "$H/state/labtask.status"
    wu 30 sh -c "[ \$(grep -c labtask.status '$H/state/.watch-deliveries.log') -gt $closes ]" || { say "FAIL mid-run wake never closed"; fin; exit 2; }
    say "mid-run wake closed while long turn running (LONGTURN-DONE seen yet: $(reply LONGTURN-DONE && echo yes || echo no))"
    order() { plog | awk '/^user Use the bash tool/{p=NR} p&&!r&&/^reply .*LONGTURN-DONE/{r=NR} /^wake /{if(p&&!r)e=1; else if(r)l=1} END{print e?"early":l?"ok":"pending"}'; }
    i=0; while [ "$(order)" = pending ] && [ $i -lt 150 ]; do sleep 1; i=$((i+1)); done
    say "mid-run ordering: $(order) (ok = wake started only after the run's final reply)"
    wu 180 sh -c "[ ! -s '$H/state/.wake-queue' ]" && say "mid-run queue drained" || say "mid-run queue NOT drained ($(rows) rows)"
    [ "$(order)" = ok ] || { fin; exit 1; }
  fi
  fin; exit 0
else
  say "FAIL wake started no turn within 60s after ${IDLE}s idle behind the advisor note (rows $(rows), $(probe))"
  fin; exit 1
fi
