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
assert_returns_0       "rejects redirects"     has_unsafe_chars 'a>b'
assert_returns_0       "rejects whitespace"    has_unsafe_chars 'a b'
assert_returns_0       "rejects tab"           has_unsafe_chars $'a\tb'
assert_returns_0       "rejects newline"       has_unsafe_chars $'a\nb'
assert_returns_0       "rejects carriage rtn"  has_unsafe_chars $'a\rb'
assert_returns_0       "rejects single quote"  has_unsafe_chars "a'b"
assert_returns_0       "rejects double quote"  has_unsafe_chars 'a"b'
assert_returns_0       "rejects backslash"     has_unsafe_chars 'a\b'

# ---- annot_text ------------------------------------------------------------
echo "-- annot_text"
total=$((total+1))
if [[ "$(annot_text $'a\r\nb::error::x')" == "a  b::error::x" ]]; then
  pass "flattens CR/LF"
else fail "flattens CR/LF" "got: $(annot_text $'a\r\nb::error::x')"; fi
total=$((total+1))
long="$(printf 'x%.0s' $(seq 1 600))"
capped="$(annot_text "$long")"
if [[ "${#capped}" -eq 500 ]]; then pass "caps at 500 by default"; else fail "caps at 500 by default" "len=${#capped}"; fi
total=$((total+1))
capped="$(annot_text "$long" 42)"
if [[ "${#capped}" -eq 42 ]]; then pass "caps at explicit length"; else fail "caps at explicit length" "len=${#capped}"; fi

# ---- annotation sinks ------------------------------------------------------
# warn/error sanitise their own message: every caller (die, assert_safe_ref's
# rejection, bump.sh's skip) passes contributor-derived text, and an embedded
# newline would otherwise open a forged workflow command on the next line.
echo "-- warn/error sinks"
total=$((total+1))
sink_out="$(warn "$(printf 'bad\n::error::forged')" 2>&1)"
if [[ "$sink_out" == '::warning::bad ::error::forged' ]]; then
  pass "warn() flattens newlines"
else fail "warn() flattens newlines" "got: $sink_out"; fi
total=$((total+1))
sink_out="$(error "$(printf 'x\r\n::error::forged')" 2>&1)"
if [[ "$sink_out" == '::error::x  ::error::forged' ]]; then
  pass "error() flattens CR/LF"
else fail "error() flattens CR/LF" "got: $sink_out"; fi

# log_untrusted carries plugin/model/CLI output. Flattening newlines is not
# enough for these: a value whose first line is `::error::...` would still be
# read as a workflow command, so every line must be indented.
total=$((total+1))
sink_out="$(log_untrusted "$(printf '::error::forged\nsecond\n::set-output name=x::y')" 2>&1)"
if ! grep -qE '^::' <<<"$sink_out"; then
  pass "log_untrusted() cannot start a line with ::"
else fail "log_untrusted() cannot start a line with ::" "got: $sink_out"; fi
total=$((total+1))
if [[ "$(log_untrusted "plain" 2>&1)" == '  | plain' ]]; then
  pass "log_untrusted() keeps content readable"
else fail "log_untrusted() keeps content readable" "got: $(log_untrusted "plain" 2>&1)"; fi

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

# ---- assert_safe_ref -------------------------------------------------------
echo "-- assert_safe_ref"
assert_returns_0       "remote branch"           assert_safe_ref "origin/main"
assert_returns_0       "HEAD"                    assert_safe_ref "HEAD"
assert_returns_0       "rev expression"          assert_safe_ref "HEAD~1"
assert_returns_0       "40-hex sha"              assert_safe_ref "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_returns_nonzero "long option"             assert_safe_ref "--upload-pack=x"
assert_returns_nonzero "short option"            assert_safe_ref "-x"
assert_returns_nonzero "whitespace"              assert_safe_ref "a b"
assert_returns_nonzero "empty"                   assert_safe_ref ""
assert_returns_nonzero "metacharacter"           assert_safe_ref 'main;rm'

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

