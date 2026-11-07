#!/usr/bin/env bash
# fm-secondmate-move.sh - move a persistent second mate onto another runtime
# backend, keeping its home, records, and backlog exactly as they are.
#
# Usage: fm-secondmate-move.sh <secondmate-id> --backend <name>
#
# A second mate's home holds its state, backlog, charter, and projects; this
# home's state/<id>.meta only names the endpoint its agent runs in. A move
# therefore never touches the home. It stops the agent, closes the old
# endpoint, and respawns the mate through the one owner every recovery already
# uses - `bin/fm-spawn.sh <id> --secondmate` - with the target backend passed
# explicitly. The record that spawn republishes IS the move; nothing is
# hand-edited.
#
# The whole sequence runs under the mate's liveness lock
# (bin/fm-secondmate-liveness-lib.sh), so neither the session-start sweep nor
# the watcher's liveness tick can respawn the mate on its old backend between
# the stop and the new launch:
#   1. the recorded endpoint is probed;
#   2. an alive agent is stopped with `bin/fm-control.sh <id> exit`, which
#      proves the stop or refuses (a pending composer, an endpoint it cannot
#      prove absent, a backend with no recovery-grade classifier), and the
#      mate is probed again;
#   3. only a dead or confidently missing endpoint proceeds: a dead one is
#      closed, and the respawn lands on the target backend through
#      fm_secondmate_liveness_relaunch with that backend named, which records
#      the attempt and its outcome in the ordinary relaunch ledger.
# An ambiguous, unreadable, or unverified endpoint refuses before anything is
# stopped. A mate recorded with no endpoint at all is simply launched on the
# target backend.
#
# A remote mate (a record with remote_host=) moves on its own host, and only
# onto that host's hc core (docs/remote-secondmates.md "Move a remote second
# mate onto hc"). Before anything is stopped it refuses any other target, a
# move onto the backend already recorded, and a host the hc readiness gate
# (bin/fm-remote-readiness-lib.sh with --backend hc) reports unready or
# cannot reach. Under the same locks it then stops an alive agent with the
# host's own `control <id> exit`, has the host close the agent-free endpoint
# and set its record aside (`move-release`), and respawns the mate through
# fm_secondmate_liveness_relaunch with hc named. A failed launch has the host
# restore its set-aside record (`move-settle restore`) and leaves this home's
# record as it was, so the next liveness recovery respawns the mate on its
# previous backend; a completed one drops the set-aside record. A launch
# whose completion is unknown (exit 255) may still be running on the host, so
# the set-aside record is kept for the operator to settle there.
#
# The target must be a spawn-capable backend that hosts second mates
# (bin/fm-backend.sh's FM_BACKEND_SECONDMATE) and must be ready to launch one:
# its own CLI and toolchain present, and for hc and rex its core or server
# reachable, through the same adapter checks fm-spawn runs. All of that is
# checked before anything is stopped. Recovery keeps a local mate on its
# recorded backend (PR #8082), so a completed move needs no config/backend
# change to last. The record is snapshotted before the launch; a launch that
# fails after the stop has its previous record put back under the record's
# meta lock, so the next liveness recovery respawns the mate on its previous,
# recorded backend; a different record found in place by then is left alone.
# The failure says which of those happened.
#
# Prints `moved <id> from=<old-backend> to=<new-backend>` (plus `host=<alias>`
# for a remote move) followed by the
# spawn's own `spawned ...` line. Exit status: 0 moved; 1 refused or failed,
# with the message naming the state the mate was left in; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,/^set -u/{/^#/{s/^# \{0,1\}//;p;};}' "$0"
}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

