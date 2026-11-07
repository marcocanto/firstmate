#!/usr/bin/env bash
# tests/hc-fake-fixture.sh - a stateful fake herdr-core (`hc`) CLI shared by the
# remote hc second-mate suites, plus a real unix-socket holder that stands in
# for an answering core.
#
# write_hc_fake_cli <bin-path> <state-dir> emits the fake with its state dir
# baked in, because the remote job worker and the remote doctor run under an
# empty environment. Terminals live as <state-dir>/<address>.json. Every call
# is logged to <state-dir>/log as `HC_SESSION=<s>` followed by its arguments,
# each prefixed with a unit separator (0x1f).
#
#   --version            `hc <state-dir>/cli-version` (default 0.1.18)
#   server status        {"pid":4242,"version":<core-version>} (default 0.1.18)
#   connect              answers the hello handshake with generation 1
#   ls [--all] --label   live terminals filtered by label, finished with --all
#   run                  allocates t<n> with its labels and a zsh foreground
#                        whose pid is <state-dir>/shell-pid (default 1)
#   get / kill / rm      read, finish, or remove a terminal; get exits 3 when absent
#   read                 <state-dir>/screen, else a bare prompt
#   send                 records the text in <state-dir>/sent; a launch line
#                        (`. '...'`) makes the foreground omp, /quit or /exit
#                        makes it the zsh shell again
#   keys                 records the keys in <state-dir>/keys
#   exec                 exits with <state-dir>/exec-rc (default 0); the remote
#                        doctor runs its login-keychain probe through it
#
# start_hc_core_socket <socket-path> starts a real listener at <socket-path>
# (HC_CORE_SOCKET_PID); stop_hc_core_socket stops it and removes the socket.
# A connect succeeds while it runs, which is all fm_backend_hc_core_live reads.

write_hc_fake_cli() {  # <bin-path> <state-dir>
  local bin=$1 dir=$2
  mkdir -p "$(dirname "$bin")" "$dir"
  printf '#!/usr/bin/env bash\nD=%q\n' "$dir" > "$bin"
  cat >> "$bin" <<'SH'
set -u
mkdir -p "$D"
{ printf 'HC_SESSION=%s' "${HC_SESSION:-}"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$D/log"
cmd=${1:-}
last=''
for a in "$@"; do last=$a; done
shell_pid=$(cat "$D/shell-pid" 2>/dev/null || printf 1)
set_fg() {  # <address> <name>
  jq --arg n "$2" --argjson p "$shell_pid" '.foreground = {name:$n, argv:[$n], cwd:.cwd, pid:$p}' \
    "$D/$1.json" > "$D/$1.tmp" && mv "$D/$1.tmp" "$D/$1.json"
}
case "$cmd" in
  --version) printf 'hc %s\n' "$(cat "$D/cli-version" 2>/dev/null || printf 0.1.18)" ;;
  server)
    case "${2:-}" in
      status) printf '{"pid":4242,"version":"%s"}\n' "$(cat "$D/core-version" 2>/dev/null || printf 0.1.18)" ;;
      *) printf '{}\n' ;;
    esac
    ;;
  connect) IFS= read -r _ || true; printf '{"jsonrpc":"2.0","id":1,"result":{"generation":1}}\n' ;;
  ls)
    all=0; want=()
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --all) all=1 ;;
        --label) want+=("$2"); shift ;;
      esac
      shift
    done
    out='[]'
    for f in "$D"/t*.json; do
      [ -e "$f" ] || continue
      [ "$all" = 1 ] || [ "$(jq -r .state "$f")" = live ] || continue
      ok=1
      for kv in ${want[@]+"${want[@]}"}; do
        [ "$(jq -r --arg k "${kv%%=*}" '.labels[$k] // ""' "$f")" = "${kv#*=}" ] || ok=0
      done
      [ "$ok" = 1 ] || continue
      out=$(jq -c --slurpfile t "$f" '. + [$t[0] | {address, state}]' <<<"$out")
    done
    printf '{"terminals":%s}\n' "$out" ;;
  run)
    n=$(cat "$D/next" 2>/dev/null || printf 1)
    printf '%s\n' $((n + 1)) > "$D/next"
    addr="t$n"; cwd=/; labels='{}'; name=null
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) cwd=$2; shift ;;
        --name) name=$(jq -n --arg v "$2" '$v'); shift ;;
        --label) labels=$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '.[$k]=$v' <<<"$labels"); shift ;;
      esac
      shift
    done
    jq -n --arg a "$addr" --arg c "$cwd" --argjson l "$labels" --argjson n "$name" --argjson p "$shell_pid" \
      '{address:$a, state:"live", name:$n, labels:$l, cwd:$c, foreground:{name:"zsh", argv:["zsh"], cwd:$c, pid:$p}}' > "$D/$addr.json"
    printf '{"address":"%s"}\n' "$addr" ;;
  get)
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    cat "$D/$last.json" ;;
  kill)
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    jq '.state="finished" | .foreground=null' "$D/$last.json" > "$D/$last.tmp" && mv "$D/$last.tmp" "$D/$last.json"
    printf '{}\n' ;;
  rm) rm -f "$D/$last.json"; printf '{}\n' ;;
  read) if [ -f "$D/screen" ]; then cat "$D/screen"; else printf '❯\n'; fi ;;
  send)
    addr=''
    for a in "$@"; do case "$a" in t[0-9]*) addr=$a; break ;; esac; done
    printf '%s\n' "$last" >> "$D/sent"
    if [ -n "$addr" ] && [ -f "$D/$addr.json" ]; then
      case "$last" in
        ". '"*"'") set_fg "$addr" omp ;;
        /quit|/exit) set_fg "$addr" zsh ;;
      esac
    fi
    printf '{"started":true,"wait":{"status":"working"}}\n' ;;
  keys) shift; printf '%s\n' "$*" >> "$D/keys"; printf '{}\n' ;;
  exec)
    rc=$(cat "$D/exec-rc" 2>/dev/null || printf 0)
    [ "$rc" = 0 ] || printf 'security: User interaction is not allowed.\n' >&2
    exit "$rc" ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$bin"
}

HC_CORE_SOCKET_PID=
start_hc_core_socket() {  # <socket-path>
  mkdir -p "$(dirname "$1")"
  python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(64)
time.sleep(3600)' "$1" &
  HC_CORE_SOCKET_PID=$!
  local i=0
  while [ ! -S "$1" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
}

stop_hc_core_socket() {  # <socket-path>
  [ -z "$HC_CORE_SOCKET_PID" ] || { kill "$HC_CORE_SOCKET_PID" 2>/dev/null; wait "$HC_CORE_SOCKET_PID" 2>/dev/null || true; }
  HC_CORE_SOCKET_PID=
  rm -f "$1"
}
