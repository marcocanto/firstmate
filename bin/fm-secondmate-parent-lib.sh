#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Parse, write, and locate the durable parent binding of a seeded secondmate home.
#
# The fm-secondmate-parent.v1 record contains exactly one schema and route.
# A local route contains exactly one absolute parent_home and no parent_host.
# A remote route contains no parent_home; current provisioning includes its SSH
# alias as diagnostic-only parent_host, while legacy-compatible manifests may
# omit that field.
# Unknown fields are reserved for forward-compatible additions.
# Duplicate schema or route fields, a malformed local binding, an unsupported
# route or schema, a NUL-bearing record, and a symlinked record fail closed.
# Writers publish this record before .fm-secondmate-home so that the identity
# marker remains the seed-completion point.

fm_secondmate_parent_record_parse() {
  local file=$1 line schema='' route='' parent_home='' parent_host=''
  local schema_count=0 route_count=0 parent_home_count=0 parent_host_count=0

  FM_SECONDMATE_PARENT_ROUTE=
  FM_SECONDMATE_PARENT_HOME=
  FM_SECONDMATE_PARENT_HOST=

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  # bash's read drops NUL bytes, and different bash generations disagree on the
  # result (3.2 truncates the value at the NUL, 5.x splices the surrounding
  # bytes together), so a NUL-bearing parent_home can resolve to a home the
  # record's bytes never name contiguously. Reject the whole record as corrupt
  # before any field parsing instead of letting the interpreter pick a home.
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*)
        schema_count=$((schema_count + 1))
        schema=${line#schema=}
        ;;
      route=*)
        route_count=$((route_count + 1))
        route=${line#route=}
        ;;
      parent_home=*)
        parent_home_count=$((parent_home_count + 1))
        parent_home=${line#parent_home=}
        ;;
      parent_host=*)
        parent_host_count=$((parent_host_count + 1))
        parent_host=${line#parent_host=}
        ;;
    esac
  done < "$file"

  [ "$schema_count" -eq 1 ] || return 1
  [ "$route_count" -eq 1 ] || return 1
  [ "$schema" = fm-secondmate-parent.v1 ] || return 1
  case "$route" in
    local)
      [ "$parent_home_count" -eq 1 ] || return 1
      [ "$parent_host_count" -eq 0 ] || return 1
      case "$parent_home" in /*) ;; *) return 1 ;; esac
      FM_SECONDMATE_PARENT_HOME=$parent_home
      ;;
    remote)
      [ "$parent_home_count" -eq 0 ] || return 1
      ;;
    *) return 1 ;;
  esac

  FM_SECONDMATE_PARENT_ROUTE=$route
  FM_SECONDMATE_PARENT_HOST=$parent_host
}

# Publish the remote-route record at <file>: schema, route=remote, and the
# diagnostic parent_host when one is known. The write is a rename, so a reader
# sees the previous record or the new one, never a partial one.
# bin/fm-remote-home-provision.sh writes it for a new remote home, and
# bin/fm-secondmate-move.sh for a local mate converted to a remote route.
fm_secondmate_parent_record_write_remote() {  # <file> [parent-host]
  local file=$1 host=${2:-} tmp
  tmp="$file.tmp.$$"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=remote\n'
    [ -z "$host" ] || printf 'parent_host=%s\n' "$host"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

# The identity of a home on the machine that runs this: `uid=<account uid>`
# and `home=<device>:<inode>` of the home directory, one per line. The remote
# control plane's `identity` verb prints it on the host, and
# bin/fm-secondmate-move.sh compares it with its own reading before converting
# a local mate to a remote route on the same machine: the same uid and the
# same device and inode prove the SSH alias reaches this account and this home,
# not a same-named path on another machine.
fm_secondmate_home_identity() {  # <home>
  local home=$1 devino
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    devino=$(LC_ALL=C /usr/bin/stat -f '%d:%i' "$home" 2>/dev/null) || return 1
  else
    devino=$(LC_ALL=C stat -c '%d:%i' "$home" 2>/dev/null) || return 1
  fi
  [ -n "$devino" ] || return 1
  printf 'uid=%s\nhome=%s\n' "$(id -u)" "$devino"
}
