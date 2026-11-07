#!/usr/bin/env bash
# Shared secondmate charter helpers: registry summary and scope extraction, and
# the remote form of a charter.
# Source only. FM_SECONDMATE_CHARTER and FM_SECONDMATE_SCOPE remain explicit
# caller overrides; otherwise the named sections in the filled brief are used.

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_CHARTER:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_SCOPE:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}

# The remote form of a charter, printed to stdout. A charter names the parent's
# status file and steering inbox for this mate; a remote home keeps neither on
# its own filesystem, so its status path becomes the home's append-only relay
# log and its inbox path becomes the host-local parent-route inbox the remote
# control plane writes to. The two parents differ only by suffix, so the two
# whole-string rewrites are order-independent and every mention - bare path,
# /*.msg listing, and handled/ acknowledgement - lands host-local.
# Each rewrite stays its own plain assignment: on stock macOS bash a quoted
# substitution nested inside a double-quoted argument leaks literal quotes into
# the replacement text. bin/fm-remote-home-seed.sh renders a new remote home's
# charter with this, and bin/fm-secondmate-move.sh renders a converted one.
secondmate_charter_remote_form() {  # <charter> <parent-state-dir> <id> <remote-home>
  local charter=$1 parent_state=$2 id=$3 remote_home=$4 line
  local parent_status="$parent_state/$id.status"
  local remote_status="$remote_home/state/parent-replies.status"
  local parent_inbox="$parent_state/$id.inbox"
  local remote_inbox="$remote_home/state/parent-route/$id.inbox"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//"$parent_status"/"$remote_status"}
    line=${line//"$parent_inbox"/"$remote_inbox"}
    printf '%s\n' "$line"
  done < "$charter"
}
