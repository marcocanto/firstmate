#!/usr/bin/env bash
# fm-secondmate-move.sh - move a persistent second mate onto another runtime
# backend, keeping its home, records, and backlog exactly as they are.
#
# Usage: fm-secondmate-move.sh <secondmate-id> --backend <name>
#        fm-secondmate-move.sh <secondmate-id> --remote <ssh-alias> --root <remote-root> [--backend hc]
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
# previous backend; a completed one drops the set-aside record.
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
# --remote converts a LOCAL mate into a remote route on the same machine, in
# place: the home path, backlog, task records, lanes, and worktrees stay
# exactly where they are, and only the route records below change
# (docs/remote-secondmates.md "Convert a local second mate to a remote route"). It is a mode of this move
# rather than a new command because it is the same lifecycle - the same locks,
# probe, proven stop, and restore of the previous record on a failed launch -
# with a different launch target. <ssh-alias> must reach this account on this
# machine and <remote-root> is a separate Firstmate code root here; the mate
# then runs on this machine's hc core. Before anything is stopped it refuses:
# a mate that is remote already, a home that is not a directory on this
# machine or is bound to another parent, an alias whose host reports a
# different account or home (`identity` verb), a host the `--backend hc`
# readiness gate does not pass, an unresolved routed request or handoff
# outbox, a local hc mate in a core other than the one the home's
# config/hc-session names, and leftovers of an earlier remote route. After the
# stop, the old endpoint is closed and the conversion rewrites what
# bin/fm-remote-home-seed.sh would have produced, without re-cloning: the
# home's .fm-secondmate-parent becomes route=remote with the alias, its
# data/charter.md takes its remote form (secondmate_charter_remote_form), the
# parent's state/<id>.status is copied to the home's
# state/parent-replies.status and adopted as already mirrored
# (bin/fm-procevent-remote-reply.sh adopt), the parent-side steering inbox
# (unread and handled records) moves to the home's
# state/parent-route/<id>.inbox, and the registry entry takes the remote form.
# Then the mate is launched through `bin/fm-spawn.sh <id> --secondmate
# --backend hc` with the harness, model, and effort its local record named,
# which publishes the remote record and arms the reply mirror. A failed launch
# restores every one of those changes and the previous local record, so the
# next liveness recovery respawns the mate locally. A launch the host completed
# but this home could not record is left in place and reported, because
# restoring the local route would put a second agent beside it.
#
# Prints `moved <id> from=<old-backend> to=<new-backend>` (plus `host=<alias>`
# for a remote move or a conversion) followed by the
# spawn's own `spawned ...` line. Exit status: 0 moved; 1 refused or failed,
# with the message naming the state the mate was left in; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

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
# shellcheck disable=SC2329 # Registered by the EXIT trap in move_lock and remote_convert.
move_cleanup() {
  [ -z "$SNAPSHOT" ] || rm -f "$SNAPSHOT"
  # An exit during a conversion that did not go through cv_fail still puts
  # the previous local route back (cv_restore is a no-op once settled).
  [ "${CV_ACTIVE:-0}" != 1 ] || cv_restore
  if [ -n "${CV_STAGE:-}" ] && [ "${CV_KEEP:-0}" != 1 ] && [ -z "${CV_RESTORE_NOTES:-}" ]; then
    rm -rf -- "$CV_STAGE"
  fi
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

# stop_local_agent: probe this home's local record, and stop an alive agent
# through bin/fm-control.sh exit, proving the endpoint agent-free. Sets
# STOPPED=1 when it stopped one. Refuses before anything is stopped on an
# unclassifiable endpoint, and refuses with the record unchanged when the stop
# cannot be proven. The caller holds the move locks.
stop_local_agent() {
  local exit_out_file exit_out
  fm_secondmate_liveness_probe "$META" "$ID" poll
  case "$FM_SM_LIVE_STATUS" in
    silent)
      # No endpoint recorded: nothing to stop or close, only the launch.
      ;;
    alive)
      # A direct child, not a command substitution: fm-control recognizes the
      # handed-down control lock by its parent pid, which a substitution's
      # subshell would hide.
      exit_out_file="$STATE/.$ID.move-exit.$$"
      if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-control.sh" "$ID" exit >"$exit_out_file" 2>&1; then
        exit_out=$(cat "$exit_out_file" 2>/dev/null || true)
        rm -f "$exit_out_file"
        die "second mate $ID's agent on $OLD_BACKEND could not be proven stopped, so nothing was moved and its record is unchanged: $(first_line "$exit_out")"
      fi
      rm -f "$exit_out_file"
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
}

