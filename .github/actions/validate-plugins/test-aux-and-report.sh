#!/usr/bin/env bash
# Static test suite for 41-validate-aux-files.sh and 90-report.sh.
# No API key, no network — pure bash/jq against synthetic fixtures.

set -euo pipefail
cd "$(dirname "$0")"
export ACTION_PATH="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0; total=0

pass() { echo "  PASS $1"; }
fail() { echo "  FAIL $1 — $2"; failures=$((failures+1)); }

echo "=== aux-files and report tests ==="

# ============================================================================
# 41-validate-aux-files.sh
# ============================================================================
echo "-- 41-validate-aux-files.sh"

# The aux-files script calls assert_safe_path on each folder, which rejects
# absolute paths. Tests must use relative paths, so we run from inside $TMP
# and create folder structures relative to it.

run_aux() {
  local label="$1" vtmp="$TMP/aux-$label"
  rm -rf "$vtmp"; mkdir -p "$vtmp"
  ( cd "$TMP"
    export VALIDATE_TMP="$vtmp"
    export ACTION_PATH="$OLDPWD"
    bash "$ACTION_PATH/scripts/41-validate-aux-files.sh" 2>&1
  )
}

# ---- no changed folders = skip ------------------------------------------------
total=$((total+1))
vtmp="$TMP/aux-nofolder"; mkdir -p "$vtmp"
echo '{"entries":[],"external":[],"folders":[]}' > "$vtmp/changes.json"
set +e
out="$(cd "$TMP" && VALIDATE_TMP="$vtmp" ACTION_PATH="$ACTION_PATH" \
  bash "$ACTION_PATH/scripts/41-validate-aux-files.sh" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "aux: no folders = skip"
else fail "aux: no folders = skip" "exit $rc"; fi

# ---- valid .mcp.json passes ---------------------------------------------------
total=$((total+1))
mkdir -p "$TMP/plugin-valid/.claude-plugin"
echo '{"name":"valid"}' > "$TMP/plugin-valid/.claude-plugin/plugin.json"
echo '{"servers":[]}' > "$TMP/plugin-valid/.mcp.json"
vtmp="$TMP/aux-valid-mcp"; mkdir -p "$vtmp"
echo '{"entries":[],"external":[],"folders":["plugin-valid"]}' > "$vtmp/changes.json"
set +e
out="$(cd "$TMP" && VALIDATE_TMP="$vtmp" ACTION_PATH="$ACTION_PATH" \
  bash "$ACTION_PATH/scripts/41-validate-aux-files.sh" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -q "parses" <<<"$out"; then
  pass "aux: valid .mcp.json passes"
else fail "aux: valid .mcp.json passes" "exit $rc, out=$out"; fi

# ---- invalid .mcp.json fails --------------------------------------------------
total=$((total+1))
mkdir -p "$TMP/plugin-bad-mcp/.claude-plugin"
echo '{"name":"bad"}' > "$TMP/plugin-bad-mcp/.claude-plugin/plugin.json"
echo '{broken json' > "$TMP/plugin-bad-mcp/.mcp.json"
vtmp="$TMP/aux-bad-mcp"; mkdir -p "$vtmp"
echo '{"entries":[],"external":[],"folders":["plugin-bad-mcp"]}' > "$vtmp/changes.json"
set +e
out="$(cd "$TMP" && VALIDATE_TMP="$vtmp" ACTION_PATH="$ACTION_PATH" \
  bash "$ACTION_PATH/scripts/41-validate-aux-files.sh" 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  pass "aux: invalid .mcp.json fails"
else fail "aux: invalid .mcp.json fails" "expected non-zero exit"; fi

# ---- valid hooks/hooks.json passes --------------------------------------------
total=$((total+1))
mkdir -p "$TMP/plugin-hooks/.claude-plugin" "$TMP/plugin-hooks/hooks"
echo '{"name":"hooks"}' > "$TMP/plugin-hooks/.claude-plugin/plugin.json"
echo '{"hooks":[]}' > "$TMP/plugin-hooks/hooks/hooks.json"
vtmp="$TMP/aux-hooks"; mkdir -p "$vtmp"
echo '{"entries":[],"external":[],"folders":["plugin-hooks"]}' > "$vtmp/changes.json"
set +e
out="$(cd "$TMP" && VALIDATE_TMP="$vtmp" ACTION_PATH="$ACTION_PATH" \
  bash "$ACTION_PATH/scripts/41-validate-aux-files.sh" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -q "parses" <<<"$out"; then
  pass "aux: valid hooks/hooks.json passes"
else fail "aux: valid hooks/hooks.json passes" "exit $rc"; fi

