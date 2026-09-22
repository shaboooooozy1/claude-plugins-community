#!/usr/bin/env bash
# For each CHANGED external entry: clone at the pinned SHA into an isolated
# temp dir and run `claude plugin validate` against it.
#
# Security: url/sha/path are re-validated here with assert_safe_* before any
# shell use, all interpolations are double-quoted, and `--` end-of-options
# markers are used on every git invocation. Nothing from the cloned repo is
# ever executed; `claude plugin validate` is a static check.

source "$ACTION_PATH/lib/common.sh"

# Marks this step done only on a zero exit, so an abort part-way through
# (a die, or set -e on an unexpected error) leaves it begun-but-unfinished
# and 90-report.sh fails the run rather than aggregating to PASS.
STEP_ID=30-cli-external
step_begin "$STEP_ID"
trap 'rc=$?; if [[ $rc -eq 0 ]]; then step_done "$STEP_ID"; fi' EXIT

: "${VALIDATE_TMP:?}"
CHANGES="$VALIDATE_TMP/changes.json"
MP="$VALIDATE_TMP/marketplace.json"
TIMEOUT_SECS="${EXTERNAL_TIMEOUT_SECS:-120}"

group_start "CLI: claude plugin validate (external plugins)"

if [[ "${VALIDATE_ALL_EXTERNAL:-false}" == "true" ]]; then
  log "validate-all-external is set: scanning every external entry"
  jq -c '[.plugins[] | select(.source|type=="object") | {name, source}]' -- "$MP" \
    > "$VALIDATE_TMP/external-targets.json"
else
  jq -c '.external' -- "$CHANGES" > "$VALIDATE_TMP/external-targets.json"
fi

count="$(jq 'length' -- "$VALIDATE_TMP/external-targets.json")"
if [[ "$count" -eq 0 ]]; then
  log "No external entries to validate; skipping."
  record_result "cli-external" "skip" "summary" "no external entries"
  group_end
  exit 0
fi

failures=0
idx=0
workroot="$(mktemp -d)"
# Re-arms rather than replaces: a bare `trap ... EXIT` here would drop the
# step-completion handler installed above, and this step would then never mark
# itself done even on a clean run.
trap 'rc=$?; rm -rf "$workroot"; if [[ $rc -eq 0 ]]; then step_done "$STEP_ID"; fi' EXIT