# --- conversion of a local mate to a remote route on this machine (header) ---

CONVERT_HOST=
CONVERT_ROOT=
CV_STAGE=
CV_ACTIVE=0
CV_HOME=
CV_META_ASIDE=
CV_INBOX_ASIDE=
CV_INBOX_NEW=0
CV_CHARTER_DONE=0
CV_STATUS_DONE=0
CV_BINDING_DONE=0
CV_ADOPT_DONE=0
CV_REGISTRY_DONE=0
CV_RESTORE_NOTES=

cv_note() {  # <text>: one restore step that could not be completed
  CV_RESTORE_NOTES="${CV_RESTORE_NOTES}${CV_RESTORE_NOTES:+; }$1"
}

# cv_restore: undo every applied conversion step, newest first, leaving the
# previous local route exactly as it was. Called on a failure after the stop
# and from the EXIT trap on an unexpected exit. A step that cannot be undone is
# named in CV_RESTORE_NOTES rather than skipped silently.
cv_restore() {
  local reg meta_lock reg_lock record f
  [ "$CV_ACTIVE" = 1 ] || return 0
  CV_ACTIVE=0
  reg="$DATA/secondmates.md"
  if [ "$CV_REGISTRY_DONE" = 1 ]; then
    reg_lock=$(secondmate_registry_lock_path "$STATE")
    if fm_lock_acquire_wait "$reg_lock"; then
      if cmp -s "$reg" "$CV_STAGE/registry.after"; then
        { cp -p "$CV_STAGE/registry.before" "$reg.convert.$$" && mv -f "$reg.convert.$$" "$reg"; } \
          || cv_note "registry entry not restored; the previous registry is at $CV_STAGE/registry.before"
      else
        cv_note "the registry changed after the conversion wrote it, so its entry was left as found"
      fi
      fm_lock_release "$reg_lock" || true
    else
      cv_note "registry lock unavailable; the previous registry is at $CV_STAGE/registry.before"
    fi
  fi
  if [ "$CV_ADOPT_DONE" = 1 ]; then
    rm -f -- "$STATE/remote-replies/$ID.cursor" || cv_note "reply cursor not removed"
    record="$STATE/.remote-reply-mirrored-$ID"
    if [ -f "$CV_STAGE/mirrored.before" ]; then
      cp -p "$CV_STAGE/mirrored.before" "$record" || cv_note "mirrored-source record not restored"
    else
      rm -f -- "$record" || cv_note "mirrored-source record not removed"
    fi
  fi
  if [ "$CV_BINDING_DONE" = 1 ]; then
    { cp -p "$CV_STAGE/parent.before" "$CV_HOME/.fm-secondmate-parent.convert.$$" \
      && mv -f "$CV_HOME/.fm-secondmate-parent.convert.$$" "$CV_HOME/.fm-secondmate-parent"; } \
      || cv_note "home parent record not restored; the previous one is at $CV_STAGE/parent.before"
  fi
  if [ "$CV_STATUS_DONE" = 1 ]; then
    # A publisher may have appended to the relay log after the switch; those
    # lines go back to the parent stream before the relay log is removed.
    if [ ! -f "$CV_HOME/state/parent-replies.status" ]; then
      :
    elif LC_ALL=C awk -v status="$STATE/$ID.status" '
        BEGIN { while ((getline line < status) > 0) seen[line] = 1; close(status) }
        $0 != "" && !($0 in seen) { seen[$0] = 1; print }
      ' "$CV_HOME/state/parent-replies.status" >> "$STATE/$ID.status"; then
      rm -f -- "$CV_HOME/state/parent-replies.status" || cv_note "home parent-replies.status not removed"
    else
      cv_note "lines in $CV_HOME/state/parent-replies.status were not carried back to $STATE/$ID.status"
    fi
  fi
  if [ "$CV_CHARTER_DONE" = 1 ]; then
    if [ -f "$CV_STAGE/charter.before" ]; then
      { cp -p "$CV_STAGE/charter.before" "$CV_HOME/data/charter.md.convert.$$" \
        && mv -f "$CV_HOME/data/charter.md.convert.$$" "$CV_HOME/data/charter.md"; } \
        || cv_note "home charter not restored; the previous one is at $CV_STAGE/charter.before"
    else
      rm -f -- "$CV_HOME/data/charter.md" || cv_note "home charter not removed"
    fi
  fi
  if [ "$CV_INBOX_NEW" = 1 ]; then
    rm -rf -- "$CV_HOME/state/parent-route/$ID.inbox" || cv_note "home parent-route inbox not removed"
  fi
  if [ -n "$CV_INBOX_ASIDE" ]; then
    if [ ! -e "$STATE/$ID.inbox" ] && [ ! -L "$STATE/$ID.inbox" ]; then
      mv -- "$CV_INBOX_ASIDE" "$STATE/$ID.inbox" || cv_note "steering inbox not restored; it is at $CV_INBOX_ASIDE"
    else
      for f in "$CV_INBOX_ASIDE"/*.msg "$CV_INBOX_ASIDE"/handled/*.msg; do
        [ -e "$f" ] || continue
        cv_note "steering inbox not restored because a new one appeared; the previous one is at $CV_INBOX_ASIDE"
        break
      done
    fi
  fi
  if [ -n "$CV_META_ASIDE" ]; then
    if meta_lock=$(fm_meta_lock_path "$META") && fm_lock_acquire_wait "$meta_lock"; then
      if [ ! -e "$META" ] && [ ! -L "$META" ]; then
        mv -f -- "$CV_META_ASIDE" "$META" || cv_note "local record not restored; it is at $CV_META_ASIDE"
      else
        cv_note "a different record for $ID is now in place, so the previous local record was left at $CV_META_ASIDE"
      fi
      fm_lock_release "$meta_lock" || true
    else
      cv_note "record lock unavailable; the previous local record is at $CV_META_ASIDE"
    fi
  fi
}

# cv_fail <message>: restore, then refuse with what the mate was left as.
cv_fail() {
  cv_restore
  if [ -n "$CV_RESTORE_NOTES" ]; then
    die "$1; the restore was incomplete: $CV_RESTORE_NOTES"
  fi
  die "$1; its previous local route and record are restored, so the next liveness recovery respawns it locally on $OLD_BACKEND"
}

# The parent-side steering inbox moves to the path the remote control plane
# writes (state/parent-route/<id>.inbox in the home), with its unread records
# and its handled/ acknowledgements, so sequence numbers keep counting past
# both and an idempotent resend still finds the handled copy. The watcher's
# ring bookkeeping (dotfiles) stays behind: the remote leg has no ladder.
cv_carry_inbox() {
  local old="$STATE/$ID.inbox" new="$CV_HOME/state/parent-route/$ID.inbox" f
  [ -e "$old" ] || [ -L "$old" ] || return 0
  [ -d "$old" ] && [ ! -L "$old" ] || return 1
  CV_INBOX_ASIDE="$STATE/.$ID.inbox.convert.$$"
  mv -- "$old" "$CV_INBOX_ASIDE" || { CV_INBOX_ASIDE=; return 1; }
  mkdir -p "$new/handled" || return 1
  CV_INBOX_NEW=1
  for f in "$CV_INBOX_ASIDE"/*.msg; do
    [ -e "$f" ] || continue
    cp -p -- "$f" "$new/" || return 1
  done
  for f in "$CV_INBOX_ASIDE"/handled/*.msg; do
    [ -e "$f" ] || continue
    cp -p -- "$f" "$new/handled/" || return 1
  done
  # A steer that resolved this mate's local record before it was set aside
  # can still land in the old path now; carrying it would race its writer.
  [ ! -e "$old" ] && [ ! -L "$old" ]
}

remote_convert() {
  local reg home canon_home canon_parent canon_root summary scope projects added harness model effort
  local account_config local_session home_session rec task_id phase rc out want got target charter_src
  local reg_lock meta_lock relaunch_lock spawn_rc
  local -a spawn_args
  [ -z "$REMOTE_HOST" ] \
    || die "second mate $ID is already a remote route on $REMOTE_HOST; nothing was stopped or converted"
  [ "$TARGET" = hc ] \
    || die "a converted second mate runs on its host's hc core, not backend=$TARGET; nothing was stopped or converted"
  reg="$DATA/secondmates.md"
  secondmate_registry_line_for_id "$reg" "$ID" \
    || die "second mate $ID has no single readable entry in $reg; nothing was stopped or converted"
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] \
    || die "second mate $ID is already registered as a remote route on $SECONDMATE_REGISTRY_HOST; nothing was stopped or converted"
  home=$SECONDMATE_REGISTRY_HOME
  summary=$SECONDMATE_REGISTRY_SUMMARY
  scope=$SECONDMATE_REGISTRY_SCOPE
  projects=$SECONDMATE_REGISTRY_PROJECTS
  added=$SECONDMATE_REGISTRY_ADDED
  [ "$(fm_meta_get "$META" home)" = "$home" ] \
    || die "second mate $ID's record names home '$(fm_meta_get "$META" home)' but the registry names '$home'; nothing was stopped or converted"

  # The home must be here: the conversion keeps it in place, so the host that
  # will run the mate is this machine.
  [ -d "$home" ] && [ ! -L "$home" ] \
    || die "second mate $ID's home $home is not a directory on this machine; convert it from the machine that holds it; nothing was stopped or converted"
  canon_home=$(CDPATH='' cd -- "$home" && pwd -P) || die "second mate $ID's home $home cannot be resolved; nothing was stopped or converted"
  [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] \
    && [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null)" = "$ID" ] \
    || die "$home is not marked as second mate $ID's home; nothing was stopped or converted"
  [ -f "$home/AGENTS.md" ] && [ -d "$home/bin" ] \
    || die "second mate $ID's home $home is not a Firstmate checkout, which a remote host requires; nothing was stopped or converted"
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || die "second mate $ID's home has no readable local parent record; nothing was stopped or converted"
  canon_parent=$(CDPATH='' cd -- "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null && pwd -P) || canon_parent=
  [ -n "$canon_parent" ] && [ "$canon_parent" = "$(CDPATH='' cd -- "$FM_HOME" && pwd -P)" ] \
    || die "second mate $ID's home is bound to the parent home $FM_SECONDMATE_PARENT_HOME, not this one; convert it from there; nothing was stopped or converted"

  # The code root the host runs from: a separate checkout on this machine, and
  # never this parent home, which is expected to move away later.
  case "$CONVERT_ROOT" in /*) ;; *) die "--root must be an absolute path: $CONVERT_ROOT" ;; esac
  case "/$CONVERT_ROOT/" in */../*|*/./*) die "--root must not contain traversal components: $CONVERT_ROOT" ;; esac
  case "$CONVERT_ROOT" in *'//'*|*';'*|*')'*|*$'\n'*|*$'\t'*) die "--root contains an empty component or a registry delimiter: $CONVERT_ROOT" ;; esac
  [ -d "$CONVERT_ROOT/bin" ] && [ -f "$CONVERT_ROOT/bin/fm-remote-entrypoint.sh" ] \
    || die "--root $CONVERT_ROOT is not a Firstmate code root on this machine; nothing was stopped or converted"
  canon_root=$(CDPATH='' cd -- "$CONVERT_ROOT" && pwd -P) || die "--root $CONVERT_ROOT cannot be resolved"
  [ "$canon_root" = "$CONVERT_ROOT" ] \
    || die "--root must be the canonical path $canon_root, the path the host resolves; nothing was stopped or converted"
  case "$canon_home/" in "$canon_root/"*) die "second mate $ID's home is inside the code root $CONVERT_ROOT; nothing was stopped or converted" ;; esac
  case "$canon_root/" in "$canon_home/"*) die "the code root $CONVERT_ROOT is inside second mate $ID's home; nothing was stopped or converted" ;; esac
  [ "$canon_root" != "$(CDPATH='' cd -- "$FM_HOME" && pwd -P)" ] \
    || die "the code root must be a separate checkout, not this parent home; nothing was stopped or converted"

  # Leftovers of an earlier remote route would mix with the new one. The
  # cursor path is bin/fm-procevent-remote-reply.sh's.
  for rec in "$home/state/parent-replies.status" "$home/state/parent-route/$ID.meta" \
    "$home/state/parent-route/$ID.inbox" "$STATE/remote-replies/$ID.cursor"; do
    [ ! -e "$rec" ] && [ ! -L "$rec" ] \
      || die "$rec is left from an earlier remote route of $ID; nothing was stopped or converted"
  done

  # The runtime the local record names is the one the remote launch keeps.
  harness=$(fm_meta_get "$META" harness)
  model=$(fm_meta_get "$META" model)
  effort=$(fm_meta_get "$META" effort)
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|omp) ;;
    *) die "second mate $ID's record names harness '${harness:-none}', which a remote route cannot launch; nothing was stopped or converted" ;;
  esac
  [ "$model" != default ] || model=
  [ "$effort" != default ] || effort=
  account_config=$(fm_worker_account_config "$harness" "$CONFIG" "$ID") \
    || die "second mate $ID's account pin cannot be read; nothing was stopped or converted"
  [ "$account_config" = "$CONFIG" ] \
    || die "$account_config pins second mate $ID's account, which a remote route cannot use; move that pin into $home/config first; nothing was stopped or converted"
  OLD_BACKEND=$(fm_backend_of_meta "$META")
  case "$OLD_BACKEND" in
    rex|t3code) die "a $OLD_BACKEND second mate cannot be converted directly; move it onto hc with --backend hc first; nothing was stopped or converted" ;;
  esac
  if [ "$OLD_BACKEND" = hc ]; then
    fm_backend_source hc >/dev/null 2>&1 || die "the hc adapter could not be loaded; nothing was stopped or converted"
    local_session=$(fm_meta_get "$META" hc_session)
    home_session=$(fm_backend_hc_remote_session "$home") \
      || die "$home/config/hc-session does not name one valid hc session; nothing was stopped or converted"
    [ "${local_session:-default}" = "$home_session" ] \
      || die "second mate $ID runs in hc core '${local_session:-default}', but its home's config/hc-session resolves to '$home_session'; write '${local_session:-default}' to $home/config/hc-session so the converted mate stays in its core; nothing was stopped or converted"
  fi

  # An open routed request or handoff would be answered on a channel this
  # conversion changes, the same reason retirement refuses them.
  for rec in "$STATE/pending-replies"/*; do
    [ -f "$rec" ] || continue
    task_id=$(fm_meta_get "$rec" task_id)
    [ "$task_id" = "$ID" ] || continue
    phase=$(fm_meta_get "$rec" phase)
    [ "$phase" = resolved ] \
      || die "second mate $ID has an unresolved routed request (${rec##*/}); let it resolve first; nothing was stopped or converted"
  done
  [ ! -e "$DATA/handoff/$ID.outbox.md" ] \
    || die "second mate $ID has an unfinished backlog handoff outbox; deliver it first; nothing was stopped or converted"

  # The remote registry entry, staged where only this conversion's own
  # transport reads it until the mate is stopped.
  CV_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-convert.XXXXXX") || die "cannot create conversion scratch space"
  trap move_cleanup EXIT
  mkdir -p "$CV_STAGE/data" || die "cannot create conversion scratch space"
  cp -p "$reg" "$CV_STAGE/registry.before" || die "cannot snapshot the registry"
  # ENVIRON, not -v: awk -v would interpret backslashes in the summary text.
  FM_CV_ID=$ID FM_CV_LINE=$(printf -- '- %s - %s (host: %s; root: %s; home: %s; scope: %s; projects: %s; added %s)' \
    "$ID" "$summary" "$CONVERT_HOST" "$CONVERT_ROOT" "$home" "$scope" "$projects" "$added") \
    LC_ALL=C awk '
    BEGIN { id = ENVIRON["FM_CV_ID"]; line = ENVIRON["FM_CV_LINE"] }
    $0 == "- " id || index($0, "- " id " ") == 1 { print line; next }
    { print }
  ' "$CV_STAGE/registry.before" > "$CV_STAGE/registry.after" || die "cannot stage the remote registry entry"
  cp -p "$CV_STAGE/registry.after" "$CV_STAGE/data/secondmates.md" || die "cannot stage the remote registry entry"
  secondmate_registry_validate_bindings "$CV_STAGE/data/secondmates.md" secondmate_registry_path_key "$ID" "$home" \
    || die "the remote registry entry for $ID is invalid ($SECONDMATE_REGISTRY_ERROR); nothing was stopped or converted"

  # The alias must reach this account and this very home.
  rc=0
  out=$(FM_DATA_OVERRIDE="$CV_STAGE/data" "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh identity "$ID" </dev/null 2>&1) || rc=$?
  [ "$rc" -ne 255 ] \
    || die "the SSH alias $CONVERT_HOST is unreachable or its answer is unknown; nothing was stopped or converted"
  [ "$rc" -eq 0 ] \
    || die "the host behind $CONVERT_HOST could not confirm second mate $ID's home ($(first_line "$out")); nothing was stopped or converted"
  want=$(fm_secondmate_home_identity "$home") || die "the identity of $home cannot be read; nothing was stopped or converted"
  got=$(printf '%s\n' "$out" | grep -E '^(uid|home)=')
  [ "$got" = "$want" ] \
    || die "the SSH alias $CONVERT_HOST does not reach this account and this home on this machine (host: $(printf '%s' "$got" | tr '\n' ' ')this machine: $(printf '%s' "$want" | tr '\n' ' ')); nothing was stopped or converted"

  rc=0
  FM_DATA_OVERRIDE="$CV_STAGE/data" fm_remote_readiness_ensure "$SCRIPT_DIR" "$ID" hc "$harness" || rc=$?
  [ "$rc" -ne 255 ] \
    || die "the host behind $CONVERT_HOST is unreachable or its readiness is unknown; nothing was stopped or converted"
  [ "$rc" -eq 0 ] \
    || die "the host behind $CONVERT_HOST is not ready for backend=hc ($(printf '%s\n' "$FM_REMOTE_READINESS_OUT" | awk '/^check [^=]+=(fixable|human):|^error:/ { print; exit }')); nothing was stopped or converted"

  move_lock
  STOPPED=0
  stop_local_agent
  CV_HOME=$home
  CV_ACTIVE=1

  # Close the old local endpoint (the same close liveness recovery runs).
  if [ "$FM_SM_LIVE_KILL" = 1 ]; then
    target=$(fm_backend_target_of_meta "$META")
    [ -n "$target" ] || target=$(fm_meta_get "$META" window)
    [ -z "$target" ] || fm_backend_kill "$OLD_BACKEND" "$target" 2>/dev/null \
      || cv_fail "second mate $ID's agent was stopped, but its $OLD_BACKEND endpoint $target could not be closed"
  fi

  # The local record is set aside, not edited: the launch below publishes the
  # remote one, and a failure puts this one back.
  meta_lock=$(fm_meta_lock_path "$META") && fm_lock_acquire_wait "$meta_lock" \
    || cv_fail "second mate $ID's record lock could not be taken"
  CV_META_ASIDE="$STATE/.$ID.meta.convert.$$"
  if ! mv -f -- "$META" "$CV_META_ASIDE"; then
    CV_META_ASIDE=
    fm_lock_release "$meta_lock" || true
    cv_fail "second mate $ID's local record could not be set aside"
  fi
  fm_lock_release "$meta_lock" || true

  cv_carry_inbox || cv_fail "second mate $ID's steering inbox could not be carried to its home"

  mkdir -p "$home/state" "$home/data" || cv_fail "second mate $ID's home state could not be prepared"
  if [ -f "$home/data/charter.md" ]; then
    charter_src="$home/data/charter.md"
    cp -p "$charter_src" "$CV_STAGE/charter.before" || cv_fail "second mate $ID's charter could not be snapshotted"
  else
    charter_src="$DATA/$ID/brief.md"
    [ -f "$charter_src" ] || cv_fail "second mate $ID has neither a home charter nor a charter brief at $charter_src"
  fi
  secondmate_charter_remote_form "$charter_src" "$STATE" "$ID" "$home" > "$CV_STAGE/charter.remote" \
    || cv_fail "second mate $ID's charter could not be rendered in its remote form"
  CV_CHARTER_DONE=1
  { cp "$CV_STAGE/charter.remote" "$home/data/charter.md.convert.$$" \
    && mv -f "$home/data/charter.md.convert.$$" "$home/data/charter.md"; } \
    || cv_fail "second mate $ID's charter could not be rewritten"

  # The binding switches first, so every parent-channel append from here on
  # resolves to the relay log (bin/fm-parent-channel-lib.sh).
  cp -p "$home/.fm-secondmate-parent" "$CV_STAGE/parent.before" || cv_fail "second mate $ID's parent record could not be snapshotted"
  CV_BINDING_DONE=1
  fm_secondmate_parent_record_write_remote "$home/.fm-secondmate-parent" "$CONVERT_HOST" \
    || cv_fail "second mate $ID's parent record could not be rewritten"

  # The old parent stream becomes the head of the new relay log, so the home's
  # outcome publishers still see every line they already delivered, and the
  # mirror starts after it (adopt) instead of delivering it again. A line a
  # publisher appended to the relay log after the switch stays after that head
  # and is mirrored once; one appended to the old stream after the snapshot is
  # carried after the head too, and the mirror skips it because the parent
  # stream already holds it.
  if [ -f "$STATE/$ID.status" ]; then
    cp "$STATE/$ID.status" "$CV_STAGE/status.prefix" || cv_fail "second mate $ID's status stream could not be read"
  else
    : > "$CV_STAGE/status.prefix" || cv_fail "cannot stage an empty status stream"
  fi
  cp "$CV_STAGE/status.prefix" "$CV_STAGE/relay.next" || cv_fail "cannot stage the relay log"
  [ ! -f "$home/state/parent-replies.status" ] || cat "$home/state/parent-replies.status" >> "$CV_STAGE/relay.next" \
    || cv_fail "cannot stage the relay log"
  CV_STATUS_DONE=1
  { cp "$CV_STAGE/relay.next" "$home/state/parent-replies.status.convert.$$" \
    && mv -f "$home/state/parent-replies.status.convert.$$" "$home/state/parent-replies.status"; } \
    || cv_fail "second mate $ID's relay log could not be written"
  if [ -f "$STATE/$ID.status" ] && ! cmp -s "$STATE/$ID.status" "$CV_STAGE/status.prefix"; then
    tail -c "+$(( $(LC_ALL=C wc -c < "$CV_STAGE/status.prefix") + 1 ))" "$STATE/$ID.status" \
      >> "$home/state/parent-replies.status" || cv_fail "second mate $ID's late status lines could not be carried"
  fi

  [ ! -f "$STATE/.remote-reply-mirrored-$ID" ] || cp -p "$STATE/.remote-reply-mirrored-$ID" "$CV_STAGE/mirrored.before" \
    || cv_fail "the mirrored-source record could not be snapshotted"
  CV_ADOPT_DONE=1
  out=$("$SCRIPT_DIR/fm-procevent-remote-reply.sh" adopt "$ID" "$CV_STAGE/status.prefix" 2>&1) \
    || cv_fail "second mate $ID's relay log could not be adopted ($(first_line "$out"))"

  reg_lock=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$reg_lock" || cv_fail "the registry lock could not be taken"
  if ! cmp -s "$reg" "$CV_STAGE/registry.before"; then
    fm_lock_release "$reg_lock" || true
    cv_fail "the registry changed during the conversion"
  fi
  CV_REGISTRY_DONE=1
  if ! { cp "$CV_STAGE/registry.after" "$reg.convert.$$" && mv -f "$reg.convert.$$" "$reg"; }; then
    fm_lock_release "$reg_lock" || true
    cv_fail "the registry entry could not be rewritten"
  fi
  fm_lock_release "$reg_lock" || true

  # The launch: the same per-home relaunch lock and ledger every respawn uses.
  spawn_args=("$ID" --secondmate --backend hc --harness "$harness")
  [ -z "$model" ] || spawn_args+=(--model "$model")
  [ -z "$effort" ] || spawn_args+=(--effort "$effort")
  relaunch_lock="$STATE/.secondmate-relaunch.lock"
  fm_lock_acquire_wait_bounded "$relaunch_lock" 600 || cv_fail "another second-mate relaunch still holds the relaunch lock"
  fm_secondmate_liveness_ledger_add "$ID" attempt || true
  spawn_rc=0
  out=$(FM_SPAWN_NO_GUARD=1 "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" 2>&1) || spawn_rc=$?
  if [ "$spawn_rc" -eq 0 ]; then
    fm_secondmate_liveness_ledger_add "$ID" relaunched || true
    fm_lock_release "$relaunch_lock" || true
    CV_ACTIVE=0
    rm -rf -- "$CV_META_ASIDE" "$CV_INBOX_ASIDE" "$CV_STAGE"
    printf 'moved %s from=%s to=hc host=%s\n' "$ID" "$OLD_BACKEND" "$CONVERT_HOST"
    printf '%s\n' "$out" | grep '^spawned ' || true
    exit 0
  fi
  fm_secondmate_liveness_ledger_add "$ID" failed || true
  fm_lock_release "$relaunch_lock" || true
  # A launch the host completed, or may have completed, is never undone from
  # here: restoring the local route would put a second agent beside the remote
  # one.
  if [ "$spawn_rc" -eq 255 ] || [ -f "$META" ] || [ -f "$home/state/parent-route/$ID.meta" ]; then
    CV_ACTIVE=0
    CV_KEEP=1
    die "second mate $ID may already run on $CONVERT_HOST, but its launch did not finish cleanly ($(first_line "$out")); its remote route is kept, so run 'bin/fm-spawn.sh $ID --secondmate' to finish recording it; the previous local record and the conversion's snapshots are at $CV_META_ASIDE and $CV_STAGE"
  fi
  cv_fail "second mate $ID could not be launched as a remote route on $CONVERT_HOST: $(first_line "$out")"
}