# ---- missing aux files = no check (no fail) ------------------------------------
total=$((total+1))
mkdir -p "$TMP/plugin-noaux/.claude-plugin"
echo '{"name":"noaux"}' > "$TMP/plugin-noaux/.claude-plugin/plugin.json"
vtmp="$TMP/aux-noaux"; mkdir -p "$vtmp"
echo '{"entries":[],"external":[],"folders":["plugin-noaux"]}' > "$vtmp/changes.json"
set +e
out="$(cd "$TMP" && VALIDATE_TMP="$vtmp" ACTION_PATH="$ACTION_PATH" \
  bash "$ACTION_PATH/scripts/41-validate-aux-files.sh" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "aux: missing aux files = no fail"
else fail "aux: missing aux files = no fail" "exit $rc"; fi

# ---- multiple folders, one bad = 1 failure ------------------------------------
total=$((total+1))
mkdir -p "$TMP/plugin-multi-good/.claude-plugin"
echo '{"name":"good"}' > "$TMP/plugin-multi-good/.claude-plugin/plugin.json"
echo '{"servers":[]}' > "$TMP/plugin-multi-good/.mcp.json"
mkdir -p "$TMP/plugin-multi-bad/.claude-plugin"
echo '{"name":"bad"}' > "$TMP/plugin-multi-bad/.claude-plugin/plugin.json"
echo '{broken' > "$TMP/plugin-multi-bad/.mcp.json"
vtmp="$TMP/aux-multi"; mkdir -p "$vtmp"
echo '{"entries":[],"external":[],"folders":["plugin-multi-good","plugin-multi-bad"]}' > "$vtmp/changes.json"
set +e
out="$(cd "$TMP" && VALIDATE_TMP="$vtmp" ACTION_PATH="$ACTION_PATH" \
  bash "$ACTION_PATH/scripts/41-validate-aux-files.sh" 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  pass "aux: multiple folders, one bad = failure"
else fail "aux: multiple folders, one bad = failure" "expected non-zero exit"; fi

# ============================================================================
# 90-report.sh
# ============================================================================
echo "-- 90-report.sh"

run_report() {
  local vtmp="$TMP/rpt-$1"
  rm -rf "$vtmp"; mkdir -p "$vtmp"
  export VALIDATE_TMP="$vtmp"
  export GITHUB_OUTPUT="$vtmp/github-output"
  export GITHUB_STEP_SUMMARY="$vtmp/summary.md"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
}

# ---- all pass = exit 0, result=pass ------------------------------------------
total=$((total+1))
run_report all-pass
jq -cn '{step:"s1",status:"pass",subject:"a",detail:""}' > "$VALIDATE_TMP/results.jsonl"
jq -cn '{step:"s2",status:"pass",subject:"b",detail:""}' >> "$VALIDATE_TMP/results.jsonl"
set +e
bash "$ACTION_PATH/scripts/90-report.sh" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -q "result=pass" "$VALIDATE_TMP/github-output"; then
  pass "report: all pass = exit 0, result=pass"
else fail "report: all pass = exit 0, result=pass" "exit=$rc, output=$(cat "$VALIDATE_TMP/github-output" 2>/dev/null)"; fi

# ---- one fail = exit 1, result=fail ------------------------------------------
total=$((total+1))
run_report one-fail
jq -cn '{step:"s1",status:"pass",subject:"a",detail:""}' > "$VALIDATE_TMP/results.jsonl"
jq -cn '{step:"s2",status:"fail",subject:"b",detail:"oops"}' >> "$VALIDATE_TMP/results.jsonl"
set +e
bash "$ACTION_PATH/scripts/90-report.sh" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]] && grep -q "result=fail" "$VALIDATE_TMP/github-output"; then
  pass "report: one fail = exit 1, result=fail"
else fail "report: one fail = exit 1, result=fail" "exit=$rc"; fi

# ---- empty results = exit 0 ---------------------------------------------------
total=$((total+1))
run_report empty
: > "$VALIDATE_TMP/results.jsonl"
set +e
bash "$ACTION_PATH/scripts/90-report.sh" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "report: empty results = exit 0"
else fail "report: empty results = exit 0" "exit=$rc"; fi

# ---- summary contains markdown table ------------------------------------------
total=$((total+1))
run_report table
jq -cn '{step:"s1",status:"pass",subject:"a",detail:""}' > "$VALIDATE_TMP/results.jsonl"
set +e
bash "$ACTION_PATH/scripts/90-report.sh" >/dev/null 2>&1
rc=$?
set -e
if grep -q "| Step | Subject | Status | Detail |" "$VALIDATE_TMP/summary.md"; then
  pass "report: summary contains markdown table"
else fail "report: summary contains markdown table" "no table in summary"; fi

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
