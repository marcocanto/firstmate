#!/usr/bin/env bash
# Behavior: bin/fm-evidence-review.sh prints a run's Test records and evidence
# files, flags identity markers left after home redaction, and refuses a run it
# cannot review.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required for fm-evidence-review.sh"

TMP_ROOT=$(fm_test_tmproot fm-evidence-review)
NMH="$TMP_ROOT/nm"
mkdir -p "$NMH/evidence"
# An invented user and home keep the operator's real identity out of every
# fixture; getpass.getuser() reads LOGNAME first and Path.home() reads HOME.
USER_NAME=quillsmith
export LOGNAME="$USER_NAME" USER="$USER_NAME" HOME="$TMP_ROOT/home/$USER_NAME"
mkdir -p "$HOME"

# make_run <run-id> <summary> <round-caption>: one run with a Test step result
# and one round, in the v1.79.0 table shape the helper reads.
make_run() {
  python3 - "$NMH/state.sqlite" "$1" "$2" "$3" <<'PY'
import json, sqlite3, sys
db, run, summary, caption = sys.argv[1:]
conn = sqlite3.connect(db)
conn.execute("CREATE TABLE IF NOT EXISTS step_results (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, findings_json TEXT)")
conn.execute("CREATE TABLE IF NOT EXISTS step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT, round INTEGER, findings_json TEXT)")
conn.execute("INSERT INTO step_results VALUES (?, ?, 'test', ?)", ("sr-" + run, run, json.dumps({"testing_summary": summary})))
conn.execute("INSERT INTO step_rounds VALUES (?, ?, 1, ?)", ("rd-" + run, "sr-" + run, json.dumps({"artifacts": [{"label": "log", "content": caption}]})))
conn.commit()
PY
}

make_run clean "Drove the fixture and it passed." "Output of the fixture run"
mkdir -p "$NMH/evidence/clean"
printf 'fixture output line\n' > "$NMH/evidence/clean/out.log"
printf '\000\001' > "$NMH/evidence/clean/shot.png"

out=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" clean)
rc=$?
expect_code 0 "$rc" "a run with no hit exits 0"
assert_contains "$out" "Drove the fixture and it passed." "step result text is printed"
assert_contains "$out" "--- test round 1" "round records are printed"
assert_contains "$out" "--- out.log (text," "text evidence file is listed"
assert_contains "$out" "fixture output line" "text evidence content is printed"
assert_contains "$out" "--- shot.png (not UTF-8 text, 2 bytes)" "binary evidence is listed by size"
pass "clean run prints records and files and exits 0"

# The username keeps substring matching, so it is flagged inside a longer handle.
make_run leaky "Checked the private-widget repo as ${USER_NAME}42." "plain caption"
out=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" --term private-widget leaky)
rc=$?
expect_code 1 "$rc" "username and term in Test text are flagged"
assert_contains "$out" "username '$USER_NAME': test step result line" "username inside a longer handle names its record"
assert_contains "$out" "term 'private-widget': test step result line" "term marker names its record"
assert_contains "$out" "(none)" "a run with no evidence directory reports no files"
pass "markers in Test text exit 1"

# Host markers come from the system host name and scutil. A fake scutil gives
# invented names, so the fixture never carries this machine's real host name.
# Host markers match whole words only, while terms keep substring matching.
FAKE_BIN="$TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/scutil" <<'SH'
#!/bin/sh
case "$2" in
  ComputerName) echo "Tern Studio" ;;
  LocalHostName) echo "tern" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE_BIN/scutil"

make_run hostword "Checked the pattern match in tern_cache for the interns." "plain caption"
out=$(PATH="$FAKE_BIN:$PATH" "$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" hostword)
rc=$?
expect_code 0 "$rc" "a host name inside a longer word is not a hit"
assert_not_contains "$out" "hostname '" "a host name inside a longer word is not flagged"

make_run hostname "Ran on TERN, reached tern.example.test, then Tern Studio." "plain caption"
out=$(PATH="$FAKE_BIN:$PATH" "$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" hostname)
rc=$?
expect_code 1 "$rc" "a whole-word host name is flagged"
assert_contains "$out" "hostname 'tern': test step result line" "a whole-word host name names its record"
assert_contains "$out" "hostname 'Tern Studio': test step result line" "a whole-word computer name names its record"

make_run termword "Checked the widgetry module." "plain caption"
out=$(PATH="$FAKE_BIN:$PATH" "$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" --term widget termword)
rc=$?
expect_code 1 "$rc" "a term inside a longer word is still flagged"
assert_contains "$out" "term 'widget': test step result line" "a term keeps substring matching"
pass "host names match whole words only and terms still match substrings"

make_run homepath "Read notes at $HOME/notes/plan.txt." "plain caption"
out=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" homepath)
rc=$?
expect_code 1 "$rc" "a home path is flagged even after redaction"
assert_contains "$out" "home path: test step result line" "home path hit names its record"
assert_not_contains "$out" "username '" "the redacted home path does not also count as a username"
pass "home paths exit 1 without a username hit"

make_run worktree "Ran from $HOME/.treehouse/pool/2/repo." "Copied into $NMH/worktrees/abc/worktree/out.log"
mkdir -p "$NMH/evidence/worktree"
printf 'cwd %s/.no-mistakes/worktrees/abc/run\n' "$HOME" > "$NMH/evidence/worktree/cwd.log"
printf 'secret\n' > "$TMP_ROOT/outside.txt"
ln -s "$TMP_ROOT/outside.txt" "$NMH/evidence/worktree/link.txt"
out=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" worktree)
rc=$?
expect_code 1 "$rc" "worktree paths and symlinks are flagged"
assert_contains "$out" "worktree path '.treehouse/': test step result line" "a redacted treehouse path is a hit"
assert_contains "$out" "worktree path '.no-mistakes/worktrees/': cwd.log line 1" "a redacted no-mistakes worktree path is a hit"
assert_contains "$out" "/nm/worktrees/': test round 1 line" "the configured no-mistakes worktrees path is a hit"
assert_contains "$out" "refused entry: link.txt" "a symlinked evidence entry is a hit"
assert_not_contains "$out" "secret" "a symlinked evidence entry is never read"
pass "worktree paths and symlinked entries exit 1"

err=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" missing 2>&1 >/dev/null)
rc=$?
expect_code 2 "$rc" "unknown run is refused"
assert_contains "$err" "has no test step" "refusal names the missing Test step"

err=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$TMP_ROOT/absent" clean 2>&1 >/dev/null)
rc=$?
expect_code 2 "$rc" "absent state database is refused"
assert_contains "$err" "state database not found" "refusal names the missing database"

err=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" ../clean 2>&1 >/dev/null)
rc=$?
expect_code 2 "$rc" "a run id with a path separator is refused"
assert_contains "$err" "one path segment" "refusal names the run id rule"

printf 'test:\n  evidence:\n    local_root: /srv/evidence\n' > "$NMH/config.yaml"
err=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" clean 2>&1 >/dev/null)
rc=$?
expect_code 2 "$rc" "a moved evidence root without --evidence-root is refused"
assert_contains "$err" "pass --evidence-root" "refusal asks for the evidence root"
"$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" --evidence-root "$NMH/evidence" clean >/dev/null
expect_code 0 "$?" "an explicit evidence root is accepted"
rm -f "$NMH/config.yaml"
pass "unreviewable runs exit 2"
