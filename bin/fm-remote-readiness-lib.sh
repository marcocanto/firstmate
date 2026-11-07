#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id> [backend] [harness]
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# <backend> is herdr, rex, hc, or any (the default). A concrete backend is
# passed to the doctor's --backend flag; `any` invokes it bare, which resolves
# whichever supported backend that host provides. A remote still on the
# herdr-only doctor exits 2 on the unknown flag; an explicit herdr request then
# retries without it, whose only selectable backend there is herdr. rex and hc
# have no such fallback: a remote that old cannot run them.
#
# <harness> is the runtime the launch or recovery will use. omp is the only
# runtime with its own doctor check, so only omp is forwarded (--harness omp);
# every other runtime keeps the harness-agnostic doctor call.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_probe() { # <bin-dir> <secondmate-id> [doctor-args...]
  local bin_dir=$1 id=$2 out rc
  shift 2
  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" </dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  return "$rc"
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id> [backend] [harness]
  local bin_dir=$1 id=$2 backend=${3:-any} harness=${4:-} rc
  local -a doctor_args=() runtime_args=()
  [ "$harness" != omp ] || runtime_args=(--harness omp)
  [ "$backend" = any ] || doctor_args=(--backend "$backend")
  doctor_args+=(${runtime_args[@]+"${runtime_args[@]}"})

  fm_remote_readiness_probe "$bin_dir" "$id" ${doctor_args[@]+"${doctor_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    # A remote still on the herdr-only doctor refuses the flag entirely; the
    # same request without it is what that doctor accepts.
    fm_remote_readiness_probe "$bin_dir" "$id" ${runtime_args[@]+"${runtime_args[@]}"}
    rc=$?
  fi
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_probe "$bin_dir" "$id" --fix ${doctor_args[@]+"${doctor_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    fm_remote_readiness_probe "$bin_dir" "$id" --fix ${runtime_args[@]+"${runtime_args[@]}"}
    rc=$?
  fi
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_probe "$bin_dir" "$id" ${doctor_args[@]+"${doctor_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    fm_remote_readiness_probe "$bin_dir" "$id" ${runtime_args[@]+"${runtime_args[@]}"}
    rc=$?
  fi
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
