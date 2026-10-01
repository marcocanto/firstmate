#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# keep both public test-evidence routes off, and park every run after Test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_keeps_evidence_private_until_reviewed() {
  local facts route gate_cmd rc
  facts=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
ev = ((doc["test"] || {})["evidence"]) || {}
puts "store_in_repo=#{ev["store_in_repo"].inspect}"
puts "attach_media=#{ev["attach_media"].inspect}"
gate = (doc["gates"] || []).find { |g| g["name"] == "evidence-review" && g["after"] == "test" }
puts "gate=#{gate ? gate["command"] : ""}"
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  # An unset key falls back to global config or to attach_media's default of
  # true, so each route must be explicitly false.
  for route in store_in_repo attach_media; do
    assert_contains "$facts" "$route=false" "test.evidence.$route must be explicitly false"
  done
  gate_cmd=$(printf '%s\n' "$facts" | sed -n 's/^gate=//p')
  [ -n "$gate_cmd" ] || fail "an evidence-review gate after test must exist"
  (cd "$(fm_test_tmproot fm-nm-gate)" && sh -c "$gate_cmd" >/dev/null 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the evidence-review gate command must fail so every run parks for review"
  pass "no-mistakes keeps test evidence private until the evidence-review gate"
}

test_nm_has_no_deterministic_test_command
test_nm_keeps_evidence_private_until_reviewed
