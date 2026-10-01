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
USER_NAME=$(python3 -c 'import getpass; print(getpass.getuser())')

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

make_run clean "Drove the fixture and it passed." "Output of $HOME/.no-mistakes/evidence/clean/out.log"
mkdir -p "$NMH/evidence/clean"
printf 'ran from %s/work\n' "$HOME" > "$NMH/evidence/clean/out.log"
printf '\000\001' > "$NMH/evidence/clean/shot.png"

out=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" clean)
rc=$?
expect_code 0 "$rc" "home paths alone are redacted, so no marker is flagged"
assert_contains "$out" "Drove the fixture and it passed." "step result text is printed"
assert_contains "$out" "--- test round 1" "round records are printed"
assert_contains "$out" "--- out.log (text," "text evidence file is listed"
assert_contains "$out" "ran from $HOME/work" "text evidence content is printed"
assert_contains "$out" "--- shot.png (not UTF-8 text, 2 bytes)" "binary evidence is listed by size"
pass "clean run prints records and files and exits 0"

make_run leaky "Checked the private-widget repo as $USER_NAME." "plain caption"
out=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" --term private-widget leaky)
rc=$?
expect_code 1 "$rc" "username and term in Test text are flagged"
assert_contains "$out" "username '$USER_NAME': test step result line" "username marker names its record"
assert_contains "$out" "term 'private-widget': test step result line" "term marker names its record"
assert_contains "$out" "(none)" "a run with no evidence directory reports no files"
pass "markers in Test text exit 1"

err=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$NMH" missing 2>&1 >/dev/null)
rc=$?
expect_code 2 "$rc" "unknown run is refused"
assert_contains "$err" "has no test step" "refusal names the missing Test step"

err=$("$ROOT/bin/fm-evidence-review.sh" --nm-home "$TMP_ROOT/absent" clean 2>&1 >/dev/null)
rc=$?
expect_code 2 "$rc" "absent state database is refused"
assert_contains "$err" "state database not found" "refusal names the missing database"
pass "unreviewable runs exit 2"
