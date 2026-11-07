#!/usr/bin/env bash
# tests/fm-secondmate-convert-remote.test.sh - bin/fm-secondmate-move.sh
# --remote: a live local hc second mate converted in place into a remote route
# on the same machine.
#
# The parent home, the mate's home, and the "host" all live on this machine,
# exactly as in a real conversion. A fake ssh stands in for the SSH alias: it
# decodes the fixed entrypoint's argv and runs the named host command under the
# environment the remote job worker gives it (FM_HOME at the mate's home,
# FM_ROOT_OVERRIDE at the host code root), answering only the readiness doctor
# itself. The hc core is the stateful fake from tests/hc-fake-fixture.sh with a
# real unix socket standing in for an answering core, shared by the local mate
# and the converted one, as one machine's core is.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/hc-fake-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/hc-fake-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-secondmate-convert-remote)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
SOCK_ROOT=$(mktemp -d /tmp/fmcvt.XXXXXX)
SOCK_ROOT=$(cd "$SOCK_ROOT" && pwd -P)
CLAIMS="$TMP_ROOT/claims"
SHELL_PID=
cleanup_convert() {
  local w
  for w in "$TMP_ROOT"/w-*; do
    [ -d "$w/parent" ] || continue
    FM_HOME="$w/parent" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
      "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  stop_hc_core_socket "$SOCK_ROOT/none" 2>/dev/null || true
  [ -z "$SHELL_PID" ] || kill "$SHELL_PID" 2>/dev/null || true
  rm -rf "$SOCK_ROOT"
  fm_test_cleanup
}
trap cleanup_convert EXIT
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
ID=sm1
SESSION=fmcvt-lab
ALIAS=self-lab

# --- shared fakes -------------------------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT/tools")
write_hc_fake_cli "$FAKEBIN/herdr-core" "$TMP_ROOT/hc-unused"
ln -sf "$(command -v git)" "$FAKEBIN/git"
ln -sf "$(command -v jq)" "$FAKEBIN/jq"
ln -sf "$(command -v python3)" "$FAKEBIN/python3"
ln -sf "$(command -v perl)" "$FAKEBIN/perl"
fm_fake_exit0 "$FAKEBIN" node treehouse no-mistakes gh gh-axi chrome-devtools-axi lavish-axi quota-axi
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != models ] || printf '%s\n' '{"models":[]}'
exit 0
SH
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.6' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/omp" "$FAKEBIN/tasks-axi"

# The SSH alias. Its mode file picks the host's answer: ready (default),
# unready, unreachable, or other-host (the alias reaches a different machine,
# so the home's identity differs). Every host command is logged.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1; entry=$2; shift 2
[ "$host" = "$FM_FAKE_ALIAS" ] || exit 255
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
root=$(printf '%s' "$2" | perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)')
home=$(printf '%s' "$3" | perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)')
argv=()
while IFS= read -r -d '' a; do argv+=("$a"); done \
  < <(printf '%s' "$4" | perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)')
mode=$(cat "$FM_FAKE_W/ssh-mode" 2>/dev/null || printf ready)
printf '%s\n' "${argv[*]}" >> "$FM_FAKE_W/ssh.log"
[ "$mode" != unreachable ] || exit 255
case "${argv[0]}" in
  fm-remote-doctor.sh)
    if [ "$mode" = unready ]; then
      printf 'check hc-core=human: no hc core answers for session %s on this account\n' "$FM_FAKE_SESSION"
      exit 1
    fi
    printf 'ok: remote second-mate readiness confirmed on this host\n'
    exit 0
    ;;
  fm-remote-secondmate-control.sh)
    if [ "${argv[1]}" = identity ] && [ "$mode" = other-host ]; then
      printf 'schema=fm-remote-secondmate-control.v1\nuid=%s\nhome=1:2\n' "$(id -u)"
      exit 0
    fi
    if [ "${argv[1]}" = launch ] && [ -e "$FM_FAKE_W/launch-fails" ]; then
      printf 'error: remote host-local secondmate launch failed\n' >&2
      exit 1
    fi
    ;;