while IFS= read -r ext; do
  idx=$((idx+1))
  name="$(jq -r '.name' <<<"$ext")"
  kind="$(jq -r '.source.source // "unknown"' <<<"$ext")"
  url="$(jq -r '.source.url // .source.repo // empty' <<<"$ext")"
  sha="$(jq -r '.source.sha // empty' <<<"$ext")"
  subdir="$(jq -r '.source.path // ""' <<<"$ext")"

  # I11 validates the name, but a consumer may demote it through
  # WARN_INVARIANTS, so it can still reach here unchecked. Flattening plus the
  # constant prefix is what keeps this line from forging a workflow command.
  log "---- $(annot_text "$name" 100) ($(annot_text "$kind" 40)) ----"

  if [[ -z "$url" ]]; then
    error "$name: no url/repo field on source"
    record_result "cli-external" "fail" "$name" "no url/repo on source"
    failures=$((failures+1))
    continue
  fi
  if [[ -z "$sha" ]]; then
    error "$name: no sha pin (cannot safely clone)"
    record_result "cli-external" "fail" "$name" "no sha pin"
    failures=$((failures+1))
    continue
  fi

  # Expand owner/repo shorthand (and {source:'github', repo}) to a full https URL.
  if [[ "$url" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    url="https://github.com/$url"
  fi

  # Defense-in-depth: re-check safety even though schema + I4/I5/I9 already ran.
  #
  # These reject the entry and carry on rather than calling the asserting
  # wrappers, which `die`. Every other failure mode in this loop records a
  # result and continues, and aborting here loses the rest of the sweep: with
  # two entries where the first is off-allowlist, the second was never cloned
  # and results.jsonl held one `fatal`/`die` row naming no plugin. Both shapes
  # reach here un-rejected by the invariants — I4 checks URL syntax but not the
  # host, and I5 (malformed sha) is warn-by-default — and validate-all-external
  # sweeps 1714 entries, so one of them would end the run at the first.
  # common.sh says as much: url_safe_or_reason exists so callers can skip one
  # target rather than abort. scan.sh and bump.sh already use it.
  if ! url_reason="$(url_safe_or_reason "$url")"; then
    error "$name: url rejected (${url_reason:-unvalidated})"
    record_result "cli-external" "fail" "$name" "url rejected: ${url_reason:-unvalidated}"
    failures=$((failures+1))
    continue
  fi
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    error "$name: sha is not a 40-char lowercase hex string"
    record_result "cli-external" "fail" "$name" "sha is not 40-char lowercase hex"
    failures=$((failures+1))
    continue
  fi
  if [[ -n "$subdir" ]] && { has_unsafe_chars "$subdir" || [[ "$subdir" == /* ]] || [[ "$subdir" == *".."* ]]; }; then
    error "$name: source.path is absolute, contains '..', or has unsafe characters"
    record_result "cli-external" "fail" "$name" "unsafe source.path"
    failures=$((failures+1))
    continue
  fi

  ref="$url@${sha:0:8}${subdir:+ ($subdir)}"
  dest="$workroot/ext-$idx"
  mkdir -p -- "$dest"

  if ! timeout "$TIMEOUT_SECS" git clone --quiet --depth 1 -- "$url" "$dest" 2>&1; then
    error "$name: git clone failed or timed out — $ref"
    record_result "cli-external" "fail" "$name" "git clone failed — $ref"
    failures=$((failures+1))
    continue
  fi

  if ! git -C "$dest" fetch --quiet --depth 1 origin -- "$sha" 2>&1; then
    error "$name: git fetch of pinned sha failed — $ref"
    record_result "cli-external" "fail" "$name" "git fetch of pinned sha failed — $ref"
    failures=$((failures+1))
    continue
  fi

  if ! git -C "$dest" -c advice.detachedHead=false checkout --quiet "$sha" -- 2>&1; then
    error "$name: git checkout of pinned sha failed — $ref"
    record_result "cli-external" "fail" "$name" "git checkout of pinned sha failed — $ref"
    failures=$((failures+1))
    continue
  fi

  target="$dest"
  if [[ -n "$subdir" ]]; then
    target="$dest/$subdir"
    if [[ ! -d "$target" ]]; then
      error "$name: subdir '$subdir' not found — $ref"
      record_result "cli-external" "fail" "$name" "subdir '$subdir' not found — $ref"
      failures=$((failures+1))
      continue
    fi
  fi

  manifest="$target/.claude-plugin/plugin.json"
  if [[ ! -f "$manifest" ]]; then
    if [[ -f "$target/plugin.json" ]]; then
      manifest="$target/plugin.json"
    else
      error "$name: no plugin manifest (.claude-plugin/plugin.json or plugin.json) — $ref"
      record_result "cli-external" "fail" "$name" "no plugin manifest — $ref"
      failures=$((failures+1))
      continue
    fi
  fi

  # BOTH the plugin root and the manifest, via the shared helper. Checking the
  # manifest alone is not enough: a cloned `subdir` can be a symlink out of the
  # clone whose `.claude-plugin` symlinks back in, so realpath(manifest) lands
  # inside while the plugin root the validator is handed traverses outside.
  # Reproduced with dest/sub -> outside and outside/.claude-plugin -> dest/real,
  # which the manifest-only test accepted. Same gap step 11 had; one helper now.
  if [[ -L "$manifest" ]]; then
    error "$name: plugin manifest is a symlink — $ref"
    record_result "cli-external" "fail" "$name" "manifest is a symlink — $ref"
    failures=$((failures+1))
    continue
  fi
  if ! why="$(path_contained_or_reason "$target" "$dest")" \
     || ! why="$(path_contained_or_reason "$manifest" "$dest")"; then
    error "$name: ${why:-not contained in the clone} — $ref"
    record_result "cli-external" "fail" "$name" "${why:-not contained in the clone} — $ref"
    failures=$((failures+1))
    continue
  fi

  if out="$(timeout "$TIMEOUT_SECS" claude plugin validate "$manifest" 2>&1)"; then
    log "  ✓ $(annot_text "$name" 100) OK — $ref"
    record_result "cli-external" "pass" "$name" ""
  else
    # || true: grep exits 1 when the validator output carries none of these
    # markers, and under `set -euo pipefail` that would abort the whole step
    # instead of failing this one plugin.
    detail="$(grep -E '❯|Error:' <<<"$out" | head -1 | sed -E 's/^[[:space:]]+//' || true)"
    error "$name: claude plugin validate failed — $ref — ${detail:-see log}"
    log_untrusted "$out"
    record_result "cli-external" "fail" "$name" "$out"
    failures=$((failures+1))
  fi

  rm -rf -- "$dest"
done < <(jq -c '.[]' -- "$VALIDATE_TMP/external-targets.json")

if (( failures > 0 )); then
  die "$failures external plugin(s) failed validation"
fi

log "All $count changed external plugin(s) validated OK"
group_end
