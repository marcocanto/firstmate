#!/usr/bin/env bash
# launchd target for the Aqua fm-remote Herdr job.
#
# Usage:
#   fm-remote-herdr-launch.sh <herdr-path> <session>
#
# bin/fm-remote-doctor.sh runs this through the account's login shell in
# gui/<uid>. Detach the Unix session without changing the tracked process PID,
# audit session, Mach bootstrap context, environment, or output descriptors,
# then exec bin/fm-remote-herdr-guard.sh with the same arguments.
# The guard's header owns socket takeover and exit behavior.
# A server reached through its final exec has getsid(0) == getpid(), which
# Herdr requires for a saved machine, while launchd still tracks that same PID.
# Herdr 0.9.2 exposes no headless daemon-start flag; its client auto-start path
# requires a terminal and selects a different macOS service context.
#
# setsid refuses a process-group leader. A temporary child creates another
# group in the inherited session so the original process can join it and then
# call setsid. The child exits when its release pipe closes, including when
# the original process dies, and is reaped before exec. It never runs Herdr.
# A failed group join or setsid call stops before the guard runs.
# No daemon parent exits and no detached server child needs separate monitoring.
# A missing Perl POSIX runtime or any setup failure exits nonzero so
# KeepAlive={SuccessfulExit=false} retries; nothing starts after such a failure.
set -u

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ "$#" -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || usage
SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
command -v perl >/dev/null 2>&1 || { printf 'fm-remote-herdr-launch: Perl POSIX is required\n' >&2; exit 1; }

exec perl -MPOSIX=setsid,setpgid,_exit -e '
  use strict;
  use warnings;
  if (getpgrp() == $$) {
    pipe(my $ready_read, my $ready_write) or die "ready pipe: $!";
    pipe(my $release_read, my $release_write) or die "release pipe: $!";
    my $helper = fork();
    defined $helper or die "detach helper fork: $!";
    if ($helper == 0) {
      close $ready_read;
      close $release_write;
      setpgid(0, 0) or _exit(1);
      syswrite($ready_write, "1") == 1 or _exit(1);
      close $ready_write;
      my $release;
      defined(sysread($release_read, $release, 1)) or _exit(1);
      _exit(0);
    }
    close $ready_write;
    close $release_read;
    my ($ready, $error);
    if ((sysread($ready_read, $ready, 1) // 0) != 1) {
      $error = "detach helper did not become ready";
    } elsif (!setpgid(0, $helper)) {
      $error = "join detach helper group: $!";
    } elsif (setsid() < 0) {
      $error = "detach session: $!";
    }
    close $ready_read;
    close $release_write;
    waitpid($helper, 0) == $helper or die "wait detach helper: $!";
    die "$error\n" if defined $error;
    $? == 0 or die "detach helper failed\n";
  } else {
    setsid() >= 0 or die "detach session: $!";
  }
  exec {$ARGV[0]} @ARGV or die "exec remote Herdr guard: $!";
' -- "$SCRIPT_DIR/fm-remote-herdr-guard.sh" "$@"
