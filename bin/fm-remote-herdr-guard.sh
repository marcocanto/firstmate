#!/usr/bin/env bash
# Guard for the Firstmate-owned dev.firstmate.herdr.fm-remote launch agent.
# Make the Aqua login session own a detached fm-remote Herdr server.
#
# Usage:
#   fm-remote-herdr-guard.sh <herdr-path> <session>
#
# bin/fm-remote-doctor.sh renders the launch agent through the account's login
# shell and bin/fm-remote-herdr-launch.sh in gui/<uid>. The launcher detaches
# the Unix session without forking away the tracked PID, then execs this guard.
# The Aqua domain supplies the audit session and login-keychain access.
# The login shell supplies the account's environment.
# The final exec keeps the server under launchd with that same PID and context.
#
# Decision, made once per launch (exit codes matter under SuccessfulExit=false:
# 0 tells launchd the job is done until something restarts it, non-zero asks
# for a retry after the throttle interval):
#   no server owns the session socket  -> exec `herdr server --session <s>`
#   the owner was born in Aqua and reports detached_server_daemon:true
#                                      -> exit 0, leave it alone
#   the owner was born in Aqua but lacks that capability, or
#   the owner was born anywhere else (an SSH remote attach, a shell over
#   ssh/mosh, or a birth it cannot prove) -> `herdr server stop`, wait until the
#                                          socket is released, then exec
#                                          `herdr server --session <s>` at once
#                                          so the socket is rebound before a
#                                          reconnecting SSH attach can start
#                                          another foreign server
#   the server does not release the socket in time -> exit 1
# A takeover closes every pane in that session; the parent firstmate's
# secondmate liveness sweep relaunches its mates into the detached Aqua server.
# bin/fm-remote-herdr-owner-lib.sh owns the owner discovery and the birth
# markers; FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS (default 50) bounds the
# release wait in tenths of a second. Every decision prints one line to
# stdout, which launchd routes to the agent's log.
set -u

SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$SCRIPT_DIR/fm-remote-herdr-owner-lib.sh"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ "$#" -eq 2 ] || usage
HERDR_BIN=$1
SESSION=$2
[ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ] || { printf 'fm-remote-herdr-guard: herdr is not executable: %s\n' "$HERDR_BIN" >&2; exit 1; }
[ -n "$SESSION" ] || usage
command -v jq >/dev/null 2>&1 || { printf 'fm-remote-herdr-guard: jq does not resolve on the launch agent PATH\n' >&2; exit 1; }
STOP_WAIT_TENTHS=${FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS:-50}

log() { printf 'fm-remote-herdr-guard: %s\n' "$*"; }

herdr_status() { # prints the session's status JSON, empty when herdr fails
  HERDR_SESSION="$SESSION" "$HERDR_BIN" status --json --session "$SESSION" 2>/dev/null || true
}

status_running() { # <status-json>
  [ "$(printf '%s' "$1" | jq -r '.server.running // false' 2>/dev/null)" = true ]
}

status_detached() { # <status-json>
  printf '%s' "$1" | jq -e '.server.capabilities.detached_server_daemon == true' >/dev/null 2>&1
}

start_server() {
  log "starting the herdr server for session $SESSION inside this launch agent (pid $$)"
  exec "$HERDR_BIN" server --session "$SESSION"
}

STATUS=$(herdr_status)
if ! status_running "$STATUS"; then
  log "no server owns session $SESSION"
  start_server
fi

SOCKET=$(printf '%s' "$STATUS" | jq -r '.server.socket // empty' 2>/dev/null)
OWNER=$(fm_remote_herdr_socket_owner "$SOCKET"); OWNER_RC=$?
if [ "$OWNER_RC" -eq 2 ]; then
  log "session $SESSION is running but lsof does not resolve, so its server's birth cannot be proven"
  BIRTH=unknown
elif [ -z "$OWNER" ]; then
  log "session $SESSION is running but no herdr process could be proven to own ${SOCKET:-its socket}"
  BIRTH=unknown
else
  BIRTH=$(fm_remote_herdr_owner_birth "$OWNER")
fi

if fm_remote_herdr_birth_is_aqua "$BIRTH"; then
  if status_detached "$STATUS"; then
    log "session $SESSION is served by pid $OWNER born in the Aqua login session ($BIRTH) with detached_server_daemon=true; nothing to do"
    exit 0
  fi
  log "session $SESSION is served by pid $OWNER born in the Aqua login session ($BIRTH) without detached_server_daemon=true; saved machines require a detached server, taking the session over"
else
  log "session $SESSION is served by ${OWNER:+pid }${OWNER:-an unproven process} born outside the Aqua login session ($BIRTH); its panes cannot reach the login keychain, taking the session over"
fi
HERDR_SESSION="$SESSION" "$HERDR_BIN" server stop --session "$SESSION" >/dev/null 2>&1 \
  || log "herdr server stop for session $SESSION did not succeed; waiting for the socket anyway"
i=0
while [ "$i" -lt "$STOP_WAIT_TENTHS" ]; do
  if ! status_running "$(herdr_status)"; then
    log "session $SESSION released its socket after $i tenths of a second"
    start_server
  fi
  sleep 0.1
  i=$((i + 1))
done
log "the server for session $SESSION did not release its socket within $STOP_WAIT_TENTHS tenths of a second; exiting 1 so launchd retries"
exit 1
