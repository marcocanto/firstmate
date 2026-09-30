#!/usr/bin/env bash
# tmux port of tests/fm-omp-interrupt-live-e2e.test.sh (the Herdr lab tripwire could
# not provision on this host). Real omp, private tmux socket, disposable homes.
set -u
ROOT=${ROOT:?}
cd "$ROOT"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_TASK_ID FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
OMP_BIN=$(command -v omp); OMP_VERSION=$("$OMP_BIN" --version | head -1)
MODEL=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6-astra}
SETTLE_MS=8000
. "$ROOT/bin/fm-backend.sh"; fm_backend_source tmux; . "$ROOT/bin/fm-composer-lib.sh"
TARGET=; HOME_ROOT=; WHO="omp $OMP_VERSION ($MODEL) through tmux"
cleanup() { rc=$?; T kill-server 2>/dev/null; for p in $(ps -axo pid=,command= | awk -v l="$LAB" 'index($0,l){print $1}'); do kill -TERM $p 2>/dev/null; done; rm -rf "$LAB"; exit $rc; }
trap cleanup EXIT
screen() { T capture-pane -p -t "$TARGET" -S -40 2>/dev/null; }
fail() { echo "not ok - $1"; echo "# pane:"; screen | tail -30 | sed 's/^/#   /'; echo "# rows: $(queue_rows)"; exit 1; }
busy() { screen | grep -Eq "$FM_DELIVERY_OMP_BUSY_REGEX_DEFAULT"; }
# Screen-read composer: the last prompt row (❯) with or without text after it.
composer() { local r; r=$(screen | grep '❯' | tail -1) || { printf unknown; return; }; r=${r#*❯}; r=$(printf '%s' "$r" | tr -d '[:space:]'); [ -z "$r" ] && printf empty || printf pending; }
queue_rows() { [ -s "$HOME_ROOT/state/.wake-queue" ] && wc -l < "$HOME_ROOT/state/.wake-queue" | tr -d ' ' || printf 0; }
type_line() { T send-keys -t "$TARGET" -l "$1"; sleep 0.5; T send-keys -t "$TARGET" Enter; }
wait_until() { local l=$1 i=0; shift; while [ $i -lt $l ]; do "$@" && return 0; sleep 1; i=$((i+1)); done; return 1; }
watcher_live() { local p; p=$(cat "$HOME_ROOT/state/.watch.lock/pid" 2>/dev/null) || return 1; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
reply_seen() { screen | grep -Eq "^[^[:alnum:]]*$1[[:space:]]*\$"; }
settled_idle() { ! busy && sleep 2 && ! busy; }
wake_closed() { grep -q 'labtask.status' "$HOME_ROOT/state/.watch-deliveries.log" 2>/dev/null; }
queue_drained() { [ "$(queue_rows)" = 0 ]; }
composer_empty() { [ "$(composer)" = empty ]; }
steer_seen() { T capture-pane -p -t "$TARGET" -S -400 | grep -q 'Firstmate supervision continues in a new turn'; }
build_home() {
  HOME_ROOT="$LAB/$1/root"; mkdir -p "$HOME_ROOT"
  git -C "$ROOT" ls-files -z --cached | (cd "$ROOT" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$HOME_ROOT"
  printf 'labmate\n' > "$HOME_ROOT/.fm-secondmate-home"; mkdir -p "$HOME_ROOT/state" "$HOME_ROOT/config" "$HOME_ROOT/data"
}
launch_omp() {
  T new-session -d -s "$1" -x 160 -x 160 -y 50 -c "$HOME_ROOT" \
    "env -u CLAUDECODE -u FM_TASK_ID -u OMPCODE GIT_CEILING_DIRECTORIES='$LAB' FM_HOME='$HOME_ROOT' FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 FM_OMP_INTERRUPT_SETTLE_MS=$SETTLE_MS '$OMP_BIN' --config '$HOME_ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$HOME_ROOT' --no-session --model '$MODEL' --thinking low"
  TARGET="$1"
}
snap() { echo "# --- pane ($1) ---"; screen | grep -v '^[[:space:]]*$' | tail -${2:-14} | sed 's/^/#   /'; }
run_case() {
  local kind=$1 key want
  build_home "$kind"; launch_omp "$kind"
  wait_until 60 composer_empty || fail "$kind: composer never empty at start ($(composer))"
  type_line 'Reply with exactly LAB-READY and nothing else. Do not run any tool.'
  wait_until 120 test -e "$HOME_ROOT/state/.lock" || fail "$kind: no lab lock"
  wait_until 120 reply_seen LAB-READY || fail "$kind: first turn never replied"
  wait_until 120 settled_idle || fail "$kind: not idle"
  watcher_live || type_line '/fm-watch-arm-omp'
  wait_until 60 watcher_live || fail "$kind: watcher never armed"
  wait_until 120 settled_idle || fail "$kind: not idle after arm"
  type_line 'Use the bash tool to run exactly this command and nothing else: sleep 60 ; echo LONGTURN-SLEPT . After it returns, reply with exactly LONGTURN-DONE and nothing else.'
  wait_until 60 busy || fail "$kind: long turn never busy"
  : > "$HOME_ROOT/state/labtask.meta"; printf 'done: lab wake\n' >> "$HOME_ROOT/state/labtask.status"
  wait_until 30 wake_closed || fail "$kind: watcher never closed"
  sleep 5
  busy || fail "$kind: long turn ended too early"
  [ "$(queue_rows)" -gt 0 ] || fail "$kind: no durable row"
  echo "# $kind: wake queued behind busy turn, durable rows=$(queue_rows)"
  case $kind in escape) key=Escape want=pending;; enter) key=Enter want=empty;; draft) key=Escape want=pending;; esac
  if [ $kind = draft ]; then T send-keys -t "$TARGET" -l 'captain draft KEEP-ME-7 do not lose'; sleep 1; echo "# draft: captain typed an unsent draft during the busy turn"; fi
  T send-keys -t "$TARGET" "$key"; sleep 3
  local c; c=$(composer)
  busy && fail "$kind: $key did not end the run"
  snap "$kind right after $key (settle window, recovery not yet acted)"
  [ "$c" = "$want" ] || fail "$kind: precondition broke on $OMP_VERSION: composer=$c want=$want"
  if [ $kind = escape ]; then screen | grep -q 'FIRSTMATE WATCHER WAKE' || fail "escape: wake text not restored into composer on $OMP_VERSION"; fi
  echo "# $kind precondition held: composer=$c, $(queue_rows) durable rows"
  if [ $kind = enter ]; then wait_until 60 steer_seen || fail "enter: steer never reached transcript"; echo "# enter: continuation steer seen in transcript"; fi
  wait_until 300 queue_drained || fail "$kind: queue never drained ($(queue_rows) rows)"
  wait_until 180 settled_idle || fail "$kind: not idle after recovery"
  if [ $kind = draft ]; then
    local row; row=$(screen | grep '❯' | tail -1); echo "# draft: composer row after recovery: [$row]"
    printf '%s' "$row" | grep -q '❯ captain draft KEEP-ME-7 do not lose[[:space:]]*$' || fail "draft: captain draft not preserved exactly"
    screen | grep -A3 '❯' | grep -q 'FIRSTMATE WATCHER WAKE' && fail "draft: wake text left in composer"
  else
    wait_until 30 composer_empty || fail "$kind: composer=$(composer) after recovery"
  fi
  snap "$kind after recovery" 20
  echo "# $kind: wake-drain invocations in transcript: $(T capture-pane -p -t "$TARGET" -S -400 | grep -c 'fm-wake-drain')"
  echo "ok - live omp interrupt recovery ($kind): $WHO drained the wake with no further key, composer=$(composer)"
  type_line '/quit'; sleep 2
}
for k in ${CASES:-escape enter}; do run_case $k; done
