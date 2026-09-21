#!/usr/bin/env bash
# For each CHANGED in-repo plugin folder: parse the auxiliary JSON files the
# runtime loader always-probes (.mcp.json, .lsp.json, hooks/hooks.json).
# A malformed file here is a runtime crash that `claude plugin validate` may
# not surface as an error.

source "$ACTION_PATH/lib/common.sh"

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
# file outside the workspace. Same guard as the external manifest in step 30.
root_phys="$(realpath -- "${GITHUB_WORKSPACE:-$PWD}" 2>/dev/null || true)"
[[ -n "$root_phys" ]] || die "cannot resolve workspace root"

while IFS= read -r folder; do
  assert_safe_path "$folder"
  folder_phys="$(realpath -- "$folder" 2>/dev/null || true)"
  # A folder that no longer exists holds no aux files; nothing to parse.
  [[ -n "$folder_phys" ]] || continue
  if [[ "$folder_phys" != "$root_phys" && "$folder_phys" != "$root_phys"/* ]]; then
    error "$folder: resolves outside the workspace"
    record_result "aux-files" "fail" "$folder" "folder resolves outside the workspace"
    failures=$((failures+1))
    continue
  fi
  for aux in "${AUX_FILES[@]}"; do
    f="$folder/$aux"
    [[ -f "$f" ]] || continue
    f_phys="$(realpath -- "$f" 2>/dev/null || true)"
    if [[ -L "$f" ]]; then
      error "$f: is a symlink"
      record_result "aux-files" "fail" "$f" "symlink"
      failures=$((failures+1))
      continue
    fi
    if [[ -z "$f_phys" || "$f_phys" != "$folder_phys"/* ]]; then
      error "$f: resolves outside the plugin folder"
      record_result "aux-files" "fail" "$f" "resolves outside the plugin folder"
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
