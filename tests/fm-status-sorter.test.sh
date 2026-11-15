#!/usr/bin/env bash
# tests/fm-status-sorter.test.sh - the opt-in status-wake sorter
# (bin/fm-status-sorter-lib.sh) and its two consumers: the watcher's signal
# path (bin/fm-watch.sh signal_batch_held) and the drain's HELD STATUS section
# (bin/fm-wake-drain.sh).
#
# The rule tier is pinned as a table over the real library. The model tier runs
# real curl against a local stub HTTP server on 127.0.0.1 that answers sure
# hold, unsure, yes, malformed, slow, and error; no test reaches any other
# endpoint. The watcher cases drive a real fm-watch.sh against the stub, and the
# identity case proves a home without config/status-sorter wakes exactly as a
# configured home whose model says yes, with no held record and no request.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-status-sorter-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-sorter-tests)
# stub_start runs inside $(...) to return its port, so its pids are recorded in
# a file the parent shell can read back.
STUB_PID_FILE="$TMP_ROOT/stub.pids"

stop_stubs() {
  local pid
  [ -f "$STUB_PID_FILE" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done < "$STUB_PID_FILE"
  : > "$STUB_PID_FILE"
}
trap 'stop_stubs; fm_test_cleanup' EXIT

CORR=0123456789abcdef

# A local chat-completions stub. <dir>/mode holds "<kind> <content>": kind
# "answer" returns <content> as the assistant message, "status" returns that
# HTTP status, and "sleep" waits <content> seconds before a sure-hold answer.
# Every request is appended to <dir>/requests.log as one JSON line.
stub_start() {  # <dir> -> port on stdout
  local dir=$1 i=0
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the local model stub"
  cat > "$dir/stub.py" <<'PY'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

d = sys.argv[1]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        with open(os.path.join(d, "requests.log"), "a") as f:
            f.write(json.dumps({"path": self.path,
                                "auth": self.headers.get("Authorization"),
                                "body": body.decode("utf-8", "replace")}) + "\n")
        with open(os.path.join(d, "mode")) as f:
            kind, _, content = f.read().partition(" ")
        if kind == "sleep":
            time.sleep(float(content))
            kind, content = "answer", '{"answer":"no","confidence":0.99}'
        if kind == "status":
            code, raw = int(content), b'{"error":"stub"}'
        else:
            code = 200
            raw = json.dumps({"choices": [{"message": {"role": "assistant",
                                                       "content": content}}]}).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
        except OSError:
            pass

    def log_message(self, *args):
        pass

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port.tmp"), "w") as f:
    f.write(str(srv.server_port))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
srv.serve_forever()
PY
  printf '%s' 'answer {"answer":"no","confidence":0.95}' > "$dir/mode"
  : > "$dir/requests.log"
  # The stub's stdout must not hold the caller's $(...) open.
  python3 "$dir/stub.py" "$dir" > /dev/null 2> "$dir/stub.err" &
  printf '%s\n' "$!" >> "$STUB_PID_FILE"
  while [ ! -s "$dir/port" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$dir/port" ] || fail "the local model stub never reported its port"
  cat "$dir/port"
}

stub_mode() {  # <dir> <kind> [content]
  printf '%s %s' "$2" "${3:-}" > "$1/mode"
}

stub_requests() {  # <dir>
  awk 'END { print NR }' "$1/requests.log"
}

# Write config/status-sorter for <config-dir> against the stub on <port>.
write_sorter_config() {  # <config-dir> <port> [timeout]
  local cfg=$1 port=$2 timeout=${3:-2}
  mkdir -p "$cfg"
  printf 'test-key\n' > "$cfg/sorter.key"
  cat > "$cfg/status-sorter" <<EOF
# local stub only
endpoint=http://127.0.0.1:$port/v1/chat/completions
model=stub-model
key_file=$cfg/sorter.key
timeout=$timeout
EOF
}

# Library-level batch decision: rule tier over <span>, then the model tier.
decide_span() {  # <config-dir> <task> <span>
  fm_status_sorter_begin
  fm_status_sorter_add_span "$2" "$3" || return 1
  fm_status_sorter_decide "$1"
}

test_rule_tier_table() {
  local expect line got failures=''
  while IFS='|' read -r expect line; do
    [ -n "$expect" ] || continue
    if fm_status_sorter_rule "$line"; then got=candidate; else got=wake; fi
    [ "$got" = "$expect" ] || failures="$failures"$'\n'"  $line: expected $expect, got $got ($FM_STATUS_SORTER_REASON)"
  done <<EOF
candidate|working: compiling step 2
candidate|working [at=1700000000]: started the next phase
candidate|done corr=$CORR: recorded
candidate|done [corr=$CORR]: re-read done
wake|done: finished the task
wake|done xcorr=$CORR: recorded
wake|done corr=0123: recorded
wake|needs-decision: choose between two layouts
wake|needs-decision [key=layout]: choose between two layouts
wake|blocked: the build needs a credential
wake|failed: tests failed twice
wake|paused: waiting on CI until 2026-01-01T00:00Z
wake|note: fyi only
wake|resolved [key=layout]: answered
wake|captain-held: transferred to the captain
wake|parked: an unknown verb
wake|working [key=child-pr-alpha]: relayed
wake|working: saw child-outcome-alpha-done
wake|done corr=$CORR: child-pr-alpha relayed
wake|working: opened https://forge.example.invalid/acme/widget/pull/12
wake|done corr=$CORR: https://forge.example.invalid/acme/widget/merge_requests/7 is up
wake|working: recorded pr=https://forge.example.invalid/acme/widget/pull/12
wake|working: merging the base branch
wake|done corr=$CORR: merged
wake|working: PR ready for review
wake|working: checks green on the branch
wake|continuation prose without a verb
EOF
  [ -z "$failures" ] || fail "rule tier disagreed with the table:$failures"
  pass "rule tier: only working lines and steer-reply done lines are candidates; decisions, blockers, failures, pauses, finished work, keys, and PR or merge news wake"
}

test_model_sure_hold_records_the_reason() {
  local dir cfg port req
  dir="$TMP_ROOT/model-hold"; cfg="$dir/config"; mkdir -p "$dir"
  port=$(stub_start "$dir")
  write_sorter_config "$cfg" "$port"
  decide_span "$cfg" mate1 "done corr=$CORR: recorded" \
    || fail "a sure no did not hold the line: $FM_STATUS_SORTER_REASON"
  [ "$FM_STATUS_SORTER_HELD" = "mate1"$'\t'"model"$'\t'"model: no (confidence 0.95)"$'\t'"done corr=$CORR: recorded"$'\n' ] \
    || fail "held row did not carry task, tier, reason, and line: $(printf '%q' "$FM_STATUS_SORTER_HELD")"
  [ "$(stub_requests "$dir")" = 1 ] || fail "a single candidate did not make exactly one request"
  req=$(head -n 1 "$dir/requests.log")
  [ "$(printf '%s' "$req" | jq -r .auth)" = 'Bearer test-key' ] || fail "the key file was not sent as a bearer header: $req"
  [ "$(printf '%s' "$req" | jq -r '.body | fromjson | .model')" = stub-model ] || fail "the configured model was not sent: $req"
  printf '%s' "$req" | jq -r '.body | fromjson | .messages[-1].content' | grep -F "done corr=$CORR: recorded" >/dev/null \
    || fail "the status line was not sent to the model: $req"

  stub_mode "$dir" answer $'```json\n{"answer":"No","confidence":1}\n```'
  decide_span "$cfg" mate1 "working: re-read done" \
    || fail "a fenced sure no was not accepted: $FM_STATUS_SORTER_REASON"
  stop_stubs
  pass "model tier: a sure no holds the line, sends key, model, and line, and records tier and reason"
}

test_model_unsure_yes_and_malformed_wake() {
  local dir cfg port
  dir="$TMP_ROOT/model-wake"; cfg="$dir/config"; mkdir -p "$dir"
  port=$(stub_start "$dir")
  write_sorter_config "$cfg" "$port"
  stub_mode "$dir" answer '{"answer":"no","confidence":0.6}'
  ! decide_span "$cfg" mate1 "working: started" || fail "a no below hold_confidence held the line"
  assert_contains "$FM_STATUS_SORTER_REASON" "unsure" "the unsure band must be named"
  stub_mode "$dir" answer '{"answer":"yes","confidence":0.99}'
  ! decide_span "$cfg" mate1 "working: started" || fail "a yes held the line"
  stub_mode "$dir" answer 'probably fine, no action'
  ! decide_span "$cfg" mate1 "working: started" || fail "a malformed answer held the line"
  assert_contains "$FM_STATUS_SORTER_REASON" "malformed" "a malformed answer must be named"
  stub_mode "$dir" answer '{"answer":"no","confidence":"high"}'
  ! decide_span "$cfg" mate1 "working: started" || fail "a non-numeric confidence held the line"
  printf 'hold_confidence=0.6\n' >> "$cfg/status-sorter"
  stub_mode "$dir" answer '{"answer":"no","confidence":0.6}'
  decide_span "$cfg" mate1 "working: started" || fail "a configured lower hold_confidence was not honoured"
  stop_stubs
  pass "model tier: the unsure band, a yes, and a malformed answer wake; hold_confidence sets the band"
}

test_model_timeout_and_errors_wake() {
  local dir cfg port start elapsed
  dir="$TMP_ROOT/model-errors"; cfg="$dir/config"; mkdir -p "$dir"
  port=$(stub_start "$dir")
  write_sorter_config "$cfg" "$port" 1
  stub_mode "$dir" sleep 4
  start=$(date +%s)
  ! decide_span "$cfg" mate1 "working: started" || fail "a timed-out request held the line"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 4 ] || fail "the request was not bounded by the configured timeout (${elapsed}s)"
  assert_contains "$FM_STATUS_SORTER_REASON" "unreachable" "a timeout must read as unreachable"
  stub_mode "$dir" status 500
  ! decide_span "$cfg" mate1 "working: started" || fail "a 500 answer held the line"
  assert_contains "$FM_STATUS_SORTER_REASON" "HTTP 500" "a non-200 answer must be named"
  stop_stubs
  write_sorter_config "$cfg" "$port" 1
  ! decide_span "$cfg" mate1 "working: started" || fail "an unreachable endpoint held the line"
  assert_contains "$FM_STATUS_SORTER_REASON" "unreachable" "a closed port must read as unreachable"
  pass "model tier: a timeout, a non-200 answer, and an unreachable endpoint wake"
}

test_model_never_asked_without_usable_input() {
  local dir cfg port
  dir="$TMP_ROOT/model-no-ask"; cfg="$dir/config"; mkdir -p "$dir"
  port=$(stub_start "$dir")
  write_sorter_config "$cfg" "$port"
  rm -f "$cfg/sorter.key"
  ! decide_span "$cfg" mate1 "working: started" || fail "a missing key file held the line"
  assert_contains "$FM_STATUS_SORTER_REASON" "key file" "a missing key must be named"
  write_sorter_config "$cfg" "$port"
  printf 'temperature=0\n' >> "$cfg/status-sorter"
  ! decide_span "$cfg" mate1 "working: started" || fail "an invalid config held the line"
  assert_contains "$FM_STATUS_SORTER_REASON" "config invalid" "an invalid config must be named"
  write_sorter_config "$cfg" "$port"
  ! decide_span "$cfg" mate1 "$(printf 'working: a\nworking: b\nworking: c\nworking: d\nworking: e')" \
    || fail "a batch over the candidate limit held its lines"
  ! decide_span "$cfg" mate1 "$(printf 'working: started\nblocked: need a credential')" \
    || fail "a span with a blocker held its lines"
  [ "$(stub_requests "$dir")" = 0 ] || fail "the model was asked without a usable key, config, or candidate set"
  stop_stubs
  pass "model tier: a missing key, an invalid config, an oversized batch, or a rule wake never reaches the model"
}

# One watcher home: state, fakebin, and a config dir that may hold the sorter.
sorter_home() {  # <name>
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host-off"
  printf '%s\n' "$dir"
}

# Seed <task>'s status log with one already-seen line, then append <line>.
seed_status() {  # <state> <task> <line>
  local f="$1/$2.status"
  printf 'working: earlier progress\n' > "$f"
  prime_status_seen "$1" "$f"
  printf '%s\n' "$3" >> "$f"
}

watch_home() {  # <dir> [extra env...]
  local dir=$1
  shift
  watch_bg "$dir/state" "$dir/fakebin" "$dir/watch.out" env FM_CONFIG_OVERRIDE="$dir/config" "$@"
}

wait_for_triage() {  # <state> <pid> <needle>
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -Fq "$3" "$1/.watch-triage.log" 2>/dev/null && return 0
    kill -0 "$2" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

drain_home() {  # <dir> <out>
  FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" "$DRAIN" > "$2" 2>/dev/null
}

test_watcher_holds_and_drain_presents_once() {
  local dir state stub port pid out
  dir=$(sorter_home watch-hold); state="$dir/state"
  stub="$dir/stub"; mkdir -p "$stub"
  port=$(stub_start "$stub")
  write_sorter_config "$dir/config" "$port"
  seed_status "$state" mate1 "done corr=$CORR: recorded"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · fake default'
  watch_home "$dir"
  pid=$!
  wait_for_triage "$state" "$pid" "held signal:" \
    || { reap "$pid"; fail "the watcher did not hold a sure-no steer reply: $(cat "$dir/watch.out")"; }
  reap "$pid"
  [ ! -s "$dir/watch.out" ] || fail "a held line printed a wake reason: $(cat "$dir/watch.out")"
  [ ! -s "$state/.wake-queue" ] || fail "a held line queued a wake row"
  grep -F "$(printf 'mate1\tmodel\tmodel: no (confidence 0.95)\tdone corr=%s: recorded' "$CORR")" \
    "$state/status-sorter-held.log" >/dev/null || fail "the held log lacks the line, tier, and reason: $(cat "$state/status-sorter-held.log" 2>/dev/null)"
  tail -n 1 "$state/mate1.status" | grep -Fx "done corr=$CORR: recorded" >/dev/null \
    || fail "holding the wake changed the durable status log"

  # The heartbeat backstop must not raise the held line again.
  # A successor of the reaped watcher: its downtime marker has no queued row.
  watch_home "$dir" FM_HEARTBEAT=1 FM_WATCH_HANDLING_SUCCESSOR=1
  pid=$!
  for _ in 1 2 3; do
    wait_poll_cycle "$state" "$pid" \
      || { reap "$pid"; fail "the heartbeat backstop re-raised a held line: $(cat "$dir/watch.out")"; }
  done
  reap "$pid"
  [ ! -s "$state/.wake-queue" ] || fail "the heartbeat backstop queued a held line"
  [ "$(stub_requests "$stub")" = 1 ] || fail "a held line was sent to the model again"

  out="$dir/drain1.out"
  drain_home "$dir" "$out" || fail "drain failed with a held line"
  grep -F 'HELD STATUS (1 status line(s)' "$out" >/dev/null || fail "the drain printed no HELD STATUS count: $(cat "$out")"
  grep -F "mate1 done corr=$CORR: recorded [held by model: no (confidence 0.95)]" "$out" >/dev/null \
    || fail "the drain did not present the held line with its reason: $(cat "$out")"
  out="$dir/drain2.out"
  drain_home "$dir" "$out" || fail "second drain failed"
  ! grep -F 'HELD STATUS' "$out" >/dev/null || fail "a presented held line was printed again: $(cat "$out")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" mate2 model 'model: no (confidence 0.9)' 'working: started' \
    >> "$state/status-sorter-held.log"
  out="$dir/drain3.out"
  drain_home "$dir" "$out" || fail "third drain failed"
  grep -F 'mate2 working: started' "$out" >/dev/null || fail "a later held line was not presented: $(cat "$out")"
  ! grep -F 'mate1 done' "$out" >/dev/null || fail "an earlier held line was replayed with a later one"
  stop_stubs
  pass "watcher holds a sure-no line without a wake or backstop, and the drain presents it once with count and reason"
}

test_watcher_wakes_on_yes_rule_and_unreachable() {
  local dir state stub port pid
  dir=$(sorter_home watch-wake); state="$dir/state"
  stub="$dir/stub"; mkdir -p "$stub"
  port=$(stub_start "$stub")
  write_sorter_config "$dir/config" "$port"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · fake default'

  stub_mode "$stub" answer '{"answer":"yes","confidence":0.9}'
  seed_status "$state" mate1 "working: started the migration"
  watch_home "$dir"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a yes answer did not wake the watcher"
  grep -F "signal: $state/mate1.status" "$dir/watch.out" >/dev/null || fail "a yes answer did not print the signal"
  [ "$(stub_requests "$stub")" = 1 ] || fail "the candidate was not asked exactly once"
  ack_stopped_cycle "$state" >/dev/null 2>&1 || fail "could not acknowledge the yes wake"

  : > "$dir/watch.out"
  printf 'blocked [key=cred]: the build needs a credential\n' >> "$state/mate1.status"
  watch_home "$dir"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a blocker did not wake the watcher"
  grep -F "signal: $state/mate1.status" "$dir/watch.out" >/dev/null || fail "a blocker did not print the signal"
  [ "$(stub_requests "$stub")" = 1 ] || fail "a blocker was sent to the model"
  ack_stopped_cycle "$state" >/dev/null 2>&1 || fail "could not acknowledge the blocker wake"

  stop_stubs
  : > "$dir/watch.out"
  printf 'working: re-read done\n' >> "$state/mate1.status"
  watch_home "$dir"
  pid=$!
  wait_for_exit "$pid" 100 || fail "an unreachable model did not wake the watcher"
  grep -F "signal: $state/mate1.status" "$dir/watch.out" >/dev/null || fail "an unreachable model did not print the signal"
  [ ! -e "$state/status-sorter-held.log" ] || fail "a woken line was written to the held log"
  pass "watcher wakes on a yes, on a rule-tier blocker without asking, and when the model is unreachable"
}

# Strip the per-case directory and the volatile row fields (time and sequence)
# so two homes' outputs compare byte for byte.
normalize() {  # <dir> <file>
  sed -e "s#$1#HOME#g" -e 's/^[^	]*	[0-9][0-9]*	/ROW	/' "$2"
}

test_config_absent_is_identical() {
  local off on stub port pid
  off=$(sorter_home identity-off)
  on=$(sorter_home identity-on)
  stub="$on/stub"; mkdir -p "$stub"
  port=$(stub_start "$stub")
  write_sorter_config "$on/config" "$port"
  stub_mode "$stub" answer '{"answer":"yes","confidence":0.9}'
  export FM_FAKE_CREW_STATE='state: unknown · source: none · fake default'
  for home in "$off" "$on"; do
    seed_status "$home/state" mate1 "done corr=$CORR: recorded"
    watch_home "$home"
    pid=$!
    wait_for_exit "$pid" 100 || fail "the watcher did not wake in $(basename "$home")"
    drain_home "$home" "$home/drain.out" || fail "drain failed in $(basename "$home")"
  done
  [ "$(normalize "$off" "$off/watch.out")" = "$(normalize "$on" "$on/watch.out")" ] \
    || fail "watcher output differs with the config absent: $(cat "$off/watch.out") vs $(cat "$on/watch.out")"
  [ "$(normalize "$off" "$off/state/.wake-queue")" = "$(normalize "$on" "$on/state/.wake-queue")" ] \
    || fail "queued wake rows differ with the config absent"
  [ "$(normalize "$off" "$off/drain.out")" = "$(normalize "$on" "$on/drain.out")" ] \
    || fail "drain output differs with the config absent: $(cat "$off/drain.out") vs $(cat "$on/drain.out")"
  [ "$(ls -A "$off/state")" = "$(ls -A "$on/state")" ] \
    || fail "the state files differ with the config absent: $(ls -A "$off/state") vs $(ls -A "$on/state")"
  [ ! -e "$off/state/status-sorter-held.log" ] && [ ! -e "$off/state/.status-sorter-held.cursor" ] \
    || fail "a home without the config wrote sorter records"
  [ "$(stub_requests "$stub")" = 1 ] || fail "only the configured home may ask the model"
  stop_stubs
  pass "with config/status-sorter absent the watcher, queue, drain, and state files match a configured home whose model says yes"
}

fm_test_run \
  test_rule_tier_table \
  test_model_sure_hold_records_the_reason \
  test_model_unsure_yes_and_malformed_wake \
  test_model_timeout_and_errors_wake \
  test_model_never_asked_without_usable_input \
  test_watcher_holds_and_drain_presents_once \
  test_watcher_wakes_on_yes_rule_and_unreachable \
  test_config_absent_is_identical
