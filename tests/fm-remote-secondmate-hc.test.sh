#!/usr/bin/env bash
# tests/fm-remote-secondmate-hc.test.sh - the host half of a remote second mate
# on the hc backend: bin/fm-remote-secondmate-control.sh run directly, the way
# the remote job worker runs it, against the stateful fake herdr-core in
# tests/hc-fake-fixture.sh and a real unix socket that stands in for an
# answering core. The parent half (route recording, readiness, steering, and
# lifecycle routing) is covered by the remote lifecycle and relaunch suites.
#
# The socket sits at hc's own HOME layout for the configured session, under a
# scratch XDG_STATE_HOME, because that layout is what the host resolves when the
# job worker hands it nothing but HOME.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/hc-fake-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/hc-fake-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-hc)
# AF_UNIX paths are capped near 104 bytes, so the socket layout gets its own
# short directory.
SOCK_ROOT=$(mktemp -d /tmp/fmrhc.XXXXXX)
SHELL_PID=
cleanup_hc() {
  stop_hc_core_socket "$SOCK_ROOT/none" 2>/dev/null || true
  [ -z "$SHELL_PID" ] || kill "$SHELL_PID" 2>/dev/null || true
  rm -rf "$SOCK_ROOT"
  fm_test_cleanup
}
trap cleanup_hc EXIT
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

FAKEBIN="$TMP_ROOT/fakebin"
HC_STATE="$TMP_ROOT/hc"
mkdir -p "$FAKEBIN"
write_hc_fake_cli "$FAKEBIN/herdr-core" "$HC_STATE"
ln -sf "$(command -v git)" "$FAKEBIN/git"
ln -sf "$(command -v jq)" "$FAKEBIN/jq"
ln -sf "$(command -v python3)" "$FAKEBIN/python3"
command -v node >/dev/null 2>&1 && ln -sf "$(command -v node)" "$FAKEBIN/node"
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != models ] || printf '%s\n' '{"models":[]}'
exit 0
SH
chmod +x "$FAKEBIN/omp"

# A real shell alone in its own process group, so the classifier reads the
# terminal's zsh foreground as an agent-free shell once its agent exits.
mkfifo "$TMP_ROOT/shell.fifo"
perl -e 'setpgrp(0, 0); exec "/bin/sh", "-c", "read x < \"\$0\"", $ARGV[0]' "$TMP_ROOT/shell.fifo" &
SHELL_PID=$!
printf '%s\n' "$SHELL_PID" > "$HC_STATE/shell-pid"

ID=sm-hc
SESSION=fmrhc-lab
HOME_DIR="$TMP_ROOT/home-$ID"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/data" "$HOME_DIR/config"
printf '# Firstmate\n' > "$HOME_DIR/AGENTS.md"
printf '%s\n' "$ID" > "$HOME_DIR/.fm-secondmate-home"
printf '# Charter\n\nStand by until steering arrives.\n' > "$HOME_DIR/data/charter.md"
printf '%s\n' "$SESSION" > "$HOME_DIR/config/hc-session"
git -C "$HOME_DIR" init -q
META="$HOME_DIR/state/parent-route/$ID.meta"
CORE_SOCK="$SOCK_ROOT/herdr-core/$SESSION/$SESSION.sock"