esac
exec /usr/bin/env -i PATH="$FM_FAKE_PATH" HOME="$HOME" XDG_STATE_HOME="$FM_FAKE_SOCK_ROOT" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_REMOTE_JOB_ACTIVE=1 FM_GATE_REFUSE_BYPASS=1 \
  FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=0.5 \
  "$root/bin/${argv[0]}" "${argv[@]:1}"
SH
chmod +x "$FAKEBIN/ssh"

# One real shell alone in its own process group, so an hc terminal whose
# agent has exited reads as an agent-free shell.
mkfifo "$TMP_ROOT/shell.fifo"
perl -e 'setpgrp(0, 0); exec "/bin/sh", "-c", "read x < \"\$0\"", $ARGV[0]' "$TMP_ROOT/shell.fifo" &
SHELL_PID=$!
CORE_SOCK="$SOCK_ROOT/herdr-core/$SESSION/$SESSION.sock"
start_hc_core_socket "$CORE_SOCK"

# The host code root: a separate Firstmate checkout, as --root requires.
HOST_ROOT="$TMP_ROOT/host-root"
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (mkdir -p "$HOST_ROOT" && cd "$HOST_ROOT" && tar -xf -)
fm_git_identity "$HOST_ROOT" 2>/dev/null || true
git -C "$HOST_ROOT" init -q -b main
git -C "$HOST_ROOT" -c user.email=t@example.com -c user.name=T add -A
git -C "$HOST_ROOT" -c user.email=t@example.com -c user.name=T commit -qm 'host root'

# --- one world: a parent home with one live local hc mate ------------------

