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
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
case "${CLAUDE_STUB_MODE:-pass}" in
  pass)
    printf 'validated %s\n' "${3:-}"
    exit 0
    ;;
  warn)
    printf '⚠ stub warning for %s\n' "${3:-}"
    exit 0
    ;;
  fail)
    printf 'Error: stub failure for %s\n' "${3:-}" >&2
    exit 1
    ;;
  *)
    printf 'unknown CLAUDE_STUB_MODE=%s\n' "${CLAUDE_STUB_MODE:-}" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP/bin/claude"

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
assert_last_result() {
  total=$((total+1))
  local label="$1" step="$2" status="$3" subject="$4"
  if jq -s -e \
      --arg step "$step" \
      --arg status "$status" \
      --arg subject "$subject" \
      'length > 0 and .[-1].step == $step and .[-1].status == $status and .[-1].subject == $subject' \
      "$RESULTS_FILE" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label" "unexpected last result"
  fi
}
reset_results() { : > "$RESULTS_FILE"; }

run_cli_validate() {
  local mode="$1" fail_on="$2"
  reset_results
  CLAUDE_STUB_MODE="$mode" FAIL_ON_WARNINGS="$fail_on" \
    cli_validate "cli-step" "stub-subject" "$TMP/plugin.json" >/dev/null 2>&1
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
assert_returns_0       "rejects redirects"     has_unsafe_chars 'a>b'
assert_returns_0       "rejects whitespace"    has_unsafe_chars 'a b'
assert_returns_0       "rejects tab"           has_unsafe_chars $'a\tb'
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

# ---- record_result ----------------------------------------------------------
echo "-- record_result"
reset_results
record_result "unit-step" "pass" "unit-subject" "unit-detail"
assert_last_result "records JSONL result rows" "unit-step" "pass" "unit-subject"

# ---- cli_validate -----------------------------------------------------------
echo "-- cli_validate"
echo '{}' > "$TMP/plugin.json"

total=$((total+1))
if run_cli_validate pass false; then
  pass "pass result exits 0"
else
  fail "pass result exits 0" "expected 0 exit"
fi
assert_last_result "pass result records pass" "cli-step" "pass" "stub-subject"

total=$((total+1))
if run_cli_validate warn false; then
  pass "warning result exits 0 by default"
else
  fail "warning result exits 0 by default" "expected 0 exit"
fi
assert_last_result "warning result records warn" "cli-step" "warn" "stub-subject"

total=$((total+1))
if run_cli_validate warn true; then
  fail "fail-on-warnings returns non-zero" "expected non-zero exit"
else
  pass "fail-on-warnings returns non-zero"
fi
assert_last_result "fail-on-warnings records fail" "cli-step" "fail" "stub-subject"

total=$((total+1))
if run_cli_validate fail false; then
  fail "validator failure returns non-zero" "expected non-zero exit"
else
  pass "validator failure returns non-zero"
fi
assert_last_result "validator failure records fail" "cli-step" "fail" "stub-subject"

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
