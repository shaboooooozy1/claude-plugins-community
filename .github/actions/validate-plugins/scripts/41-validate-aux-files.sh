#!/usr/bin/env bash
# For each CHANGED in-repo plugin folder: parse the auxiliary JSON files the
# runtime loader always-probes (.mcp.json, .lsp.json, hooks/hooks.json).
# A malformed file here is a runtime crash that `claude plugin validate` may
# not surface as an error.

source "$ACTION_PATH/lib/common.sh"

# Marks this step done only on a zero exit, so an abort part-way through
# (a die, or set -e on an unexpected error) leaves it begun-but-unfinished
# and 90-report.sh fails the run rather than aggregating to PASS.
STEP_ID=41-aux-files
step_begin "$STEP_ID"
trap 'rc=$?; if [[ $rc -eq 0 ]]; then step_done "$STEP_ID"; fi' EXIT

: "${VALIDATE_TMP:?}"
CHANGES="$VALIDATE_TMP/changes.json"
AUX_FILES=(".mcp.json" ".lsp.json" "hooks/hooks.json")

group_start "Aux-file JSON parse (changed in-repo plugin folders)"

count="$(jq '.folders | length' -- "$CHANGES")"
if [[ "$count" -eq 0 ]]; then
  log "No changed in-repo plugin folders; skipping."
  record_result "aux-files" "skip" "summary" "no changed local plugin folders"
  group_end
  exit 0
fi

failures=0

# Containment is checked against physical paths, not the spelling of "$f":
# `-L "$f"` only sees a symlink in the FINAL component, so a contributor who
# makes an ancestor (e.g. `hooks/`) a symlink would otherwise have jq read a
# file outside the workspace. Shared with steps 11, 30 and 40 via common.sh.
WS_ROOT="${GITHUB_WORKSPACE:-$PWD}"

while IFS= read -r folder; do
  assert_safe_path "$folder"
  # A folder that no longer exists holds no aux files; nothing to parse.
  [[ -e "$folder" ]] || continue
  if ! why="$(path_contained_or_reason "$folder" "$WS_ROOT")"; then
    error "$folder: ${why:-not contained in the workspace}"
    record_result "aux-files" "fail" "$folder" "${why:-not contained in the workspace}"
    failures=$((failures+1))
    continue
  fi
  for aux in "${AUX_FILES[@]}"; do
    f="$folder/$aux"
    [[ -f "$f" ]] || continue
    if [[ -L "$f" ]]; then
      error "$f: is a symlink"
      record_result "aux-files" "fail" "$f" "symlink"
      failures=$((failures+1))
      continue
    fi
    if ! why="$(path_contained_or_reason "$f" "$folder")"; then
      error "$f: ${why:-not contained in the plugin folder}"
      record_result "aux-files" "fail" "$f" "${why:-not contained in the plugin folder}"
      failures=$((failures+1))
      continue
    fi
    if err="$(jq -e 'type' -- "$f" 2>&1 >/dev/null)"; then
      log "  ✓ $f parses"
      record_result "aux-files" "pass" "$f" ""
    else
      error "$f: invalid JSON"
      log_untrusted "$err"
      record_result "aux-files" "fail" "$f" "$err"
      failures=$((failures+1))
    fi
  done
done < <(jq -r '.folders[]' -- "$CHANGES")

if (( failures > 0 )); then
  die "$failures auxiliary file(s) failed to parse"
fi

log "All auxiliary files parse OK"
group_end