# new_world <name>: sets W, PARENT, MHOME, HC_DIR. The mate was launched by
# the real local launch; its home holds a lane record, a parked lane copy with
# an unpushed commit, a backlog item, a charter naming the parent's paths, and
# the parent holds its status stream and steering inbox.
new_world() {
  W="$TMP_ROOT/w-$1"
  PARENT="$W/parent"
  MHOME="$W/home-$ID"
  HC_DIR="$W/hc"
  mkdir -p "$PARENT/data/$ID" "$PARENT/state" "$PARENT/config" "$MHOME/bin" "$MHOME/data" \
    "$MHOME/state" "$MHOME/config" "$MHOME/projects" "$HC_DIR"
  write_hc_fake_cli "$W/bin/herdr-core" "$HC_DIR"
  printf '%s\n' "$SHELL_PID" > "$HC_DIR/shell-pid"
  printf 'omp\n' > "$PARENT/config/secondmate-harness"
  printf '# Firstmate\n' > "$MHOME/AGENTS.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' > "$MHOME/.gitignore"
  git -C "$MHOME" init -q -b main
  printf '%s\n' "$ID" > "$MHOME/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$MHOME/.fm-secondmate-parent"
  printf '%s\n' "$SESSION" > "$MHOME/config/hc-session"
  cat > "$PARENT/data/$ID/brief.md" <<EOF
# Charter
Lab work.
# Routing scope
lab
# Return channel
Append to $PARENT/state/$ID.status. Steering waits in $PARENT/state/$ID.inbox; list $PARENT/state/$ID.inbox/*.msg and move each to $PARENT/state/$ID.inbox/handled/.
EOF
  cp "$PARENT/data/$ID/brief.md" "$MHOME/data/charter.md"
  printf '## In flight\n\n## Queued\n\n- [ ] lab-item - keep me\n\n## Done\n' > "$MHOME/data/backlog.md"
  printf -- '- %s - Lab work (home: %s; scope: lab; projects: ; added 2026-11-01)\n' "$ID" "$MHOME" > "$PARENT/data/secondmates.md"
  # A lane record and a parked lane copy holding an unpushed commit.
  git -C "$W" init -q -b main lane-copy
  git -C "$W/lane-copy" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m 'unpushed lane work'
  printf 'window=%s:t9\nbackend=hc\nhc_session=%s\nhc_terminal=t9\nkind=ship\nworktree=%s\n' \
    "$SESSION" "$SESSION" "$W/lane-copy" > "$MHOME/state/lane1.meta"
  printf 'working [at=1794000000]: lane1 started\n' > "$MHOME/state/lane1.status"
  # The real local launch, as the parent ran it.
  pexec "$ROOT/bin/fm-spawn.sh" "$ID" "$MHOME" --secondmate --backend hc --harness omp > "$W/local-launch.out" 2>&1 \
    || fail "the local hc mate could not be launched for the world"$'\n'"$(cat "$W/local-launch.out")"
  # Status lines the mate already wrote, and one unread and one handled steer.
  printf 'working [at=1794000100]: first note\nneeds-decision [at=1794000200] [key=k1]: pick a\nresolved [at=1794000300] [key=k1]: picked a\n' \
    >> "$PARENT/state/$ID.status"
  mkdir -p "$PARENT/state/$ID.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=2026-11-01T00:00:00Z\n--\nold steer\n' > "$PARENT/state/$ID.inbox/handled/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=2026-11-01T00:00:01Z\n--\nunread steer\n' > "$PARENT/state/$ID.inbox/002.msg"
  : > "$W/ssh.log"
}

pexec() {  # run a parent-side command in the world
  env -u HC_SOCKET -u FM_HC_SOCKET -u FM_HC_BIN -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE \
    -u XDG_RUNTIME_DIR -u FM_ROOT_OVERRIDE -u FM_BACKEND -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_TASK_ID -u FM_TASK_INBOX \
    PATH="$W/bin:$FAKEBIN:$BASE_PATH" TMUX='' HC_SESSION="$SESSION" XDG_STATE_HOME="$SOCK_ROOT" \
    FM_HOME="$PARENT" FM_SSH_BIN="$FAKEBIN/ssh" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" FM_FAKE_W="$W" FM_FAKE_ALIAS="$ALIAS" FM_FAKE_SESSION="$SESSION" \
    FM_FAKE_SOCK_ROOT="$SOCK_ROOT" FM_FAKE_PATH="$W/bin:$FAKEBIN:$BASE_PATH" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=0.5 \
    "$@"
}

convert() { pexec "$ROOT/bin/fm-secondmate-move.sh" "$ID" --remote "$ALIAS" --root "$HOST_ROOT" 2>&1; }

# snapshot <file>: every durable record the conversion may touch, so a refusal
# can be proven to have changed nothing.
snapshot() {
  {
    for f in "$PARENT/state/$ID.meta" "$PARENT/state/$ID.status" "$PARENT/data/secondmates.md" \
      "$MHOME/.fm-secondmate-parent" "$MHOME/data/charter.md" "$MHOME/data/backlog.md" \
      "$MHOME/state/lane1.meta"; do
      printf '== %s\n' "$f"; cat "$f" 2>/dev/null || printf '(absent)\n'
    done
    printf '== inbox\n'; (cd "$PARENT/state" && find "$ID.inbox" -type f 2>/dev/null | sort)
    printf '== home parent-route\n'; ls -A "$MHOME/state/parent-route" 2>/dev/null || true
    printf '== relay log\n'; cat "$MHOME/state/parent-replies.status" 2>/dev/null || printf '(absent)\n'
    printf '== cursor\n'; ls -A "$PARENT/state/remote-replies" 2>/dev/null || true
    printf '== terminals\n'; ls "$HC_DIR"/t*.json 2>/dev/null
  } > "$1"
}

state_word() { jq -r '.foreground.name // "none"' "$HC_DIR/$1.json" 2>/dev/null || printf absent; }

# --- refusals: each fires before anything is stopped or changed --------------

test_refusals_change_nothing() {
  local scenario out rc
  for scenario in remote-already other-machine-home other-host unreachable unready open-request \
    root-is-parent bad-root other-core; do
    new_world "refuse-$scenario"
    case "$scenario" in
      remote-already)
        printf 'remote_host=elsewhere\nremote_backend=hc\n' >> "$PARENT/state/$ID.meta" ;;
      other-machine-home)
        # The registry and record name a home this machine does not hold.
        sed -i.bak "s|$MHOME|/nonexistent/home-$ID|g" "$PARENT/data/secondmates.md" "$PARENT/state/$ID.meta"
        rm -f "$PARENT/data/secondmates.md.bak" "$PARENT/state/$ID.meta.bak" ;;
      other-host) printf 'other-host\n' > "$W/ssh-mode" ;;
      unreachable) printf 'unreachable\n' > "$W/ssh-mode" ;;
      unready) printf 'unready\n' > "$W/ssh-mode" ;;
      open-request)
        mkdir -p "$PARENT/state/pending-replies"
        printf 'corr_id=0123456789abcdef\ntask_id=%s\nphase=delivered\n' "$ID" > "$PARENT/state/pending-replies/0123456789abcdef" ;;
      root-is-parent)
        # A real parent home is itself a Firstmate checkout.
        mkdir -p "$PARENT/bin" && : > "$PARENT/bin/fm-remote-entrypoint.sh" ;;
      bad-root) ;;
      other-core) printf 'some-other-core\n' > "$MHOME/config/hc-session" ;;
    esac
    snapshot "$W/before"
    rc=0
    case "$scenario" in
      root-is-parent) out=$(pexec "$ROOT/bin/fm-secondmate-move.sh" "$ID" --remote "$ALIAS" --root "$PARENT" 2>&1) || rc=$? ;;
      bad-root) out=$(pexec "$ROOT/bin/fm-secondmate-move.sh" "$ID" --remote "$ALIAS" --root "$W/no-root" 2>&1) || rc=$? ;;
      *) out=$(convert) || rc=$? ;;
    esac
    [ "$rc" -ne 0 ] || fail "$scenario: the conversion must refuse"$'\n'"$out"
    [ "$(state_word t1)" = omp ] || fail "$scenario: the refusal must leave the local agent running"
    snapshot "$W/after"
    cmp -s "$W/before" "$W/after" || fail "$scenario: the refusal changed a record"$'\n'"$(diff "$W/before" "$W/after")"
    if grep -v -e '^fm-remote-doctor.sh' -e '^fm-remote-secondmate-control.sh identity' "$W/ssh.log" | grep -q .; then
      fail "$scenario: only the identity and readiness reads may reach the host: $(cat "$W/ssh.log")"
    fi
    [ ! -e "$PARENT/state/.secondmate-relaunch-$ID" ] || fail "$scenario: a refusal recorded a relaunch attempt"
    case "$scenario" in
      remote-already) assert_contains "$out" "already a remote route on elsewhere" "$scenario names the route" ;;
      other-machine-home) assert_contains "$out" "is not a directory on this machine" "$scenario names the home" ;;
      other-host) assert_contains "$out" "does not reach this account and this home on this machine" "$scenario names the mismatch" ;;
      unreachable) assert_contains "$out" "unreachable or its answer is unknown" "$scenario names the transport" ;;
      unready) assert_contains "$out" "is not ready for backend=hc (check hc-core=human" "$scenario quotes the doctor" ;;
      open-request) assert_contains "$out" "unresolved routed request" "$scenario names the request" ;;
      root-is-parent) assert_contains "$out" "not this parent home" "$scenario names the root" ;;
      bad-root) assert_contains "$out" "is not a Firstmate code root on this machine" "$scenario names the root" ;;
      other-core) assert_contains "$out" "config/hc-session resolves to 'some-other-core'" "$scenario names the core" ;;
    esac
    assert_contains "$out" "nothing was stopped or converted" "$scenario must say nothing changed"
  done
  pass "convert: every refusal fires before the stop and leaves the agent, records, inbox, and home unchanged"
}

# --- the conversion -------------------------------------------------------------

test_conversion_rebinds_carries_and_relaunches() {
  local out rc=0 meta target addr launch_line launch_file line count
  new_world converts
  local backlog_before lane_before
  backlog_before=$(cat "$MHOME/data/backlog.md")
  lane_before=$(cat "$MHOME/state/lane1.meta")
  out=$(convert) || rc=$?
  expect_code 0 "$rc" "the conversion failed"$'\n'"$out"
  assert_contains "$out" "moved $ID from=hc to=hc host=$ALIAS" "the conversion must report the route change"
  assert_contains "$out" "spawned $ID harness=omp kind=secondmate" "the conversion must relay the launch line"

  # The old local agent was stopped through its exit command and its terminal closed.
  grep -qx '/quit' "$HC_DIR/sent" || fail "the local agent was not stopped through its exit command"
  assert_absent "$HC_DIR/t1.json" "the old local terminal was not closed"

  # The parent record and registry are the remote form a seed would have produced.
  meta=$(cat "$PARENT/state/$ID.meta")
  for line in "remote_host=$ALIAS" "remote_root=$HOST_ROOT" remote_backend=hc "remote_hc_session=$SESSION" \
    "home=$MHOME" harness=omp kind=secondmate "window=remote:$ID"; do
    assert_contains "$meta" "$line" "the remote record must carry $line"
  done
  assert_grep "(host: $ALIAS; root: $HOST_ROOT; home: $MHOME; scope: lab; projects: ; added 2026-11-01)" \
    "$PARENT/data/secondmates.md" "the registry entry is not the remote form"

  # The home's parent binding and charter match the remote seed's output.
  assert_equals "$(cat "$MHOME/.fm-secondmate-parent")" \
    "$(printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=%s' "$ALIAS")" "the home binding is not remote"
  assert_grep "Append to $MHOME/state/parent-replies.status." "$MHOME/data/charter.md" "the charter status path was not rewritten"
  assert_grep "list $MHOME/state/parent-route/$ID.inbox/*.msg" "$MHOME/data/charter.md" "the charter inbox path was not rewritten"
  assert_no_grep "$PARENT/state" "$MHOME/data/charter.md" "the charter still names a parent path"

  # Home, backlog, lanes, and the parked copy are untouched.
  assert_equals "$(cat "$MHOME/data/backlog.md")" "$backlog_before" "the backlog changed"
  assert_equals "$(cat "$MHOME/state/lane1.meta")" "$lane_before" "the lane record changed"
  assert_equals "$(git -C "$W/lane-copy" log -1 --format=%s)" "unpushed lane work" "the parked commit was lost"

  # The steering inbox moved with its unread and handled records.
  assert_present "$MHOME/state/parent-route/$ID.inbox/002.msg" "the unread steer was not carried"
  assert_present "$MHOME/state/parent-route/$ID.inbox/handled/001.msg" "the handled steer was not carried"
  assert_absent "$PARENT/state/$ID.inbox" "the parent-side inbox was left behind"

  # The relay log holds the old stream; the mirror starts after it.
  cmp -s "$PARENT/state/$ID.status" "$MHOME/state/parent-replies.status" \
    || fail "the relay log does not start with the parent stream"
  assert_grep "offset=$(wc -c < "$MHOME/state/parent-replies.status" | tr -d ' ')" \
    "$PARENT/state/remote-replies/$ID.cursor" "the reply cursor was not committed at the end of the carried stream"

  # The new terminal is a remote launch on the same core, wired for omp.
  target=$(sed -n 's/^remote_target=//p' "$PARENT/state/$ID.meta")
  addr=${target#*:}
  [ "$(state_word "$addr")" = omp ] || fail "the converted mate is not running in $target"
  assert_grep "firstmate.home" "$HC_DIR/$addr.json" "the new terminal lacks its identity labels"
  launch_line=$(grep "^\. '" "$HC_DIR/sent" | tail -1)
  launch_file=${launch_line#. \'}
  launch_file=${launch_file%\'}
  grep -q -- '--config' "$launch_file" || fail "the remote omp launch lacks its --config wiring"
  assert_present "$MHOME/state/parent-route/$ID.meta" "the host holds no endpoint record"
  pass "convert: a live local hc mate becomes a remote route with its home, lanes, backlog, inbox, and stream intact"

  # One new line through the relay is mirrored once; the old lines never again.
  printf 'working [at=1794000400]: after the switch\n' >> "$MHOME/state/parent-replies.status"
  local seq=1 result
  result="$W/delta.result"
  pexec "$ROOT/bin/fm-on.sh" "$ID" fm-remote-delta-read.sh state/parent-replies.status \
    "$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/$ID.cursor")" \
    "$(sed -n 's/^prefix_sha256=//p' "$PARENT/state/remote-replies/$ID.cursor")" 1 > "$result" \
    || fail "the delta read after the switch failed"
  pexec "$ROOT/bin/fm-procevent-remote-reply.sh" ingest "$ID" "$result" > "$W/ingest.out" 2>&1 \
    || fail "the delta after the switch was not ingested: $(cat "$W/ingest.out")"
  for line in 'first note' 'pick a' 'picked a' 'after the switch'; do
    count=$(grep -c -- "$line" "$PARENT/state/$ID.status")
    assert_equals "$count" 1 "the status line '$line' must be present exactly once"
  done
  : "$seq"
  pass "convert: the old status lines stay once and a new relay line is mirrored once"

  # Steering reaches the converted mate through the remote path.
  : > "$HC_DIR/sent"
  pexec "$ROOT/bin/fm-send.sh" "fm-$ID" 'after conversion' > "$W/send.out" 2>&1 \
    || fail "a steer to the converted mate failed: $(cat "$W/send.out")"
  grep -l 'after conversion' "$MHOME/state/parent-route/$ID.inbox"/*.msg >/dev/null 2>&1 \
    || fail "the steer did not land in the carried inbox"
  [ ! -e "$MHOME/state/parent-route/$ID.inbox/003.msg" ] || assert_grep 'after conversion' \
    "$MHOME/state/parent-route/$ID.inbox/003.msg" "the steer did not continue the carried sequence"
  assert_grep "$ID.inbox" "$HC_DIR/sent" "the doorbell did not reach the converted mate"
  pass "convert: a steer reaches the converted mate's carried inbox and rings its terminal"

  # A second conversion refuses: the mate is remote now.
  rc=0
  out=$(convert) || rc=$?
  [ "$rc" -ne 0 ] || fail "a second conversion was accepted"
  assert_contains "$out" "already a remote route on $ALIAS" "a second conversion must name the existing route"
  pass "convert: a converted mate refuses another conversion"
}

test_failed_launch_restores_the_local_route() {
  local out rc=0
  new_world launch-fails
  : > "$W/launch-fails"
  snapshot "$W/before"
  cp -p "$PARENT/state/$ID.meta" "$W/meta.before"
  out=$(convert) || rc=$?
  expect_code 1 "$rc" "a conversion whose remote launch fails must fail"$'\n'"$out"
  grep -qx '/quit' "$HC_DIR/sent" || fail "the failure case must have stopped the agent first"
  assert_contains "$out" "could not be launched as a remote route on $ALIAS" "the failure names the launch"
  assert_contains "$out" "previous local route and record are restored" "the failure says the route was restored"
  # The stop itself clears the busy generation (bin/fm-control.sh exit); every
  # other byte of the record is the previous local one.
  diff <(grep -v '^busy_gen=' "$W/meta.before") "$PARENT/state/$ID.meta" >/dev/null \
    || fail "the local record was not restored"$'\n'"$(diff "$W/meta.before" "$PARENT/state/$ID.meta" 2>&1)"
  # The old terminal is closed and the agent stopped; every record is the previous local form.
  snapshot "$W/after"
  diff <(grep -v -e '^/' -e '^== terminals' -e '^busy_gen=' "$W/before") <(grep -v -e '^/' -e '^== terminals' "$W/after") >/dev/null \
    || fail "a failed launch left a changed record"$'\n'"$(diff "$W/before" "$W/after")"
  assert_grep 'failed' "$PARENT/state/.secondmate-relaunch-$ID" "the failed attempt was not recorded"
  # Recovery then respawns the mate locally on its recorded backend.
  out=$(pexec "$ROOT/bin/fm-spawn.sh" "$ID" --secondmate --backend hc 2>&1) \
    || fail "the restored local route could not be respawned: $out"
  assert_contains "$out" "spawned $ID harness=omp kind=secondmate" "the restored route did not respawn locally"
  assert_not_contains "$(cat "$PARENT/state/$ID.meta")" remote_host "the respawn must stay local"
  pass "convert: a failed remote launch restores the previous local route, and recovery respawns it locally"
}

test_refusals_change_nothing
test_conversion_rebinds_carries_and_relaunches
test_failed_launch_restores_the_local_route
echo "ALL TESTS PASSED"
