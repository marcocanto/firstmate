#!/usr/bin/env bash
# fm-status-sorter-lib.sh - opt-in status-wake sorter for the watcher's
# status-signal path, plus the held-line log the wake drain presents.
#
# Default off. Without config/status-sorter, fm_status_sorter_enabled fails and
# the watcher reads no span, no key, and no network for it, so its signal path
# is unchanged.
#
# When enabled, bin/fm-watch.sh consults this library only for a status-signal
# batch its ordinary triage has already decided to surface, and only while no
# away or quiet record (state/.afk) exists. Every new line in the batch passes
# two tiers:
#   - Rule tier, deterministic and local. A line is a hold candidate only when
#     its verb is working, including a steer reply that carries a corr= token.
#     Every other verb wakes: needs-decision, blocked, failed, paused,
#     captain-held, resolved, note, every done line, and any unrecognised
#     prefix. A candidate still wakes when it states a [key=...],
#     names a child-outcome or child-pr key, names a PR URL or pr= token,
#     mentions a merge, or matches the classifier's free-text captain tokens.
#   - Model tier, only for candidates the rules left. One chat-completions
#     request per candidate asks whether the supervisor needs to act on or
#     learn from the line now. Only an answer of "no" at or above
#     hold_confidence holds it. A "yes", the unsure band below that threshold, a
#     timeout, a connection failure, a non-200 answer, a missing key, curl or
#     jq, an invalid config, more than FM_STATUS_SORTER_MAX_CANDIDATES
#     candidates in one batch, or a malformed answer wakes.
# The batch is held only when every new line of every status file in it is
# held; any wake surfaces the whole batch exactly as without the sorter.
#
# A held line is still a durable status line; only its wake is suppressed. The
# watcher appends each held line to state/status-sorter-held.log before it
# advances any marker, one tab-separated row per line:
#   <epoch> <task> <tier> <reason> <status line>
# fm_status_sorter_held_section prints the rows main has not seen yet as the
# drain's HELD STATUS section and then advances state/.status-sorter-held.cursor
# (<log identity><TAB><byte offset>). The log is never rewritten here; deleting
# it is safe and only drops already-durable status copies.
#
# Config (config/status-sorter, local and gitignored; docs/configuration.md
# "Status-wake sorter" owns the operator-facing description):
#   endpoint=<http or https URL of a chat-completions endpoint>   required
#   model=<model name sent in the request>                        required
#   key_file=<absolute path of a file whose first line is the key> required
#   timeout=<whole seconds, 1-30>                                  default 5
#   hold_confidence=<decimal from 0.5 to 1>                        default 0.8
# Blank lines and # comments are skipped; any other line, unknown key, or bad
# value makes the config invalid, and an invalid config wakes every candidate.
# The key is sent as an Authorization bearer header through curl's stdin
# config, never on a command line.
#
# No side effects on source.

_FM_STATUS_SORTER_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_STATUS_SORTER_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$_FM_STATUS_SORTER_LIB_DIR/fm-line-cap-lib.sh"

FM_STATUS_SORTER_MAX_CANDIDATES=4
FM_STATUS_SORTER_SECTION_ITEM_BYTES=300
FM_STATUS_SORTER_SECTION_BYTES=4000
# PR and merge news beyond the classifier's free-text captain tokens: a forge
# pull or merge request URL, a pr= metadata token, or any merge wording.
FM_STATUS_SORTER_NEWS_RE='https?://[^[:space:]]+/(pull|pulls|merge_requests|merge-requests)/[0-9]+|(^|[^[:alnum:]_])pr=|merg'
FM_STATUS_SORTER_PROMPT='You sort status lines that worker agents append for their supervisor, an agent that is woken for every line it must handle. Answer one question about the line you are given: does the supervisor need to act on or learn from this line now? Reply with only a JSON object of the form {"answer":"yes","confidence":0.9}, where answer is "yes" or "no" and confidence is a number from 0 to 1. Answer "yes" when unsure.'

FM_STATUS_SORTER_REASON=''
FM_STATUS_SORTER_CANDIDATES=''
FM_STATUS_SORTER_HELD=''
FM_STATUS_SORTER_CONFIG_ERROR=''