ctl() {
  env -u HC_SESSION -u HC_SOCKET -u FM_HC_SOCKET -u FM_HC_BIN -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u XDG_RUNTIME_DIR \
    PATH="$FAKEBIN:$BASE_PATH" TMUX='' FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    XDG_STATE_HOME="$SOCK_ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}

calls() { wc -l < "$HC_STATE/log" 2>/dev/null | tr -d ' ' || printf 0; }

tag_of() {  # <home> <root>
  # shellcheck disable=SC2016 # $0 expands in the child shell, not here.
  env -u FM_ROOT_OVERRIDE FM_HOME="$1" FM_ROOT="$2" bash -c '. "$0/bin/fm-backend-hometag-lib.sh"; fm_backend_hometag' "$ROOT"
}

# --- launch refuses a core that does not answer, without starting one -------

: > "$HC_STATE/log"
if ctl launch "$ID" omp - - hc > "$TMP_ROOT/launch-down.out" 2>&1; then
  fail "a launch was accepted while no hc core answered"
fi
assert_grep "does not answer on this host" "$TMP_ROOT/launch-down.out" \
  "the refused launch did not name the silent core"
[ "$(calls)" = 0 ] || fail "a refused launch still contacted hc, which would start a core: $(cat "$HC_STATE/log")"
assert_absent "$META" "a refused launch published an endpoint record"
pass "a remote hc launch refuses a silent core and never contacts hc"

printf 'bad/session\n' > "$HOME_DIR/config/hc-session"
start_hc_core_socket "$CORE_SOCK"
if ctl launch "$ID" omp - - hc > "$TMP_ROOT/launch-bad-session.out" 2>&1; then
  fail "a launch was accepted with an invalid config/hc-session"
fi
assert_grep 'config/hc-session does not name one valid hc session' "$TMP_ROOT/launch-bad-session.out" \
  "an invalid session file was not named"
printf '%s\n' "$SESSION" > "$HOME_DIR/config/hc-session"
pass "a remote hc launch refuses an invalid session setting"

# --- launch places the mate on the configured core with its identity labels -

ctl launch "$ID" omp - - hc > "$TMP_ROOT/launch.out" 2> "$TMP_ROOT/launch.err"
expect_code 0 "$?" "the remote hc launch failed"$'\n'"$(cat "$TMP_ROOT/launch.err")"
assert_grep 'backend=hc' "$TMP_ROOT/launch.out" "the printed route did not report hc"
assert_grep "hc_session=$SESSION" "$TMP_ROOT/launch.out" "the printed route did not report the configured session"
assert_grep "target=$SESSION:t1" "$TMP_ROOT/launch.out" "the printed route did not name the new terminal"
assert_grep 'backend=hc' "$META" "the endpoint record did not record hc"
assert_grep "hc_session=$SESSION" "$META" "the endpoint record did not record the session"
labels=$(jq -c '.labels' "$HC_STATE/t1.json")
assert_equals "$(jq -r '.["firstmate.task"]' <<<"$labels")" "fm-$ID" "the mate terminal lacks its task label"
assert_equals "$(jq -r '.["firstmate.home"]' <<<"$labels")" "$(tag_of "$ROOT" "$ROOT")" \
  "the mate terminal does not carry the host launch's home label"
assert_equals "$(jq -r '.["herdr.space"]' <<<"$labels")" "fm-$(tag_of "$HOME_DIR" "$HOME_DIR")" \
  "the mate terminal is not in the mate's own Herdr.app space"
if grep -v "^HC_SESSION=$SESSION"$'\x1f' "$HC_STATE/log" | grep -q .; then
  fail "a launch call reached a session other than the configured one: $(cat "$HC_STATE/log")"
fi
[ "$(ctl state "$ID")" = alive ] || fail "the launched hc mate did not read alive"
route=$(ctl route "$ID")
assert_contains "$route" "hc_session=$SESSION" "the route verb did not report the hc session"
pass "a remote hc launch records the configured core, labels the mate, and reads alive"

# --- an existing hc endpoint is never migrated by a launch on another backend

if ctl launch "$ID" omp - - herdr > "$TMP_ROOT/launch-other.out" 2>&1; then
  fail "a herdr launch was accepted over a recorded hc endpoint"
fi
assert_grep "recorded on backend 'hc', expected 'herdr'" "$TMP_ROOT/launch-other.out" \
  "a cross-backend launch was not refused by name"
pass "a launch on another backend refuses a recorded hc endpoint"

# --- steering: the record lands and the doorbell reaches the terminal --------

: > "$HC_STATE/sent"
ctl send "$ID" "steer one" > "$TMP_ROOT/send.out" 2>&1
expect_code 0 "$?" "a steer to the remote hc mate failed"$'\n'"$(cat "$TMP_ROOT/send.out")"
inbox="$HOME_DIR/state/parent-route/$ID.inbox"
grep -l 'steer one' "$inbox"/*.msg >/dev/null 2>&1 || fail "the steer did not land as a record in the host inbox"
assert_grep "$ID.inbox" "$HC_STATE/sent" "the doorbell was not typed into the mate terminal"
assert_not_contains "$(cat "$TMP_ROOT/send.out")" 'doorbell' "the doorbell reported a delivery problem"
pass "a steer lands in the host inbox and rings the hc doorbell"

# A composer visibly holding the operator's own text gets no doorbell typed
# into it; the steer is still recorded durably.
printf 'output line\n╭─────────────────────╮\n│ %-19s │\n╰─────────────────────╯\n' '> half-typed note' > "$HC_STATE/screen"
: > "$HC_STATE/sent"
ctl send "$ID" "steer held" > "$TMP_ROOT/send-held.out" 2>&1
expect_code 0 "$?" "a steer behind a held composer did not record"$'\n'"$(cat "$TMP_ROOT/send-held.out")"
grep -l 'steer held' "$inbox"/*.msg >/dev/null 2>&1 || fail "the held-composer steer did not land in the host inbox"
assert_grep 'doorbell skipped (composer visibly holds pending text)' "$TMP_ROOT/send-held.out" \
  "a held composer was not reported"
[ ! -s "$HC_STATE/sent" ] || fail "the doorbell was typed over the operator's text: $(cat "$HC_STATE/sent")"
rm -f "$HC_STATE/screen"
pass "a composer holding text gets no doorbell, and the steer is still recorded"

# --- a stopped core reads unreadable and is never started --------------------

stop_hc_core_socket "$CORE_SOCK"
before=$(calls)
[ "$(ctl state "$ID")" = unreadable ] || fail "a silent core did not read unreadable"
ctl send "$ID" "steer two" > "$TMP_ROOT/send-down.out" 2>&1
expect_code 0 "$?" "a steer with a silent core did not still record durably"
assert_grep 'doorbell did not reach' "$TMP_ROOT/send-down.out" "the silent-core doorbell was not reported"
if ctl capture "$ID" 5 >/dev/null 2>&1; then fail "a capture ran against a silent core"; fi
if ctl control "$ID" exit >/dev/null 2>&1; then fail "an exit ran against a silent core"; fi
[ "$(calls)" = "$before" ] || fail "a probe contacted hc while its core was silent: $(tail -3 "$HC_STATE/log")"
start_hc_core_socket "$CORE_SOCK"
pass "with a silent core, state reads unreadable and no verb contacts hc"

# --- dead and finished terminals are replaced on relaunch -----------------------

jq '.foreground.name="zsh" | .foreground.argv=["zsh"]' "$HC_STATE/t1.json" > "$HC_STATE/t1.new" && mv "$HC_STATE/t1.new" "$HC_STATE/t1.json"
[ "$(ctl state "$ID")" = dead ] || fail "an agent-free hc terminal did not read dead"
ctl launch "$ID" omp - - hc > "$TMP_ROOT/relaunch-dead.out" 2>&1 \
  || fail "a dead hc mate was not relaunched: $(cat "$TMP_ROOT/relaunch-dead.out")"
assert_absent "$HC_STATE/t1.json" "the dead terminal was not closed before the replacement"
assert_grep "target=$SESSION:t2" "$TMP_ROOT/relaunch-dead.out" "the replacement terminal was not recorded"
jq '.state="finished" | .foreground=null' "$HC_STATE/t2.json" > "$HC_STATE/t2.new" && mv "$HC_STATE/t2.new" "$HC_STATE/t2.json"
[ "$(ctl state "$ID")" = missing ] || fail "a finished hc terminal did not read missing"
ctl launch "$ID" omp - - hc > "$TMP_ROOT/relaunch-missing.out" 2>&1 \
  || fail "a finished hc mate was not relaunched: $(cat "$TMP_ROOT/relaunch-missing.out")"
assert_absent "$HC_STATE/t2.json" "the finished terminal husk was not removed"
assert_grep "target=$SESSION:t3" "$TMP_ROOT/relaunch-missing.out" "the replacement for the husk was not recorded"
pass "dead and finished hc mates are closed and replaced"

# --- move verbs: release only an agent-free endpoint, then settle -----------

if ctl move-release "$ID" hc > "$TMP_ROOT/release-alive.out" 2>&1; then
  fail "move-release released an alive endpoint"
fi
assert_grep "reads 'alive', not agent-free" "$TMP_ROOT/release-alive.out" "an alive release was not refused by name"
assert_present "$META" "a refused release moved the record"
if ctl move-release "$ID" herdr > "$TMP_ROOT/release-wrong.out" 2>&1; then
  fail "move-release accepted the wrong recorded backend"
fi
assert_grep "not 'herdr'" "$TMP_ROOT/release-wrong.out" "a wrong-backend release was not refused by name"
jq '.foreground.name="zsh" | .foreground.argv=["zsh"]' "$HC_STATE/t3.json" > "$HC_STATE/t3.new" && mv "$HC_STATE/t3.new" "$HC_STATE/t3.json"
cp "$META" "$TMP_ROOT/meta-before-release"
ctl move-release "$ID" hc > "$TMP_ROOT/release.out" 2>&1 || fail "an agent-free release failed: $(cat "$TMP_ROOT/release.out")"
assert_absent "$META" "a release left the endpoint record in place"
assert_absent "$HC_STATE/t3.json" "a release left the agent-free terminal open"
ctl move-settle "$ID" restore > "$TMP_ROOT/settle.out" 2>&1 || fail "restore failed: $(cat "$TMP_ROOT/settle.out")"
cmp -s "$TMP_ROOT/meta-before-release" "$META" || fail "restore did not put the exact previous record back"
ctl move-release "$ID" hc >/dev/null 2>&1 || fail "a second release of the now-missing endpoint failed"
cp "$TMP_ROOT/meta-before-release" "$META"
if ctl move-settle "$ID" restore > "$TMP_ROOT/settle-newer.out" 2>&1; then
  fail "restore overwrote a newer record"
fi
assert_grep 'already has a newer endpoint record' "$TMP_ROOT/settle-newer.out" "a blocked restore was not explained"
ctl move-settle "$ID" drop >/dev/null || fail "drop failed"
# A host that holds no endpoint record (a route never launched there, or one
# whose record was lost) has nothing to close: the release succeeds and a
# later restore has nothing to put back.
rm -f "$META"
ctl move-release "$ID" herdr > "$TMP_ROOT/release-none.out" 2>&1 \
  || fail "a release with no host record failed: $(cat "$TMP_ROOT/release-none.out")"
assert_grep 'no endpoint record on this host' "$TMP_ROOT/release-none.out" "a recordless release did not say so"
ctl move-settle "$ID" restore > "$TMP_ROOT/settle-none.out" 2>&1 \
  || fail "a restore with nothing set aside failed: $(cat "$TMP_ROOT/settle-none.out")"
assert_absent "$META" "a restore with nothing set aside created a record"
pass "move-release frees only an agent-free endpoint, and settle restores or drops it"

# --- host lifecycle control: exit and relaunch of an hc second mate ----------

ctl launch "$ID" omp - - hc > "$TMP_ROOT/launch-for-control.out" 2>&1 \
  || fail "the mate could not be launched for control: $(cat "$TMP_ROOT/launch-for-control.out")"
target=$(sed -n 's/^target=//p' "$TMP_ROOT/launch-for-control.out" | tail -1)
[ "$(ctl state "$ID")" = alive ] || fail "the mate did not read alive before control"
ctl control "$ID" exit > "$TMP_ROOT/exit.out" 2>&1 \
  || fail "the host exit of an hc second mate failed: $(cat "$TMP_ROOT/exit.out")"
[ "$(ctl state "$ID")" = dead ] || fail "the exited hc mate did not read dead"
grep -qx '/quit' "$HC_STATE/sent" || fail "the exit did not submit omp's exit command"
: > "$HC_STATE/sent"
ctl relaunch "$ID" omp default default > "$TMP_ROOT/relaunch.out" 2>&1 \
  || fail "the host relaunch of an hc second mate failed: $(cat "$TMP_ROOT/relaunch.out")"
assert_grep "target=$target" "$TMP_ROOT/relaunch.out" "the relaunch did not keep the mate's terminal"
[ "$(ctl state "$ID")" = alive ] || fail "the relaunched hc mate did not read alive"
launch_line=$(grep "^\. '" "$HC_STATE/sent" | tail -1)
launch_file=${launch_line#. \'}
launch_file=${launch_file%\'}
[ -n "$launch_line" ] || fail "the relaunch typed no launch line"
assert_present "$launch_file" "the relaunch's launch file is not where its launch line points"
grep -q -- '--config' "$launch_file" || fail "the replacement omp launch lacks Firstmate's --config wiring"
pass "host control exits and relaunches an hc second mate in its own terminal"

echo "ALL TESTS PASSED"
