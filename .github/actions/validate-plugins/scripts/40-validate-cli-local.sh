#!/usr/bin/env bash
# For each CHANGED in-repo plugin folder (folders containing
# .claude-plugin/plugin.json that the PR touched): run `claude plugin validate`.

source "$ACTION_PATH/lib/common.sh"

: "${VALIDATE_TMP:?}"
CHANGES="$VALIDATE_TMP/changes.json"

group_start "CLI: claude plugin validate (changed in-repo plugin folders)"

count="$(jq '.folders | length' -- "$CHANGES")"
if [[ "$count" -eq 0 ]]; then
  log "No changed in-repo plugin folders; skipping."
  record_result "cli-local" "skip" "summary" "no changed local plugin folders"
  group_end
  exit 0
fi

failures=0

# This step runs BEFORE the aux-file step, and 00-detect-changes.sh selects a
# folder with `-f`, which follows symlinks. Without the same containment guard
# here, a changed local plugin could point `claude plugin validate` at a
# manifest outside the checkout before anything else looked.
WS_ROOT="${GITHUB_WORKSPACE:-$PWD}"

while IFS= read -r folder; do
  assert_safe_path "$folder"
  manifest="$folder/.claude-plugin/plugin.json"
  log "---- $(annot_text "$folder" 200) ----"

  if [[ ! -f "$manifest" ]]; then
    error "$folder: plugin.json missing (was present at detect time?)"
    record_result "cli-local" "fail" "$folder" "plugin.json missing"
    failures=$((failures+1))
    continue
  fi

  if [[ -L "$manifest" ]]; then
    error "$folder: plugin.json is a symlink"
    record_result "cli-local" "fail" "$folder" "plugin.json is a symlink"
    failures=$((failures+1))
    continue
  fi

  if ! why="$(path_contained_or_reason "$folder" "$WS_ROOT")" \
     || ! why="$(path_contained_or_reason "$manifest" "$WS_ROOT")"; then
    error "$folder: ${why:-not contained in the workspace}"
    record_result "cli-local" "fail" "$folder" "${why:-not contained in the workspace}"
    failures=$((failures+1))
    continue
  fi

  if ! cli_validate "cli-local" "$folder" "$manifest"; then
    failures=$((failures+1))
  fi
done < <(jq -r '.folders[]' -- "$CHANGES")

if (( failures > 0 )); then
  die "$failures in-repo plugin folder(s) failed validation"
fi

log "All $count changed in-repo plugin folder(s) validated OK"
group_end
