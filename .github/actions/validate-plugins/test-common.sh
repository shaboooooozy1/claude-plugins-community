#!/usr/bin/env bash
# Static unit tests for lib/common.sh — the security predicates
# (has_unsafe_chars, assert_safe_url, assert_safe_sha, assert_safe_path)
# that gate everything downstream. No network, no CLI.

set -uo pipefail
cd "$(dirname "$0")"
export ACTION_PATH="$PWD"

# common.sh sets `set -euo pipefail`; we deliberately want to keep running
# after assert_safe_* calls `die`, so each assertion is invoked in a subshell.
source "$ACTION_PATH/lib/common.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export VALIDATE_TMP="$TMP"
export ALLOWED_HOSTS="github.com gitlab.com"

failures=0; total=0

pass() { echo "  PASS $1"; }
fail() { echo "  FAIL $1 — $2"; failures=$((failures+1)); }

assert_returns_0() {
  total=$((total+1))
  local label="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then pass "$label"; else fail "$label" "expected 0 exit"; fi
}
assert_returns_nonzero() {
  total=$((total+1))
  local label="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then fail "$label" "expected non-zero exit"; else pass "$label"; fi
}

echo "=== common.sh predicate tests ==="

# ---- has_unsafe_chars ------------------------------------------------------
echo "-- has_unsafe_chars"
assert_returns_nonzero "safe alnum"            has_unsafe_chars "abc123"
assert_returns_nonzero "safe with dashes/dots" has_unsafe_chars "a-b.c_d/e"
assert_returns_0       "rejects \$"            has_unsafe_chars 'a$b'
assert_returns_0       "rejects backtick"      has_unsafe_chars 'a`b'
assert_returns_0       "rejects semicolon"     has_unsafe_chars 'a;b'
assert_returns_0       "rejects ampersand"     has_unsafe_chars 'a&b'
assert_returns_0       "rejects pipe"          has_unsafe_chars 'a|b'
assert_returns_0       "rejects parens"        has_unsafe_chars 'a(b)'
assert_returns_0       "rejects less-than"     has_unsafe_chars 'a<b'
assert_returns_0       "rejects redirects"     has_unsafe_chars 'a>b'
assert_returns_0       "rejects whitespace"    has_unsafe_chars 'a b'
assert_returns_0       "rejects tab"           has_unsafe_chars $'a\tb'
assert_returns_0       "rejects newline"       has_unsafe_chars $'a\nb'
assert_returns_0       "rejects carriage rtn"  has_unsafe_chars $'a\rb'
assert_returns_0       "rejects single quote"  has_unsafe_chars "a'b"
assert_returns_0       "rejects double quote"  has_unsafe_chars 'a"b'
assert_returns_0       "rejects backslash"     has_unsafe_chars 'a\b'

# ---- assert_safe_sha -------------------------------------------------------
echo "-- assert_safe_sha"
assert_returns_0       "valid 40-hex lowercase"  assert_safe_sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_returns_0       "valid mixed hex digits"  assert_safe_sha "0123456789abcdef0123456789abcdef01234567"
assert_returns_nonzero "rejects uppercase hex"   assert_safe_sha "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
assert_returns_nonzero "rejects short sha"       assert_safe_sha "aaaa"
assert_returns_nonzero "rejects 41 chars"        assert_safe_sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_returns_nonzero "rejects non-hex char"    assert_safe_sha "gaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_returns_nonzero "rejects empty"           assert_safe_sha ""

# ---- assert_safe_path ------------------------------------------------------
echo "-- assert_safe_path"
assert_returns_0       "relative path"           assert_safe_path "sub/dir"
assert_returns_0       "single dotfile dir"      assert_safe_path "./sub"
assert_returns_nonzero "absolute path"           assert_safe_path "/etc/passwd"
assert_returns_nonzero "parent traversal"        assert_safe_path "../escape"
assert_returns_nonzero "embedded traversal"      assert_safe_path "a/../b"
assert_returns_nonzero "metacharacter in path"   assert_safe_path 'a;rm/b'
assert_returns_nonzero "whitespace in path"      assert_safe_path 'a b'
assert_returns_nonzero "newline in path"         assert_safe_path $'a\nb'

# ---- assert_safe_url -------------------------------------------------------
echo "-- assert_safe_url"
assert_returns_0       "github https"            assert_safe_url "https://github.com/owner/repo"
assert_returns_0       "github subdomain"        assert_safe_url "https://raw.github.com/owner/repo/file"
assert_returns_0       "gitlab https"            assert_safe_url "https://gitlab.com/owner/repo"
assert_returns_nonzero "http (no s)"             assert_safe_url "http://github.com/owner/repo"
assert_returns_nonzero "bare IPv4 (SSRF)"        assert_safe_url "https://169.254.169.254/latest"
assert_returns_nonzero "host:port"               assert_safe_url "https://github.com:8080/x/y"
assert_returns_nonzero "host not in allowlist"   assert_safe_url "https://evil.example/x/y"
assert_returns_nonzero "metachar in url"         assert_safe_url 'https://github.com/x;rm/y'
assert_returns_nonzero "spaces in url"           assert_safe_url "https://github.com/ /y"