first_line() {  # <text>
  local line
  line=$(printf '%s\n' "$1" | sed -n '/^error: /{p;q;}')
  [ -n "$line" ] || line=$1
  printf '%s\n' "$line" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
LIVENESS_LOCK_HELD=0
SNAPSHOT=
# shellcheck disable=SC2329 # Registered by the EXIT trap in move_lock.
move_cleanup() {
  [ -z "$SNAPSHOT" ] || rm -f "$SNAPSHOT"
  [ "$LIVENESS_LOCK_HELD" != 1 ] || fm_secondmate_liveness_unlock "$ID"
  [ "$CONTROL_LOCK_HELD" != 1 ] || fm_lock_release "$CONTROL_LOCK" 2>/dev/null || true
}

# A relaunch (bin/fm-control.sh) takes the task's control lock rather than the
# liveness lock, so the move holds that lock too, across the probe, the stop,
# the close, and the launch: no relaunch can start an agent in an endpoint this
# move read as dead. The stop below runs as this process's child, and fm-control
# accepts the lock from its parent the way fm-spawn --relaunch does; a fresh
# --secondmate spawn never takes it.
move_lock() {
  fm_sm_live_require_locks || die "the lock helpers could not be loaded; nothing was stopped or moved"
  CONTROL_LOCK="$STATE/.control-$ID.lock"
  fm_lock_try_acquire "$CONTROL_LOCK" \
    || die "another lifecycle action is already running for second mate $ID; retry once it finishes"
  CONTROL_LOCK_HELD=1
  trap move_cleanup EXIT
  fm_secondmate_liveness_lock "$ID" \
    || die "another liveness check or recovery is in progress for second mate $ID; retry once it finishes"
  LIVENESS_LOCK_HELD=1
}

# remote_host_call <verb> <args...>: one host control verb through fm-on.
# Prints its combined output; returns its status, 255 for unknown completion.
remote_host_call() {
  "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh "$@" </dev/null 2>&1
}

# The remote path (header): a remote mate moves only on its own host, from its
# recorded backend onto that host's hc core. Every refusal before the stop
# leaves the mate running and both records unchanged.
remote_move() {
  local old harness rc=0 out stopped=0
  [ "$TARGET" = hc ] \
    || die "a remote second mate moves only onto its host's hc core, not backend=$TARGET; nothing was stopped or moved"
  old=$(fm_meta_get "$META" remote_backend)
  [ -n "$old" ] || old=herdr
  [ "$old" != "$TARGET" ] \
    || die "second mate $ID is already recorded on backend=$TARGET on $REMOTE_HOST; to restart it in place use bin/fm-control.sh $ID relaunch"
  harness=$(fm_meta_get "$META" harness)
  [ -n "$harness" ] || die "remote second mate $ID's route record names no harness; nothing was stopped or moved"
  fm_remote_readiness_ensure "$SCRIPT_DIR" "$ID" "$TARGET" "$harness" || rc=$?
  [ "$rc" -ne 255 ] \
    || die "remote host $REMOTE_HOST is unreachable or its readiness is unknown; nothing was stopped or moved"
  [ "$rc" -eq 0 ] \
    || die "remote host $REMOTE_HOST is not ready for backend=$TARGET ($(printf '%s\n' "$FM_REMOTE_READINESS_OUT" | awk '/^check [^=]+=(fixable|human):|^error:/ { print; exit }')); nothing was stopped or moved"
  move_lock
  fm_secondmate_liveness_probe "$META" "$ID" poll
  case "$FM_SM_LIVE_STATUS" in
    silent) ;;
    alive)
      rc=0
      out=$(remote_host_call control "$ID" exit) || rc=$?
      [ "$rc" -ne 255 ] \
        || die "the stop of second mate $ID's $old agent on $REMOTE_HOST has unknown completion; nothing was moved and its record is unchanged"
      [ "$rc" -eq 0 ] \
        || die "second mate $ID's agent on $old could not be proven stopped, so nothing was moved and its record is unchanged: $(first_line "$out")"
      stopped=1
      fm_secondmate_liveness_probe "$META" "$ID" poll
      [ "$FM_SM_LIVE_STATUS" = relaunchable ] \
        || die "after the stop, second mate $ID's endpoint reads '$FM_SM_LIVE_STATE' rather than agent-free, so the move stops here with its record unchanged and no replacement launched"
      ;;
    relaunchable) ;;
    *) die "second mate $ID's endpoint cannot be classified ($FM_SM_LIVE_REASON); nothing was stopped or moved" ;;
  esac
  if [ "$FM_SM_LIVE_STATUS" != silent ]; then
    rc=0
    out=$(remote_host_call move-release "$ID" "$old") || rc=$?
    if [ "$rc" -ne 0 ]; then
      [ "$stopped" = 1 ] || die "second mate $ID's $old endpoint on $REMOTE_HOST was not released ($(first_line "$out")); nothing was stopped or moved"
      die "second mate $ID's $old agent was stopped, but its endpoint on $REMOTE_HOST was not released ($(first_line "$out")); both records are unchanged, so the next liveness recovery respawns it on $old"
    fi
  fi
  SNAPSHOT="$STATE/.$ID.meta.move.$$"
  cp -p "$META" "$SNAPSHOT" || die "could not snapshot second mate $ID's record before the launch; restore its host record with 'fm-on.sh $ID fm-remote-secondmate-control.sh move-settle $ID restore'"
  if fm_secondmate_liveness_relaunch "$META" "$ID" "" "$TARGET"; then
    remote_host_call move-settle "$ID" drop >/dev/null \
      || echo "warning: second mate $ID moved, but its host kept the set-aside $old record; drop it with 'fm-on.sh $ID fm-remote-secondmate-control.sh move-settle $ID drop'" >&2
    printf 'moved %s from=%s to=%s host=%s\n' "$ID" "$old" "$TARGET" "$REMOTE_HOST"
    printf '%s\n' "$FM_SM_LIVE_OUT" | grep '^spawned ' || true
    exit 0
  fi
  [ "$FM_SM_LIVE_RC" -ne 255 ] \
    || die "the launch of second mate $ID on $TARGET on $REMOTE_HOST has unknown completion, so its host keeps the set-aside $old record; check that host for a $TARGET mate, then settle it with 'fm-on.sh $ID fm-remote-secondmate-control.sh move-settle $ID drop' if one runs or 'move-settle $ID restore' if none does: $(first_line "$FM_SM_LIVE_OUT")"
  rc=0
  out=$(remote_host_call move-settle "$ID" restore) || rc=$?
  [ "$rc" -eq 0 ] || echo "warning: the host could not restore second mate $ID's $old endpoint record: $(first_line "$out")" >&2
  if ! cmp -s "$SNAPSHOT" "$META"; then
    die "second mate $ID could not be launched on $TARGET, and a different parent record is now in place (published by the launch before a later step failed, or by another writer); that record was left as it is: $(first_line "$FM_SM_LIVE_OUT")"
  fi
  [ "$FM_SM_LIVE_STATUS" != skipped ] || [ "$stopped" = 1 ] \
    || die "second mate $ID was not moved to $TARGET; its old endpoint was already agent-free and its records are unchanged: $FM_SM_LIVE_REASON"
  die "second mate $ID could not be launched on $TARGET on $REMOTE_HOST; its previous record (backend=$old) is in place, so the next liveness recovery respawns it on $old: $(first_line "$FM_SM_LIVE_OUT")"
}