ID=
TARGET=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --backend|--remote|--root)
      [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
      case "$1" in
        --backend) TARGET=$2 ;;
        --remote) CONVERT_HOST=$2 ;;
        --root) CONVERT_ROOT=$2 ;;
      esac
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
if [ -n "$CONVERT_HOST" ] || [ -n "$CONVERT_ROOT" ]; then
  [ -n "$CONVERT_HOST" ] && [ -n "$CONVERT_ROOT" ] \
    || { echo "error: --remote and --root are given together" >&2; exit 2; }
  case "$CONVERT_HOST" in ''|-*|*[!A-Za-z0-9._-]*) echo "error: invalid SSH config alias: $CONVERT_HOST" >&2; exit 2 ;; esac
  [ -n "$TARGET" ] || TARGET=hc
fi
[ -n "$ID" ] && [ -n "$TARGET" ] || { usage >&2; exit 2; }
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $ID" >&2; exit 2 ;; esac
[ -d "$STATE" ] || die "state dir '$STATE' is missing; fm-secondmate-move cannot resolve second mates for FM_HOME '$FM_HOME'"

# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no task record for $ID in $STATE; a move needs the mate's own record"
[ "$(fm_meta_get "$META" kind)" = secondmate ] || die "task $ID is not a second mate; fm-secondmate-move moves kind=secondmate records only"
REMOTE_HOST=$(fm_meta_get "$META" remote_host)
if [ -n "$CONVERT_HOST" ]; then
  fm_sm_live_require_locks || die "the lock helpers could not be loaded; nothing was stopped or converted"
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
  # shellcheck source=bin/fm-secondmate-charter-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-charter-lib.sh"
  # shellcheck source=bin/fm-worker-account-lib.sh
  . "$SCRIPT_DIR/fm-worker-account-lib.sh"
  remote_convert
fi
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
stop_local_agent

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