# The allowlist matches "host == h" or "host == *.h" — confirm a host that
# is a SUFFIX but not a subdomain (e.g. "evilgithub.com") is rejected.
assert_returns_nonzero "lookalike suffix host"   assert_safe_url "https://evilgithub.com/owner/repo"

# bitbucket.org is in the default ALLOWED_HOSTS but not in the test allowlist above
ALLOWED_HOSTS="github.com gitlab.com bitbucket.org"
assert_returns_0       "bitbucket in allowlist"  assert_safe_url "https://bitbucket.org/owner/repo"
ALLOWED_HOSTS="github.com gitlab.com"

assert_returns_nonzero "rejects bare IPv6 brackets" assert_safe_url "https://[::1]/x"
assert_returns_nonzero "rejects bare IPv6 no brackets" assert_safe_url "https://::1/x"

# ---- assert_safe_string -------------------------------------------------------
echo "-- assert_safe_string"
assert_returns_0       "clean value"             assert_safe_string "label" "clean-value"
assert_returns_nonzero "dirty value"             assert_safe_string "label" 'bad;value'

# ---- record_result ------------------------------------------------------------
echo "-- record_result"
total=$((total+1))
rm -f "$RESULTS_FILE"
record_result "test-step" "pass" "test-subject" "test-detail"
if [[ -f "$RESULTS_FILE" ]] \
   && jq -e '.step=="test-step" and .status=="pass" and .subject=="test-subject" and .detail=="test-detail"' \
      "$RESULTS_FILE" >/dev/null 2>&1; then
  pass "record_result writes correct JSONL"
else
  fail "record_result writes correct JSONL" "JSONL mismatch or missing"
fi

# ---- cli_validate (with stub claude binary) -----------------------------------
echo "-- cli_validate"
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

# Stub that passes cleanly
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "Validation passed"
exit 0
STUB
chmod +x "$STUB_BIN/claude"
OLD_PATH="$PATH"
export PATH="$STUB_BIN:$PATH"

total=$((total+1))
rm -f "$RESULTS_FILE"
if ( cli_validate "t" "subj" "/dev/null" ) >/dev/null 2>&1; then
  if jq -e '.status=="pass"' "$RESULTS_FILE" >/dev/null 2>&1; then
    pass "cli_validate pass records pass"
  else fail "cli_validate pass records pass" "wrong status in results"; fi
else fail "cli_validate pass records pass" "expected exit 0"; fi

# Stub that emits warnings
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "passed with warnings"
echo "⚠ some warning"
exit 0
STUB
chmod +x "$STUB_BIN/claude"

total=$((total+1))
rm -f "$RESULTS_FILE"
if ( cli_validate "t" "subj" "/dev/null" ) >/dev/null 2>&1; then
  if jq -e '.status=="warn"' "$RESULTS_FILE" >/dev/null 2>&1; then
    pass "cli_validate warn records warn"
  else fail "cli_validate warn records warn" "wrong status in results"; fi
else fail "cli_validate warn records warn" "expected exit 0"; fi

# Same warning stub but FAIL_ON_WARNINGS=true
total=$((total+1))
rm -f "$RESULTS_FILE"
if ( FAIL_ON_WARNINGS=true cli_validate "t" "subj" "/dev/null" ) >/dev/null 2>&1; then
  fail "cli_validate warn + FAIL_ON_WARNINGS" "expected non-zero exit"
else
  if jq -e '.status=="fail"' "$RESULTS_FILE" >/dev/null 2>&1; then
    pass "cli_validate warn + FAIL_ON_WARNINGS"
  else fail "cli_validate warn + FAIL_ON_WARNINGS" "wrong status in results"; fi
fi

# Stub that fails
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "Error: schema violation"
exit 1
STUB
chmod +x "$STUB_BIN/claude"

total=$((total+1))
rm -f "$RESULTS_FILE"
if ( cli_validate "t" "subj" "/dev/null" ) >/dev/null 2>&1; then
  fail "cli_validate fail records fail" "expected non-zero exit"
else
  if jq -e '.status=="fail"' "$RESULTS_FILE" >/dev/null 2>&1; then
    pass "cli_validate fail records fail"
  else fail "cli_validate fail records fail" "wrong status in results"; fi
fi

export PATH="$OLD_PATH"

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