# ---- url_safe_or_reason ----------------------------------------------------
# The non-fatal form scan.sh and bump.sh call. Success means SAFE, so that a
# failed call (an older common.sh where it is undefined, exiting 127) lands on
# the reject side instead of waving the URL through. A bare IP must stay
# rejected even when an operator puts it in ALLOWED_HOSTS: that is the SSRF
# contract, and what kept the actions' inline copies from agreeing before.
echo "-- url_safe_or_reason"
assert_returns_0       "safe url returns 0"      url_safe_or_reason "https://github.com/owner/repo"
assert_returns_nonzero "bare IP rejected"        url_safe_or_reason "https://169.254.169.254/latest"
assert_returns_nonzero "host:port rejected"      url_safe_or_reason "https://github.com:8080/x/y"
assert_returns_nonzero "http rejected"           url_safe_or_reason "http://github.com/owner/repo"
assert_returns_nonzero "host off allowlist"      url_safe_or_reason "https://evil.example/x/y"
total=$((total+1))
if ( ALLOWED_HOSTS="169.254.169.254 github.com" url_safe_or_reason "https://169.254.169.254/latest" ) >/dev/null; then
  fail "bare IP rejected even when allowlisted" "expected non-zero"
else pass "bare IP rejected even when allowlisted"; fi
total=$((total+1))
if ( ALLOWED_HOSTS="" url_safe_or_reason "https://github.com/owner/repo" ) >/dev/null; then
  fail "empty ALLOWED_HOSTS fails closed" "expected non-zero"
else pass "empty ALLOWED_HOSTS fails closed"; fi

# The gate must fail CLOSED when the helper itself is missing: a caller doing
# `if ! reason="$(url_safe_or_reason ...)"` sees 127 and must treat it as a
# rejection, which is why success cannot be the "unsafe" side.
total=$((total+1))
if ( unset -f url_safe_or_reason; url_safe_or_reason "https://github.com/owner/repo" ) >/dev/null 2>&1; then
  fail "undefined helper rejects" "expected non-zero from a missing function"
else pass "undefined helper rejects"; fi

# ---- path_contained_or_reason ----------------------------------------------
# Steps 11, 40 and 41 all decide what to read from a contributor-controlled
# path, and each had its own copy of this before they disagreed. Success means
# contained, so a failure of the check cannot be read as containment.
echo "-- path_contained_or_reason"
PC="$TMP/pc"; mkdir -p "$PC/root/inner" "$PC/outside/deep"
: > "$PC/root/inner/file"; : > "$PC/outside/deep/file"
ln -s "$PC/outside" "$PC/root/escape"
ln -s "$PC/root/inner/file" "$PC/outside/back-in"
assert_returns_0       "self is contained"        path_contained_or_reason "$PC/root" "$PC/root"
assert_returns_0       "descendant contained"     path_contained_or_reason "$PC/root/inner/file" "$PC/root"
assert_returns_nonzero "sibling rejected"         path_contained_or_reason "$PC/outside/deep/file" "$PC/root"
assert_returns_nonzero "symlink out rejected"     path_contained_or_reason "$PC/root/escape" "$PC/root"
assert_returns_nonzero "via symlinked ancestor"   path_contained_or_reason "$PC/root/escape/deep/file" "$PC/root"
assert_returns_nonzero "missing target rejected"  path_contained_or_reason "$PC/root/nope" "$PC/root"
assert_returns_nonzero "missing root rejected"    path_contained_or_reason "$PC/root" "$PC/no-such-root"
# A symlink pointing back INSIDE the root is contained — that is what makes
# checking the manifest alone insufficient in step 11, where the source root
# must be checked too.
assert_returns_0       "symlink back in is contained" path_contained_or_reason "$PC/outside/back-in" "$PC/root"
total=$((total+1))
if why="$(path_contained_or_reason "$PC/outside/deep/file" "$PC/root")"; then
  fail "reports a reason" "expected non-zero"
elif [[ -n "$why" ]]; then pass "reports a reason"
else fail "reports a reason" "empty reason"; fi

# ---- assert_helpers_defined ------------------------------------------------
echo "-- assert_helpers_defined"
total=$((total+1))
if ( assert_helpers_defined ) >/dev/null 2>&1; then
  pass "passes with a complete common.sh"
else fail "passes with a complete common.sh" "expected exit 0"; fi
total=$((total+1))
if ( unset -f url_safe_or_reason; assert_helpers_defined ) >/dev/null 2>&1; then
  fail "catches a missing helper" "expected exit 1"
else pass "catches a missing helper"; fi

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