ID=
TARGET=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --backend)
      [ "$#" -ge 2 ] || { echo "error: --backend requires a value" >&2; exit 2; }
      TARGET=$2
      shift 2
      ;;
    -*)
      echo "error: unexpected argument '$1'" >&2
      usage >&2
      exit 2
      ;;
    *)
      [ -z "$ID" ] || { echo "error: exactly one second mate id is expected" >&2; exit 2; }
      ID=${1#fm-}
      shift
      ;;
  esac
done
[ -n "$ID" ] && [ -n "$TARGET" ] || { usage >&2; exit 2; }
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $ID" >&2; exit 2 ;; esac
[ -d "$STATE" ] || die "state dir '$STATE' is missing; fm-secondmate-move cannot resolve second mates for FM_HOME '$FM_HOME'"

# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no task record for $ID in $STATE; a move needs the mate's own record"
[ "$(fm_meta_get "$META" kind)" = secondmate ] || die "task $ID is not a second mate; fm-secondmate-move moves kind=secondmate records only"
REMOTE_HOST=$(fm_meta_get "$META" remote_host)
[ -z "$REMOTE_HOST" ] || remote_move

OLD_BACKEND=$(fm_backend_of_meta "$META")
[ "$OLD_BACKEND" != "$TARGET" ] || die "second mate $ID is already recorded on backend=$TARGET; to restart it in place use bin/fm-control.sh $ID relaunch"

# The harness the respawn launches comes from the same durable pin recovery
# resolves (bin/fm-harness.sh secondmate), so it is checked against the target
# here, where a refusal costs nothing: the launch owner's own check would only
# refuse it after the agent had been stopped. That owner's rule
# (fm_backend_validate_harness) is reused, not restated.
HARNESS=$("$SCRIPT_DIR/fm-harness.sh" secondmate "$ID") \
  || die "the configured second-mate harness for $ID cannot be resolved; nothing was stopped or moved"
fm_backend_validate_harness "$TARGET" "$HARNESS" \
  || die "backend=$TARGET cannot launch second mate $ID's configured harness '$HARNESS'; nothing was stopped or moved"

# Every target check runs before the agent is stopped, so an impossible move
# costs nothing.
fm_backend_validate_spawn "$TARGET" || exit 1
fm_backend_secondmate_supported "$TARGET" \
  || die "backend=$TARGET does not support --secondmate spawns yet (secondmate-capable: $FM_BACKEND_SECONDMATE)"
fm_backend_runtime_check "$TARGET" || exit 1
# The target's own tools (bin/fm-backend.sh's per-backend set, minus
# treehouse: a second mate launches in its home, never a leased worktree),
# then the reachability check fm-spawn runs before it opens an endpoint.
for TOOL in $(fm_backend_required_tools "$TARGET"); do
  [ "$TOOL" = treehouse ] || fm_backend_required_tool_available "$TARGET" "$TOOL" \
    || die "backend=$TARGET needs '$TOOL', which is not available here; nothing was stopped or moved"
done
case "$TARGET" in
  hc) fm_backend_hc_container_ensure >/dev/null || die "backend=hc is not ready to launch second mate $ID; nothing was stopped or moved" ;;
  rex) fm_backend_rex_local_server_ensure || die "backend=rex is not ready to launch second mate $ID; nothing was stopped or moved" ;;
