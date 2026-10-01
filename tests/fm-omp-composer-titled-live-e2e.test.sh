#!/usr/bin/env bash
# tests/fm-omp-composer-titled-live-e2e.test.sh - live guard for omp's
# titled-rule composer through Herdr (live-harness-optin family).
#
# omp's `claude` composer shape writes the session title into the right end of
# the rule above its `❯` row, then draws a solid rule and its status row. The
# shared classifier (bin/fm-composer-lib.sh) reads that shape only from
# vendor-rendered rows, so this guard proves it against the real omp binary:
#   - an idle titled omp composer classifies `empty`, and
#     `bin/fm-control.sh <id> exit` stops the agent;
#   - typed text in the same shape classifies `pending`, `exit` refuses, and
#     the text stays in the composer.
# No prompt is ever submitted, so no model tokens are spent: omp resumes a
# generated two-line session file that holds only a title, with `--no-title`
# and a private `--session-dir`, under a private config that pins only the
# composer shape and turns off the update check, whose banner draws solid
# rules above the composer.
#
# Every Herdr call, including adapter calls, goes through bin/fm-herdr-lab.sh
# on a private named lab session. Refresh docs/verification/runtime-backends.md
# ("titled-rule composer") from this guard's output after an omp upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_OMP_COMPOSER_TITLED_LIVE herdr jq omp

[ -x "$LAB_HELPER" ] || fail "the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name omp-composer-titled)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-omp-composer-titled.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
WT="$TMP_ROOT/wt"
TITLE='Lab composer title'
mkdir -p "$FAKEBIN" "$WT"

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  [ ! -d "$HOME_DIR" ] || "$LAB_HOME_HELPER" teardown "$HOME_DIR" >/dev/null 2>&1 || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HOME_HELPER" create "$HOME_DIR" >/dev/null || fail "could not create the private lab firstmate home"

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

cat > "$TMP_ROOT/omp-config.yml" <<'EOF'
composer:
  shape: claude
startup:
  checkUpdate: false
EOF

git -C "$WT" init -q
printf '# lab\n' > "$WT/README.md"
git -C "$WT" add README.md
git -C "$WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
OMP_VER=$(PATH="$ORIGINAL_PATH" omp --version 2>/dev/null | head -1 || printf 'version-unknown')
LABEL="$OMP_VER on Herdr"

screen_plain() {  # <pane>
  lab pane read "$1" --source visible 2>/dev/null | fm_composer_strip_ansi
}

# titled_shape_visible <pane>: 0 when the visible screen shows the shape this
# guard exists for - the titled rule directly above the `❯` row, then a solid
# rule, then omp's status row - so a pass can never come from another shape.
titled_shape_visible() {
  local rows n i a b c d
  rows=$(screen_plain "$1")
  n=$(printf '%s\n' "$rows" | wc -l)
  i=1
  while [ "$i" -le $((n - 3)) ]; do
    a=$(printf '%s\n' "$rows" | sed -n "${i}p"); fm_composer_normalize_trim_var a
    b=$(printf '%s\n' "$rows" | sed -n "$((i + 1))p"); fm_composer_normalize_trim_var b
    c=$(printf '%s\n' "$rows" | sed -n "$((i + 2))p"); fm_composer_normalize_trim_var c
    d=$(printf '%s\n' "$rows" | sed -n "$((i + 3))p"); fm_composer_normalize_trim_var d
    case "$a" in *"$TITLE"*) ;; *) i=$((i + 1)); continue ;; esac
    case "$b" in '❯'*) ;; *) i=$((i + 1)); continue ;; esac
    if _fm_composer_titled_rule_row "$a" && _fm_composer_pi_separator_row "$c" \
       && _fm_composer_row_is_omp_status "$d"; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# titled_session <id>: a minimal omp session file holding only a title and a