fm_status_sorter_config_path() {  # <config-dir>
  printf '%s/status-sorter' "$1"
}

fm_status_sorter_held_log() {  # <state-dir>
  printf '%s/status-sorter-held.log' "$1"
}

fm_status_sorter_held_cursor() {  # <state-dir>
  printf '%s/.status-sorter-held.cursor' "$1"
}

# 0 when this home opted in. Presence alone opts in; validity is checked when
# the model tier needs the values.
fm_status_sorter_enabled() {  # <config-dir>
  local path
  path=$(fm_status_sorter_config_path "$1")
  [ -e "$path" ] || [ -L "$path" ]
}

# Load and validate config/status-sorter into FM_STATUS_SORTER_ENDPOINT,
# _MODEL, _KEY_FILE, _TIMEOUT, and _HOLD_CONFIDENCE. 1 with
# FM_STATUS_SORTER_CONFIG_ERROR set when the file is unreadable or invalid.
fm_status_sorter_load_config() {  # <config-dir>
  local path line key value endpoint='' model='' key_file='' timeout=5 hold=0.8 n=0
  path=$(fm_status_sorter_config_path "$1")
  FM_STATUS_SORTER_CONFIG_ERROR=''
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    FM_STATUS_SORTER_CONFIG_ERROR="$path is not a readable file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) FM_STATUS_SORTER_CONFIG_ERROR="line $n is not key=value"; return 1 ;;
    esac
    key=${key%"${key##*[![:space:]]}"}
    value=${value#"${value%%[![:space:]]*}"}
    case "$key" in
      endpoint) endpoint=$value ;;
      model) model=$value ;;
      key_file) key_file=$value ;;
      timeout) timeout=$value ;;
      hold_confidence) hold=$value ;;
      *) FM_STATUS_SORTER_CONFIG_ERROR="line $n has unknown key '$key'"; return 1 ;;
    esac
  done < "$path"
  case "$endpoint" in
    http://?*|https://?*) ;;
    *) FM_STATUS_SORTER_CONFIG_ERROR="endpoint must be an http or https URL"; return 1 ;;
  esac
  case "$endpoint" in
    *[[:space:]]*) FM_STATUS_SORTER_CONFIG_ERROR="endpoint must not contain whitespace"; return 1 ;;
  esac
  [ -n "$model" ] || { FM_STATUS_SORTER_CONFIG_ERROR="model is required"; return 1; }
  case "$key_file" in
    /?*) ;;
    *) FM_STATUS_SORTER_CONFIG_ERROR="key_file must be an absolute path"; return 1 ;;
  esac
  case "$timeout" in
    [1-9]|[12][0-9]|30) ;;
    *) FM_STATUS_SORTER_CONFIG_ERROR="timeout must be whole seconds from 1 to 30"; return 1 ;;
  esac
  if ! [[ $hold =~ ^(0\.[5-9][0-9]*|1|1\.0+)$ ]]; then
    FM_STATUS_SORTER_CONFIG_ERROR="hold_confidence must be a decimal from 0.5 to 1"
    return 1
  fi
  FM_STATUS_SORTER_ENDPOINT=$endpoint
  FM_STATUS_SORTER_MODEL=$model
  FM_STATUS_SORTER_KEY_FILE=$key_file
  FM_STATUS_SORTER_TIMEOUT=$timeout
  FM_STATUS_SORTER_HOLD_CONFIDENCE=$hold
}

# The classifier's free-text captain tokens: its captain alternatives without
# the verb ones (those end in a colon), so one vocabulary decides both.
_fm_status_sorter_captain_tokens() {
  local alt out='' re=${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}
  local IFS='|'
  set -f
  for alt in $re; do
    case "$alt" in ''|*:) ;; *) out=${out:+$out|}$alt ;; esac
  done
  set +f
  printf '%s' "$out"
}