esac

move_lock

STOPPED=0
fm_secondmate_liveness_probe "$META" "$ID" poll
case "$FM_SM_LIVE_STATUS" in
  silent)
    # No endpoint recorded: nothing to stop or close, only the launch below.
    ;;
  alive)
    # A direct child, not a command substitution: fm-control recognizes the
    # handed-down control lock by its parent pid, which a substitution's
    # subshell would hide.
    EXIT_OUT_FILE="$STATE/.$ID.move-exit.$$"
    if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-control.sh" "$ID" exit >"$EXIT_OUT_FILE" 2>&1; then
      EXIT_OUT=$(cat "$EXIT_OUT_FILE" 2>/dev/null || true)
      rm -f "$EXIT_OUT_FILE"
      die "second mate $ID's agent on $OLD_BACKEND could not be proven stopped, so nothing was moved and its record is unchanged: $(first_line "$EXIT_OUT")"
    fi
    rm -f "$EXIT_OUT_FILE"
    STOPPED=1
    fm_secondmate_liveness_probe "$META" "$ID" poll
    [ "$FM_SM_LIVE_STATUS" = relaunchable ] \
      || die "after the stop, second mate $ID's endpoint reads '$FM_SM_LIVE_STATE' rather than agent-free, so the move stops here with its record unchanged and no replacement launched"
    ;;
  relaunchable)
    ;;
  *)
    die "second mate $ID's endpoint cannot be classified ($FM_SM_LIVE_REASON); nothing was stopped or moved"
    ;;
esac

# A fresh spawn that fails rolls its record back, which removes this mate's
# existing one; the snapshot puts it back so liveness recovery still finds it.
SNAPSHOT="$STATE/.$ID.meta.move.$$"
cp -p "$META" "$SNAPSHOT" || die "could not snapshot second mate $ID's record before the launch; nothing was moved and its record is unchanged"
if fm_secondmate_liveness_relaunch "$META" "$ID" "" "$TARGET"; then
  printf 'moved %s from=%s to=%s\n' "$ID" "$OLD_BACKEND" "$TARGET"
  printf '%s\n' "$FM_SM_LIVE_OUT" | grep '^spawned ' || true
  exit 0
fi
# The restore runs under the record's meta lock, the one every record writer
# (fm-spawn, fm-control) publishes under, and only fills the gap the failed
# fresh spawn's rollback left: a record present by then was published by
# another writer, so it is left exactly as it is.
if ! META_LOCK=$(fm_meta_lock_path "$META") || ! fm_lock_acquire_wait "$META_LOCK"; then
  die "second mate $ID could not be launched on $TARGET and its record lock could not be taken to put the previous record back; restore it from $SNAPSHOT: $(first_line "$FM_SM_LIVE_OUT")"
fi
if [ ! -e "$META" ] && [ ! -L "$META" ]; then
  if ! cp -p "$SNAPSHOT" "$META.move.$$" || ! mv -f "$META.move.$$" "$META"; then
    fm_lock_release "$META_LOCK" || true
    KEEP=$SNAPSHOT
    SNAPSHOT=
    die "second mate $ID could not be launched on $TARGET and its previous record could not be put back; restore it from $KEEP: $(first_line "$FM_SM_LIVE_OUT")"
  fi
elif ! cmp -s "$SNAPSHOT" "$META"; then
  fm_lock_release "$META_LOCK" || true
  die "second mate $ID could not be launched on $TARGET after its $OLD_BACKEND agent was stopped, and a different record for it is now in place (published by another writer since, or left by the launch's own incomplete cleanup); that record was left as it is and the previous one was not put back: $(first_line "$FM_SM_LIVE_OUT")"
fi
fm_lock_release "$META_LOCK" || true
if [ "$FM_SM_LIVE_STATUS" = skipped ]; then
  [ "$STOPPED" = 1 ] || die "second mate $ID was not moved to $TARGET; nothing was stopped or launched and its record is unchanged: $FM_SM_LIVE_REASON"
  die "second mate $ID was not moved to $TARGET: its $OLD_BACKEND agent was stopped, nothing was launched, and its previous record (backend=$OLD_BACKEND) is unchanged, so the next liveness recovery respawns it on its recorded backend: $FM_SM_LIVE_REASON"
fi
die "second mate $ID could not be launched on $TARGET after its $OLD_BACKEND agent was stopped; its home is unchanged and its previous record (backend=$OLD_BACKEND) is in place, so the next liveness recovery respawns it on $OLD_BACKEND: $(first_line "$FM_SM_LIVE_OUT")"
