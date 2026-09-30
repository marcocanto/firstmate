#!/usr/bin/env bash
# Exercise the real launcher and guard chain with a process observer, not Herdr.
# Real kernel process identities, exit codes, signals, and descriptors prove
# that detachment does not replace the process launchd supervises.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v perl >/dev/null 2>&1 || { echo 'skip: Perl POSIX not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-remote-herdr-launch)
mkdir -p "$TMP_ROOT/bin"
LAUNCH_PID=
trap '[ -z "$LAUNCH_PID" ] || kill "$LAUNCH_PID" 2>/dev/null || true; fm_test_cleanup || true' EXIT
cp "$ROOT/bin/fm-remote-herdr-launch.sh" "$ROOT/bin/fm-remote-herdr-guard.sh" \
  "$ROOT/bin/fm-remote-herdr-owner-lib.sh" "$TMP_ROOT/bin/"
HERDR_OBSERVER="$TMP_ROOT/bin/herdr with spaces"
printf '#!%s\n' "$(command -v python3)" > "$HERDR_OBSERVER"
cat >> "$HERDR_OBSERVER" <<'PY'
import json
import os
import signal
import sys
if sys.argv[1] == 'status':
    print(json.dumps({'server': {'running': False}}))
    sys.exit(0)

print('server stdout', flush=True)
print('server stderr', file=sys.stderr, flush=True)
result = os.environ['FM_LAUNCH_RESULT']
with open(result + '.tmp', 'w') as stream:
    json.dump({'pid': os.getpid(), 'sid': os.getsid(0), 'pgid': os.getpgrp(),
               'context': os.environ.get('FM_TEST_LAUNCH_CONTEXT'), 'args': sys.argv[1:],
               'stdin': sys.stdin.read()}, stream)
os.replace(result + '.tmp', result)
if os.environ['FM_LAUNCH_MODE'] == 'crash':
    signal.pause()
sys.exit(int(os.environ['FM_LAUNCH_EXIT']))
PY
chmod +x "$TMP_ROOT/bin/"*.sh "$HERDR_OBSERVER"

launch_case() { # <inherited|leader|session-leader> <exit|crash> <exit-code>
  local group=$1 mode=$2 code=$3
  CASE="$TMP_ROOT/$group-$mode-$code"
  mkdir -p "$CASE"
  printf 'server stdin' > "$CASE/input"
  FM_TEST_LAUNCH_CONTEXT=test-context \
    FM_LAUNCH_RESULT="$CASE/result.json" FM_LAUNCH_MODE="$mode" FM_LAUNCH_EXIT="$code" \
    perl -MPOSIX=setpgid,setsid -e '
      use strict;
      use warnings;
      my ($group, $identity, @command) = @ARGV;
      if ($group eq "leader") { setpgid(0, 0) or die "test setpgid: $!"; }
      if ($group eq "session-leader") { setsid() >= 0 or die "test setsid: $!"; }
      open(my $record, ">", $identity) or die "test identity: $!";
      print $record "$$ ", getpgrp(), " $ENV{FM_TEST_LAUNCH_CONTEXT}\n";
      close $record;
      exec {$command[0]} @command or die "test exec: $!";
    ' -- "$group" "$CASE/initial" "$TMP_ROOT/bin/fm-remote-herdr-launch.sh" \
      "$HERDR_OBSERVER" 'fm-lab-launch' < "$CASE/input" > "$CASE/stdout" 2> "$CASE/stderr" &
  LAUNCH_PID=$!
}

wait_case() {
  set +e
  wait "$LAUNCH_PID" 2>/dev/null
  LAUNCH_RC=$?
  set -e
  LAUNCH_PID=
}

assert_identity() { # <inherited|leader>
  local group=$1 initial_pid initial_pgid initial_context
  read -r initial_pid initial_pgid initial_context < "$CASE/initial"
  [ "$initial_context" = test-context ] || fail 'the launch caller lacked the context marker'
  if [ "$group" = leader ]; then
    [ "$initial_pid" = "$initial_pgid" ] || fail 'the process-group-leader fixture was not a leader'
  else
    [ "$initial_pid" != "$initial_pgid" ] || fail 'the inherited-group fixture was already a group leader'
  fi
  jq -e --argjson pid "$initial_pid" '
    .pid == $pid and .sid == $pid and .pgid == $pid
    and .context == "test-context"
    and .args == ["server", "--session", "fm-lab-launch"]
    and .stdin == "server stdin"
  ' "$CASE/result.json" >/dev/null || fail 'detachment changed the tracked PID or lost the inherited launch context'
  assert_grep 'server stdout' "$CASE/stdout" 'the server stdout descriptor did not survive exec'
  assert_grep 'server stderr' "$CASE/stderr" 'the server stderr descriptor did not survive exec'
}

for group in inherited leader; do
  for code in 0 23; do
    launch_case "$group" exit "$code"
    wait_case
    expect_code "$code" "$LAUNCH_RC" 'the launcher did not preserve the server exit code'
    assert_identity "$group"
  done
  pass "$group group becomes a same-PID session leader and preserves launch context and exit codes"
done

launch_case leader crash 0
i=0
while [ ! -s "$CASE/result.json" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$CASE/result.json" ] || fail 'the crash fixture did not start'
assert_identity leader
kill -KILL "$LAUNCH_PID"
wait_case
expect_code 137 "$LAUNCH_RC" 'the tracked launcher PID did not carry the server crash'
pass 'a server crash reaches the original supervised PID'

launch_case session-leader exit 0
wait_case
[ "$LAUNCH_RC" -ne 0 ] || fail 'a failed process-group join was ignored'
assert_absent "$CASE/result.json" 'the guard ran after the process-group join failed'
pass 'a failed process-group join stops before any server starts'