# Rule tier for one status line. 0 when it is a hold candidate for the model
# tier; 1 when it wakes. FM_STATUS_SORTER_REASON names the rule either way.
fm_status_sorter_rule() {  # <status-line>
  local line=$1 unstamped sorter_verb tokens
  _fm_status_unstamped "$line" unstamped
  status_line_verb "$line" sorter_verb
  case "$sorter_verb" in
    working) ;;
    done)
      FM_STATUS_SORTER_REASON='rule: finished work always wakes'
      return 1
      ;;
    *)
      FM_STATUS_SORTER_REASON="rule: verb '${sorter_verb}' always wakes"
      return 1
      ;;
  esac
  if _fm_key_before_colon "$unstamped" || _fm_key_at_note_head "$unstamped" >/dev/null; then
    FM_STATUS_SORTER_REASON='rule: a keyed line always wakes'
    return 1
  fi
  case "$unstamped" in
    *child-outcome*|*child-pr*)
      FM_STATUS_SORTER_REASON='rule: child outcome or child PR news always wakes'
      return 1
      ;;
  esac
  if _fm_classify_matches "$unstamped" "$FM_STATUS_SORTER_NEWS_RE"; then
    FM_STATUS_SORTER_REASON='rule: PR or merge news always wakes'
    return 1
  fi
  tokens=$(_fm_status_sorter_captain_tokens)
  if [ -n "$tokens" ] && _fm_classify_matches "$unstamped" "$tokens"; then
    FM_STATUS_SORTER_REASON='rule: a captain token always wakes'
    return 1
  fi
  FM_STATUS_SORTER_REASON='rule: working line is a candidate'
  return 0
}

# Start one batch decision.
fm_status_sorter_begin() {
  FM_STATUS_SORTER_CANDIDATES=''
  FM_STATUS_SORTER_HELD=''
  FM_STATUS_SORTER_REASON=''
}