# session header, so omp opens with the titled-rule composer and no turn is
# ever needed to name the session. omp rewrites the title line in place and
# refuses a header that is not padded to its fixed 255-byte width (verified,
# omp 18.4.5 `--export`: "the session header is missing or malformed").
titled_session() {
  local id=$1 dir file uuid bare pad
  dir="$TMP_ROOT/sessions/$id"
  mkdir -p "$dir"
  uuid=$(printf '%08x-0000-7000-8000-%012x' "$$" "$RANDOM$RANDOM")
  file="$dir/session-$id.jsonl"
  bare=$(jq -cn --arg t "$TITLE" '{type: "title", v: 1, title: $t, source: "user", updatedAt: "2026-01-01T00:00:00.000Z", pad: ""}')
  pad=$(printf '%*s' "$((255 - ${#bare}))" '')
  jq -cn --arg t "$TITLE" --arg p "$pad" '{type: "title", v: 1, title: $t, source: "user", updatedAt: "2026-01-01T00:00:00.000Z", pad: $p}' > "$file"
  jq -cn --arg id "$uuid" --arg cwd "$WT" --arg t "$TITLE" \
    '{type: "session", version: 3, id: $id, timestamp: "2026-01-01T00:00:00.000Z", cwd: $cwd, title: $t, titleSource: "user"}' >> "$file"
  printf '%s' "$file"
}

# launch_titled <id>: a resumed titled omp in its own lab pane with a task
# record in the private home. Prints the pane id. No prompt is ever submitted.
launch_titled() {
  local id=$1 ws pane tab wsid i st file
  file=$(titled_session "$id")
  ws=$(lab workspace create --cwd "$WT" --label "fm-$id" --no-focus) \
    || fail "could not create the lab workspace for $id"
  pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') \
    || fail "workspace create did not return a pane id"
  tab=$(printf '%s' "$ws" | jq -er '.result.root_pane.tab_id')
  wsid=$(printf '%s' "$ws" | jq -er '.result.workspace.workspace_id // .result.root_pane.workspace_id')
  lab pane run "$pane" "env -u CLAUDECODE FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 omp --config '$TMP_ROOT/omp-config.yml' --session-dir '$TMP_ROOT/sessions/$id' --resume '$file' --no-title --auto-approve --cwd '$WT'" >/dev/null \
    || fail "could not launch omp ($LABEL) in the lab pane"
  i=0
  while [ "$i" -lt 60 ]; do
    st=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done) titled_shape_visible "$pane" && break ;; esac
    i=$((i + 1)); sleep 1
  done
  [ "$i" -lt 60 ] || fail "omp ($LABEL) never drew an idle titled-rule composer above its status row; re-verify the shape"
  {
    echo "window=$SESSION:$pane"
    echo "endpoint_task_id=$id"
    echo "worktree=$WT"
    echo "project=$WT"
    echo "harness=omp"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$SESSION"
    echo "herdr_workspace_id=$wsid"
    echo "herdr_tab_id=$tab"
    echo "herdr_pane_id=$pane"
  } > "$HOME_DIR/state/$id.meta"
  printf '%s' "$pane"
}

control() {
  env FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.3 FM_CONTROL_EXIT_WAIT=15 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- idle: proven empty, and exit stops the agent ---------------------------
PANE=$(launch_titled omptitled) || exit 1
verdict=$(fm_backend_herdr_composer_state "$SESSION:$PANE")
[ "$verdict" = empty ] || fail "$LABEL: an idle titled-rule omp composer must read empty, got '$verdict'"
out=$(control omptitled exit) || fail "$LABEL: exit refused an idle titled-rule omp composer: $out"
case "$out" in
  "stopped omptitled"*) ;;
  *) fail "$LABEL: exit did not report stopped: $out" ;;
esac
pass "$LABEL: an idle titled-rule omp composer reads empty and exit stops the agent"

# --- typed: pending, exit refuses, text preserved --------------------------
PANE=$(launch_titled omptyped) || exit 1
lab pane send-text "$PANE" "typed draft text" >/dev/null || fail "could not type the draft"
sleep 1
verdict=$(fm_backend_herdr_composer_state "$SESSION:$PANE")
[ "$verdict" = pending ] || fail "$LABEL: typed text in a titled-rule omp composer must read pending, got '$verdict'"
if out=$(control omptyped exit); then
  fail "$LABEL: exit typed into a composer holding text: $out"
fi
case "$out" in
  *'visibly holds pending text'*) ;;
  *) fail "$LABEL: exit refused for the wrong reason: $out" ;;
esac
sleep 1
screen_plain "$PANE" | grep -q '❯ typed draft text' \
  || fail "$LABEL: the typed draft did not survive the refused exit"
pass "$LABEL: typed text in a titled-rule omp composer reads pending, exit refuses, and the text stays"
