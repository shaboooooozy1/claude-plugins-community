#!/usr/bin/env bash
# Static test suite for 40-validate-cli-local.sh. No network — stubs `claude`
# to exercise logic branches offline.

set -euo pipefail
cd "$(dirname "$0")"
export ACTION_PATH="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0; total=0

pass() { echo "  PASS $1"; }
fail() { echo "  FAIL $1 — $2"; failures=$((failures+1)); }

setup() {
  local label="$1"
  local vtmp="$TMP/local-$label"
  rm -rf "$vtmp"; mkdir -p "$vtmp"
  local stubdir="$TMP/stubs-local-$label"
  mkdir -p "$stubdir"
  printf '%s' "$vtmp"
}

run_local() {
  local vtmp="$1" stubdir="$2"
  ( cd "$TMP"
    export PATH="$stubdir:$PATH"
    export VALIDATE_TMP="$vtmp"
    bash "$ACTION_PATH/scripts/40-validate-cli-local.sh" 2>&1
  )
}

echo "=== cli-local tests ==="

# ---- no changed folders = skip ------------------------------------------------
total=$((total+1))
vtmp="$(setup no-folders)"
stubdir="$TMP/stubs-local-no-folders"
echo '{"entries":[],"external":[],"folders":[]}' > "$vtmp/changes.json"
set +e
out="$(run_local "$vtmp" "$stubdir" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -q "skip" <<<"$out"; then
  pass "no changed folders = skip"
else fail "no changed folders = skip" "exit=$rc"; fi

# ---- valid plugin folder passes -----------------------------------------------
total=$((total+1))
vtmp="$(setup valid)"
stubdir="$TMP/stubs-local-valid"
mkdir -p "$TMP/plugin-ok/.claude-plugin"
echo '{"name":"ok"}' > "$TMP/plugin-ok/.claude-plugin/plugin.json"
echo '{"entries":[],"external":[],"folders":["plugin-ok"]}' > "$vtmp/changes.json"
cat > "$stubdir/claude" <<'STUB'
#!/usr/bin/env bash
echo "Validation passed"
exit 0
STUB
chmod +x "$stubdir/claude"
set +e
out="$(run_local "$vtmp" "$stubdir" 2>&1)"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "valid plugin folder passes"
else fail "valid plugin folder passes" "exit=$rc, out=$out"; fi

# ---- missing plugin.json = fail -----------------------------------------------
total=$((total+1))
vtmp="$(setup missing-pj)"
stubdir="$TMP/stubs-local-missing-pj"
mkdir -p "$TMP/plugin-nopj"
echo '{"entries":[],"external":[],"folders":["plugin-nopj"]}' > "$vtmp/changes.json"
cat > "$stubdir/claude" <<'STUB'
#!/usr/bin/env bash
echo "Validation passed"
exit 0
STUB
chmod +x "$stubdir/claude"
set +e
out="$(run_local "$vtmp" "$stubdir" 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]] && grep -q "missing" <<<"$out"; then
  pass "missing plugin.json = fail"
else fail "missing plugin.json = fail" "exit=$rc, out=$out"; fi

# ---- claude validate fails = recorded fail -------------------------------------
total=$((total+1))
vtmp="$(setup claude-fail)"
stubdir="$TMP/stubs-local-claude-fail"
mkdir -p "$TMP/plugin-cfail/.claude-plugin"
echo '{"name":"cfail"}' > "$TMP/plugin-cfail/.claude-plugin/plugin.json"
echo '{"entries":[],"external":[],"folders":["plugin-cfail"]}' > "$vtmp/changes.json"
cat > "$stubdir/claude" <<'STUB'
#!/usr/bin/env bash
echo "Error: schema violation"
exit 1
STUB
chmod +x "$stubdir/claude"
set +e
out="$(run_local "$vtmp" "$stubdir" 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  pass "claude validate fails = recorded fail"
else fail "claude validate fails = recorded fail" "exit=$rc"; fi

# ---- claude warns + FAIL_ON_WARNINGS = fail ------------------------------------
total=$((total+1))
vtmp="$(setup warn-fow)"
stubdir="$TMP/stubs-local-warn-fow"
mkdir -p "$TMP/plugin-wfow/.claude-plugin"
echo '{"name":"wfow"}' > "$TMP/plugin-wfow/.claude-plugin/plugin.json"
echo '{"entries":[],"external":[],"folders":["plugin-wfow"]}' > "$vtmp/changes.json"
cat > "$stubdir/claude" <<'STUB'
#!/usr/bin/env bash
echo "passed with warnings"
echo "⚠ some warning"
exit 0
STUB
chmod +x "$stubdir/claude"
set +e
out="$(cd "$TMP" && PATH="$stubdir:$PATH" VALIDATE_TMP="$vtmp" ACTION_PATH="$ACTION_PATH" \
  FAIL_ON_WARNINGS=true bash "$ACTION_PATH/scripts/40-validate-cli-local.sh" 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  pass "claude warns + FAIL_ON_WARNINGS = fail"
else fail "claude warns + FAIL_ON_WARNINGS = fail" "exit=$rc"; fi

# ---- unsafe path in changes.json = die ----------------------------------------
total=$((total+1))
vtmp="$(setup unsafe-path)"
stubdir="$TMP/stubs-local-unsafe-path"
echo '{"entries":[],"external":[],"folders":["../escape"]}' > "$vtmp/changes.json"
cat > "$stubdir/claude" <<'STUB'
#!/usr/bin/env bash
echo "Validation passed"
exit 0
STUB
chmod +x "$stubdir/claude"
set +e
out="$(run_local "$vtmp" "$stubdir" 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]] && grep -qi "absolute\|unsafe\|\.\." <<<"$out"; then
  pass "unsafe path in changes.json = die"
else fail "unsafe path in changes.json = die" "exit=$rc, out=$out"; fi

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
