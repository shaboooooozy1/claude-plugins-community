#!/usr/bin/env bash
# Aggregate results.jsonl into a markdown table for $GITHUB_STEP_SUMMARY
# and set the final `result` output.

source "$ACTION_PATH/lib/common.sh"

: "${VALIDATE_TMP:?}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
RESULTS="$VALIDATE_TMP/results.jsonl"

# This step runs with `if: always()`, so it also runs when an upstream script
# died before its first record_result and left no results file at all. jq -s
# reports 0 failures for empty or absent input, which would otherwise announce
# PASS for a run that validated nothing.
no_results=""
if [[ ! -s "$RESULTS" ]]; then
  no_results=1
  touch "$RESULTS"
  error "report: no results recorded — an earlier step did not complete"
  any_fail=1
elif ! any_fail="$(jq -s 'map(select(.status=="fail")) | length' -- "$RESULTS" 2>&1)" || [[ ! "$any_fail" =~ ^[0-9]+$ ]]; then
  error "report: could not parse $RESULTS ($any_fail)"
  any_fail=1
fi

{
  echo "## Plugin validation report"
  echo
  echo "| Step | Subject | Status | Detail |"
  echo "|---|---|---|---|"
  # Every cell is contributor-derived. A raw newline ends the table row and
  # lets the rest of the value be read as markdown, which could forge a
  # "Result: PASS" line below; a raw pipe splits the row into extra columns.
  # scan.sh's summary already strips both, so this matches it.
  jq -r 'def cell: (. // "") | tostring | gsub("[\\r\\n|]"; " ");
         "| \(.step | cell) | \(.subject | cell) | \(.status | cell) | \((.detail | cell) | .[0:200]) |"' \
      -- "$RESULTS" 2>/dev/null \
    || echo "| report | results.jsonl | fail | could not parse results file |"
  echo
  if [[ -n "$no_results" ]]; then
    echo "**Result: FAIL** — no validation results were recorded, so an earlier step did not complete"
  elif [[ "$any_fail" -gt 0 ]]; then
    echo "**Result: FAIL** ($any_fail failure(s))"
  else
    echo "**Result: PASS**"
  fi
} >> "$SUMMARY"

result="pass"
[[ "$any_fail" -gt 0 ]] && result="fail"

echo "result=$result" >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "report-path=$SUMMARY" >> "${GITHUB_OUTPUT:-/dev/stdout}"

[[ "$result" == "pass" ]] || exit 1