# Rule-tier every nonblank line of one task's new status span. 1 as soon as a
# line wakes or the span holds no line; candidates accumulate for
# fm_status_sorter_decide as "<task><TAB><line>" rows.
fm_status_sorter_add_span() {  # <task> <span-text>
  local task=$1 line found=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    line=${line//$'\t'/ }
    line=${line%$'\r'}
    fm_status_sorter_rule "$line" || return 1
    FM_STATUS_SORTER_CANDIDATES="${FM_STATUS_SORTER_CANDIDATES}${task}"$'\t'"${line}"$'\n'
    found=1
  done <<EOF
$2
EOF
  if [ "$found" -eq 0 ]; then
    FM_STATUS_SORTER_REASON='rule: no status line to sort'
    return 1
  fi
}

# Parse one chat-completions response body into "yes <c>", "no <c>", or
# "malformed". The answer object may arrive bare, fenced, or inside prose.
_fm_status_sorter_parse_answer() {  # <response-file>
  jq -r '
    def obj: (try fromjson catch null)
      // (try (gsub("\n"; " ") | capture("(?<j>\\{.*\\})").j | fromjson) catch null);
    (.choices[0].message.content // null) as $c
    | if ($c | type) != "string" then "malformed"
      else ($c | obj) as $o
      | if ($o | type) != "object" then "malformed"
        else (if ($o.answer | type) == "string" then ($o.answer | ascii_downcase) else null end) as $a
        | $o.confidence as $n
        | if ($a == "yes" or $a == "no") and ($n | type) == "number" and $n >= 0 and $n <= 1
          then "\($a) \($n)" else "malformed" end
        end
      end
  ' "$1" 2>/dev/null || printf 'malformed'
}

# Model tier for one candidate line, with the config already loaded. 0 holds
# it; 1 wakes it. FM_STATUS_SORTER_REASON names the outcome either way.
fm_status_sorter_ask() {  # <status-line>
  local line=$1 key='' tmp code rc verdict answer confidence
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    FM_STATUS_SORTER_REASON='model: curl or jq unavailable'
    return 1
  fi
  if [ ! -f "$FM_STATUS_SORTER_KEY_FILE" ] || [ ! -r "$FM_STATUS_SORTER_KEY_FILE" ]; then
    FM_STATUS_SORTER_REASON='model: key file missing or unreadable'
    return 1
  fi
  IFS= read -r key < "$FM_STATUS_SORTER_KEY_FILE" || [ -n "$key" ] || key=''
  key=${key#"${key%%[![:space:]]*}"}
  key=${key%"${key##*[![:space:]]}"}
  case "$key" in
    '') FM_STATUS_SORTER_REASON='model: key file is empty'; return 1 ;;
    *[\"\\[:cntrl:]]*) FM_STATUS_SORTER_REASON='model: key has characters a header cannot carry'; return 1 ;;
  esac
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-status-sorter.XXXXXX") || {
    FM_STATUS_SORTER_REASON='model: no scratch directory'
    return 1
  }
  if ! jq -n --arg model "$FM_STATUS_SORTER_MODEL" --arg sys "$FM_STATUS_SORTER_PROMPT" \
    --arg line "$line" \
    '{model: $model, messages: [{role: "system", content: $sys}, {role: "user", content: ("Status line: " + $line)}]}' \
    > "$tmp/body" 2>/dev/null; then
    rm -rf "$tmp"
    FM_STATUS_SORTER_REASON='model: request could not be built'
    return 1
  fi
  rc=0
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
    | curl -q -sS -K - --proto '=http,https' \
      --connect-timeout "$FM_STATUS_SORTER_TIMEOUT" --max-time "$FM_STATUS_SORTER_TIMEOUT" \
      -H 'Content-Type: application/json' --data-binary @"$tmp/body" \
      -o "$tmp/response" -w '%{http_code}' -- "$FM_STATUS_SORTER_ENDPOINT" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$tmp"
    FM_STATUS_SORTER_REASON="model: unreachable (curl exit $rc)"
    return 1
  fi
  if [ "$code" != 200 ]; then
    rm -rf "$tmp"
    FM_STATUS_SORTER_REASON="model: answered HTTP $code"
    return 1
  fi
  verdict=$(_fm_status_sorter_parse_answer "$tmp/response")
  rm -rf "$tmp"
  answer=${verdict%% *}
  confidence=${verdict#* }
  case "$answer" in
    yes)
      FM_STATUS_SORTER_REASON="model: yes (confidence $confidence)"
      return 1
      ;;
    no)
      if awk -v c="$confidence" -v t="$FM_STATUS_SORTER_HOLD_CONFIDENCE" 'BEGIN { exit !(c + 0 >= t + 0) }'; then
        FM_STATUS_SORTER_REASON="model: no (confidence $confidence)"
        return 0
      fi
      FM_STATUS_SORTER_REASON="model: unsure (no at confidence $confidence, below $FM_STATUS_SORTER_HOLD_CONFIDENCE)"
      return 1
      ;;
  esac
  FM_STATUS_SORTER_REASON='model: malformed answer'
  return 1
}

# Model-tier every accumulated candidate. 0 when all were held, with
# FM_STATUS_SORTER_HELD set to "<task><TAB><tier><TAB><reason><TAB><line>"
# rows; 1 at the first wake, or when the config is invalid or the batch has
# more candidates than one batch may ask about.
fm_status_sorter_decide() {  # <config-dir>
  local task line count
  count=$(printf '%s' "$FM_STATUS_SORTER_CANDIDATES" | awk 'END { print NR }')
  if [ "$count" -eq 0 ]; then
    FM_STATUS_SORTER_REASON='rule: no status line to sort'
    return 1
  fi
  if [ "$count" -gt "$FM_STATUS_SORTER_MAX_CANDIDATES" ]; then
    FM_STATUS_SORTER_REASON="rule: $count candidate lines exceed the per-batch limit of $FM_STATUS_SORTER_MAX_CANDIDATES"
    return 1
  fi
  if ! fm_status_sorter_load_config "$1"; then
    FM_STATUS_SORTER_REASON="model: config invalid ($FM_STATUS_SORTER_CONFIG_ERROR)"
    return 1
  fi
  FM_STATUS_SORTER_HELD=''
  while IFS=$'\t' read -r task line; do
    [ -n "$task" ] || continue
    fm_status_sorter_ask "$line" || return 1
    FM_STATUS_SORTER_HELD="${FM_STATUS_SORTER_HELD}${task}"$'\t'model$'\t'"${FM_STATUS_SORTER_REASON}"$'\t'"${line}"$'\n'
  done <<EOF
$FM_STATUS_SORTER_CANDIDATES
EOF
}

# Append the batch's held rows, stamped with the current epoch, to the held log.
# Callers write this before advancing any marker, so a failed append leaves the
# batch to surface instead.
fm_status_sorter_record_held() {  # <state-dir>
  local log now rows
  [ -n "$FM_STATUS_SORTER_HELD" ] || return 1
  log=$(fm_status_sorter_held_log "$1")
  now=$(date +%s) || return 1
  rows=$(printf '%s' "$FM_STATUS_SORTER_HELD" | awk -v now="$now" 'NF { print now "\t" $0 }') || return 1
  [ -n "$rows" ] || return 1
  printf '%s\n' "$rows" >> "$log" 2>/dev/null
}

# Print the HELD STATUS section for rows appended since the last presentation,
# then advance the cursor past them. Silent when nothing is new. Only whole
# rows are presented; a partial final row waits for the next drain. A log
# replaced since the cursor was written is presented from its start.
fm_status_sorter_held_section() {  # <state-dir>
  local state=$1 log cursor ident size saved='' saved_ident saved_offset offset=0 end tmp last partial
  local epoch task tier reason line item bytes used=0 shown=0 omitted=0 output='' total
  log=$(fm_status_sorter_held_log "$state")
  cursor=$(fm_status_sorter_held_cursor "$state")
  [ -f "$log" ] && [ ! -L "$log" ] || return 0
  _fm_status_stat_fields "$log" || return 1
  ident=$_FM_STAT_IDENTITY
  size=$_FM_STAT_SIZE
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -f "$cursor" ]; then
    IFS= read -r saved < "$cursor" || [ -n "$saved" ] || saved=''
    saved_ident=${saved%%$'\t'*}
    saved_offset=${saved#*$'\t'}
    case "$saved_offset" in ''|*[!0-9]*) ;; *)
      if [ "$saved_ident" = "$ident" ] && [ "$saved_offset" -le "$size" ]; then
        offset=$saved_offset
      fi
      ;;
    esac
  fi
  [ "$offset" -lt "$size" ] || return 0
  tmp=$(mktemp "$state/.status-sorter-held.read.XXXXXX") || return 1
  if ! _fm_status_read_span "$log" "$offset" "$((size - offset))" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  end=$size
  last=$(tail -c 1 "$tmp" | od -An -tx1 | tr -d ' \n')
  if [ "$last" != 0a ]; then
    partial=$(tail -n 1 "$tmp" | LC_ALL=C wc -c | tr -d ' ')
    end=$((size - partial))
  fi
  if [ "$end" -le "$offset" ]; then
    rm -f "$tmp"
    return 0
  fi
  total=0
  while IFS=$'\t' read -r epoch task tier reason line; do
    [ -n "$task" ] || continue
    total=$((total + 1))
    item="$task $line [held by $tier: ${reason#"$tier: "}]"
    fm_cap_line_var "$item" $((FM_STATUS_SORTER_SECTION_ITEM_BYTES - 1))
    item=$FM_LINE_CAP_LINE
    bytes=$(( ${#item} + 1 ))
    if [ $((used + bytes)) -gt "$FM_STATUS_SORTER_SECTION_BYTES" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$item"$'\n'
    used=$((used + bytes))
    shown=$((shown + 1))
  done < <(head -c "$((end - offset))" "$tmp")
  rm -f "$tmp"
  if [ "$total" -gt 0 ]; then
    printf 'HELD STATUS (%d status line(s) the status sorter kept from waking firstmate since the last drain; still durable in each task status log, not re-printed after this presentation):\n' "$total" || return 1
    printf '%s' "$output" || return 1
    if [ "$omitted" -gt 0 ]; then
      printf 'HELD STATUS: %d more omitted (byte cap); every held line is kept in %s\n' "$omitted" "$log" || return 1
    fi
  fi
  printf '%s\t%s\n' "$ident" "$end" > "$cursor.tmp.$$" && mv -f "$cursor.tmp.$$" "$cursor"
}
