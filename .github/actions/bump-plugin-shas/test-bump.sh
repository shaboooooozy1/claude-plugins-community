#!/usr/bin/env bash
# Static test suite for bump.sh's skip/freeze/exempt logic and the freeze-shas
# reconciliation warning. No API key, no network, no gh — every fixture entry
# resolves to a skip (frozen, exempt, or non-allowlisted host), so bump.sh
# exits at "Nothing to bump" before any git ls-remote / clone / claude / gh
# call. Pure bash/jq against synthetic marketplace.json fixtures. Run locally
# or in CI on every PR touching bump-plugin-shas/.
#
# Fixtures use heredocs (not quoted args) so the suite runs identically on
# macOS bash 3.2 and Linux bash 5.x.

set -euo pipefail
cd "$(dirname "$0")"
export ACTION_PATH="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0; total=0

# A stub validate-lib providing exactly the helpers bump.sh sources. Faithful
# to validate-plugins/lib/common.sh for the functions the skip paths touch.
cat > "$TMP/lib.sh" <<'EOF'
log()   { printf '%s\n' "$*"; }
info()  { printf '::notice::%s\n' "$*"; }
warn()  { printf '::warning::%s\n' "$*"; }
error() { printf '::error::%s\n' "$*"; }
die()   { error "$*"; exit 1; }
group_start() { printf '::group::%s\n' "$*"; }
group_end()   { printf '::endgroup::\n'; }
has_unsafe_chars() {
  case "$1" in
    *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'('*|*')'*|*'<'*|*'>'*|*' '*|*'	'*|*'"'*|*"'"*|*'\'*) return 0 ;;
  esac
  return 1
}
EOF

mk() { local f="$TMP/$1.json"; cat > "$f"; printf '%s' "$f"; }

# Run the real bump.sh against fixture $1, with FREEZE_SHAS_FIXTURE /
# SHA_EXEMPT_FIXTURE supplying the two lists. Captures combined output in OUT,
# the parsed `skipped` output array in SKIPPED_JSON, and the exit code in RC.
# bump.sh mutates MARKETPLACE_PATH in place, so it operates on a copy ($work)
# and the caller compares $work against $1 to assert "pin held".
work=""
run_bump() {
  work="$TMP/work.json"; cp "$1" "$work"
  export VALIDATE_LIB="$TMP/lib.sh" MARKETPLACE_PATH="$work" \
    MAX_BUMPS=20 ALLOWED_HOSTS="github.com gitlab.com bitbucket.org" \
    PR_BRANCH="bump/plugin-shas" BASE_BRANCH="main" GH_TOKEN="dummy" \
    SHA_EXEMPT="${SHA_EXEMPT_FIXTURE:-}" FREEZE_SHAS="${FREEZE_SHAS_FIXTURE:-}" \
    ONLY="${ONLY_FIXTURE:-}" \
    GITHUB_OUTPUT="$TMP/out.txt" GITHUB_STEP_SUMMARY="$TMP/sum.md"
  : > "$TMP/out.txt"; : > "$TMP/sum.md"
  set +e
  OUT="$(bash "$ACTION_PATH/scripts/bump.sh" 2>&1)"
  RC=$?
  set -e
  SKIPPED_JSON="$(sed -n 's/^skipped=//p' "$TMP/out.txt")"
  [[ -n "$SKIPPED_JSON" ]] || SKIPPED_JSON='[]'
}

# assert_reason NAME EXPECTED_SUBSTR LABEL — entry NAME was skipped with a
# reason containing EXPECTED_SUBSTR.
assert_reason() {
  total=$((total+1))
  local got; got="$(jq -r --arg n "$1" '.[]|select(.name==$n)|.reason' <<<"$SKIPPED_JSON")"
  if [[ "$got" == *"$2"* ]]; then echo "  PASS $3"
  else echo "  FAIL $3 — '$1' reason='$got' expected to contain '$2'"; failures=$((failures+1)); fi
}

# assert_warn SUBSTR LABEL — a workflow ::warning containing SUBSTR was emitted.
assert_warn() {
  total=$((total+1))
  if grep -qF "$1" <<<"$OUT"; then echo "  PASS $2"
  else echo "  FAIL $2 — no warning containing '$1'"; failures=$((failures+1)); fi
}

# assert_no_warn SUBSTR LABEL — no output line contains SUBSTR.
assert_no_warn() {
  total=$((total+1))
  if grep -qF "$1" <<<"$OUT"; then echo "  FAIL $2 — unexpected '$1' in output"; failures=$((failures+1))
  else echo "  PASS $2"; fi
}

# assert_pin_held FIXTURE LABEL — bump.sh left the marketplace byte-identical.
assert_pin_held() {
  total=$((total+1))
  if diff -q "$1" "$work" >/dev/null; then echo "  PASS $2"
  else echo "  FAIL $2 — marketplace.json changed (pin advanced)"; failures=$((failures+1)); fi
}

# assert_rc EXPECTED LABEL
assert_rc() {
  total=$((total+1))
  if [[ "$RC" == "$1" ]]; then echo "  PASS $2"
  else echo "  FAIL $2 — exit $RC, expected $1"; failures=$((failures+1)); fi
}

# assert_not_skipped NAME LABEL — entry NAME does NOT appear in skipped[] (it was
# plain-continued by the `only` guard, not recorded as a skip).
assert_not_skipped() {
  total=$((total+1))
  local got; got="$(jq -r --arg n "$1" '[.[]|select(.name==$n)]|length' <<<"$SKIPPED_JSON")"
  if [[ "$got" == "0" ]]; then echo "  PASS $2"
  else echo "  FAIL $2 — '$1' unexpectedly recorded in skipped[]"; failures=$((failures+1)); fi
}

# assert_skipped_count N LABEL — exactly N entries in skipped[].
assert_skipped_count() {
  total=$((total+1))
  local got; got="$(jq -r 'length' <<<"$SKIPPED_JSON")"
  if [[ "$got" == "$1" ]]; then echo "  PASS $2"
  else echo "  FAIL $2 — skipped[] has $got, expected $1"; failures=$((failures+1)); fi
}

echo "=== stub fidelity: has_unsafe_chars matches the real common.sh ==="
# The stub lib above hand-copies has_unsafe_chars from validate-plugins/lib/common.sh
# so this suite can stay network-free. That copy is the SAME guard the `only`
# validation cases below assert against — if the real charset ever changes (e.g.
# adds * or ?), the copy would silently keep testing stale behavior and the
# injection-guard cases would pass against a definition that no longer ships. Pin
# the two together: run both implementations over a probe battery and require they
# agree on every input. (Each is sourced in its own subshell so neither clobbers
# the other; the real common.sh is pure function defs + a safe set/RESULTS_FILE top.)
REAL_COMMON="$ACTION_PATH/../validate-plugins/lib/common.sh"
total=$((total+1))
if [[ ! -f "$REAL_COMMON" ]]; then
  echo "  FAIL has_unsafe_chars stub-vs-real — real common.sh not found at $REAL_COMMON"; failures=$((failures+1))
else
  _drift=""
  for _p in "plain-name" "@scope/plugin" "Foo.Bar" "UPPER" "a b" "a	b" 'a$b' 'a`b' 'a;b' 'a&b' 'a|b' 'a(b' 'a)b' 'a<b' 'a>b' 'a"b' "a'b" 'a\b' "a*b" "a?b" "a[b]" ""; do
    _s=0; ( source "$TMP/lib.sh";    has_unsafe_chars "$_p" ) >/dev/null 2>&1 || _s=$?
    _r=0; ( source "$REAL_COMMON";    has_unsafe_chars "$_p" ) >/dev/null 2>&1 || _r=$?
    [[ "$_s" == "$_r" ]] || _drift="$_drift [$_p: stub=$_s real=$_r]"
  done
  if [[ -z "$_drift" ]]; then echo "  PASS has_unsafe_chars stub agrees with real common.sh across the probe battery"
  else echo "  FAIL has_unsafe_chars stub DRIFTED from real common.sh:$_drift"; failures=$((failures+1)); fi
fi

echo "=== bump-plugin-shas freeze/exempt tests ==="

# 1. A frozen, pinned entry is held and recorded — even though its host IS
#    allowlisted, the freeze check fires before any ls-remote (network-free).
f=$(mk freeze <<'EOF'
{"plugins":[{"name":"frozen-plugin","source":{"url":"https://github.com/acme/frozen-plugin","sha":"1111111111111111111111111111111111111111"}}]}
EOF
)
FREEZE_SHAS_FIXTURE="frozen-plugin"; SHA_EXEMPT_FIXTURE=""
run_bump "$f"
assert_reason "frozen-plugin" "frozen at current pin (freeze-shas)" "freeze fires + recorded in skipped[]"
assert_pin_held "$f" "frozen pin held (marketplace unchanged)"
assert_rc 0 "skip-only run exits 0 (Nothing to bump)"

# 2. Freeze match is whole-word: a 'frozen' entry is NOT frozen by the list
#    'frozen-plugin'. It passes the freeze gate and skips for a different
#    reason (host not allowlisted → still network-free).
f=$(mk wholeword <<'EOF'
{"plugins":[{"name":"frozen-plugin","source":{"url":"https://github.com/acme/frozen-plugin","sha":"1111111111111111111111111111111111111111"}},{"name":"frozen","source":{"url":"https://example.com/acme/frozen","sha":"2222222222222222222222222222222222222222"}}]}
EOF
)
FREEZE_SHAS_FIXTURE="frozen-plugin"; SHA_EXEMPT_FIXTURE=""
run_bump "$f"
assert_reason "frozen"        "not in allowlist"                  "substring 'frozen' is NOT frozen (whole-word match)"
assert_reason "frozen-plugin" "frozen at current pin (freeze-shas)" "whole-word entry still frozen"

# 3. sha-exempt path still works (no regression).
f=$(mk exempt <<'EOF'
{"plugins":[{"name":"exempt-plugin","source":{"url":"https://github.com/acme/exempt-plugin"}}]}
EOF
)
FREEZE_SHAS_FIXTURE=""; SHA_EXEMPT_FIXTURE="exempt-plugin"
run_bump "$f"
assert_reason "exempt-plugin" "unpinned by policy (sha-exempt)" "sha-exempt still skips (no regression)"

# 4. Name in BOTH lists → sha-exempt wins (checked first).
f=$(mk both <<'EOF'
{"plugins":[{"name":"dual","source":{"url":"https://github.com/acme/dual"}}]}
EOF
)
FREEZE_SHAS_FIXTURE="dual"; SHA_EXEMPT_FIXTURE="dual"
run_bump "$f"
assert_reason "dual" "unpinned by policy (sha-exempt)" "both-lists precedence: sha-exempt first"

# 5. Reconciliation: a typo'd freeze name (no matching entry) warns loudly.
f=$(mk typo <<'EOF'
{"plugins":[{"name":"frozen-plugin","source":{"url":"https://example.com/acme/frozen-plugin","sha":"1111111111111111111111111111111111111111"}}]}
EOF
)
FREEZE_SHAS_FIXTURE="frozn-plugin"; SHA_EXEMPT_FIXTURE=""
run_bump "$f"
assert_warn "freeze-shas: 'frozn-plugin' matches no external" "typo'd freeze name warns (matches no entry)"

# 6. Reconciliation: a freeze name outside the guard charset (uppercase) warns
#    as invalid — this is the silent-no-op case the warning exists to catch.
f=$(mk badname <<'EOF'
{"plugins":[{"name":"Frozen-Plugin","source":{"url":"https://example.com/acme/frozen-plugin","sha":"1111111111111111111111111111111111111111"}}]}
EOF
)
FREEZE_SHAS_FIXTURE="Frozen-Plugin"; SHA_EXEMPT_FIXTURE=""
run_bump "$f"
assert_warn "freeze-shas: 'Frozen-Plugin' is not a valid plugin name" "charset-excluded freeze name warns as invalid"

# 7. Reconciliation is glob-safe: a '*' in the list must not expand against the
#    filesystem nor freeze a real entry; it warns as invalid and 'abc' is left
#    to normal processing (skips on host).
f=$(mk glob <<'EOF'
{"plugins":[{"name":"abc","source":{"url":"https://example.com/acme/abc","sha":"3333333333333333333333333333333333333333"}}]}
EOF
)
FREEZE_SHAS_FIXTURE="*"; SHA_EXEMPT_FIXTURE=""
run_bump "$f"
assert_warn   "is not a valid plugin name" "glob '*' in freeze list warns, doesn't expand"
assert_reason "abc" "not in allowlist"      "glob '*' does not freeze a real entry"

# 8. No freeze list → no freeze-shas reconciliation noise.
f=$(mk none <<'EOF'
{"plugins":[{"name":"abc","source":{"url":"https://example.com/acme/abc","sha":"3333333333333333333333333333333333333333"}}]}
EOF
)
FREEZE_SHAS_FIXTURE=""; SHA_EXEMPT_FIXTURE=""
run_bump "$f"
assert_no_warn "freeze-shas:" "empty freeze list → no freeze-shas warning"

echo
echo "=== bump-plugin-shas single-plugin (only) target tests ==="

# Shared 2-entry fixture for the `only` cases. Both entries short-circuit BEFORE
# `git ls-remote` (alpha via the freeze gate; beta via a non-allowlisted host), so
# these stay network/gh/claude-free like the rest of this suite. alpha is on
# github.com so that — absent the freeze — it WOULD reach ls-remote; the freeze
# proves the target falls through to its real skip reason rather than the only
# guard swallowing it.
only_fix=$(mk onlytgt <<'EOF'
{"plugins":[{"name":"alpha","source":{"url":"https://github.com/acme/alpha","sha":"1111111111111111111111111111111111111111"}},{"name":"beta","source":{"url":"https://example.com/acme/beta","sha":"2222222222222222222222222222222222222222"}}]}
EOF
)

# 9. only=alpha (a frozen target): alpha still reports its freeze reason; beta is
#    plain-continued (NOT recorded in skipped[]). Proves the target falls through
#    to its real skip reason AND a non-target is silently plain-continued. (NOTE:
#    this case does NOT pin the guard's POSITION relative to the freeze gate — a
#    frozen target reports "frozen" with the guard either before or after freeze.
#    The guard-before-everything ordering invariant is pinned by case 11, which
#    relies on a non-matching target producing ZERO skip records.)
ONLY_FIXTURE="alpha"; FREEZE_SHAS_FIXTURE="alpha"; SHA_EXEMPT_FIXTURE=""
run_bump "$only_fix"
assert_reason      "alpha" "frozen at current pin (freeze-shas)" "only=target still reports its real skip reason"
assert_not_skipped "beta"                                        "only=target → non-target plain-continued (not in skipped[])"
assert_skipped_count 1                                           "only=target → exactly one entry recorded"
assert_pin_held    "$only_fix"                                   "only=target → marketplace unchanged"

# 10. only="" (default): every entry processed exactly as today — alpha frozen,
#     beta host-skipped → both recorded. Proves the empty-ONLY no-op.
ONLY_FIXTURE=""; FREEZE_SHAS_FIXTURE="alpha"; SHA_EXEMPT_FIXTURE=""
run_bump "$only_fix"
assert_reason        "alpha" "frozen at current pin (freeze-shas)" "only='' → alpha still frozen"
assert_reason        "beta"  "not in allowlist"                    "only='' → beta still host-skipped"
assert_skipped_count 2                                             "only='' → both entries processed (byte-identical default)"

# 11. only=<missing>: no entry matches → all plain-continued → Nothing to bump.
ONLY_FIXTURE="ghost"; FREEZE_SHAS_FIXTURE="alpha"; SHA_EXEMPT_FIXTURE=""
run_bump "$only_fix"
assert_skipped_count 0   "only=missing → no entry recorded (all plain-continued)"
assert_rc 0              "only=missing → exits 0 (Nothing to bump)"
assert_pin_held "$only_fix" "only=missing → marketplace unchanged"

# 12. only='bad name' (whitespace): rejected up front via has_unsafe_chars → die.
#     run_bump captures RC via its own `set +e` wrapper — no errexit-suppressing
#     `( … ) || rc=$?` around the command under test.
ONLY_FIXTURE="bad name"; FREEZE_SHAS_FIXTURE=""; SHA_EXEMPT_FIXTURE=""
run_bump "$only_fix"
assert_rc 1 "only='bad name' (whitespace) → die (RC 1)"
assert_warn "contains unsafe characters" "only='bad name' → unsafe-char die message"

# 13. has_unsafe_chars ALLOWS a scoped/dotted name (the whole reason `only` uses it
#     instead of the narrow freeze charset). A scoped target must NOT die — it
#     passes validation and reaches normal processing (here: host-skip, network-free,
#     since the freeze gate's [a-z0-9-] regex doesn't match a scoped name anyway).
scoped_fix=$(mk scoped <<'EOF'
{"plugins":[{"name":"@acme/scoped","source":{"url":"https://example.com/acme/scoped","sha":"4444444444444444444444444444444444444444"}},{"name":"alpha","source":{"url":"https://github.com/acme/alpha","sha":"1111111111111111111111111111111111111111"}}]}
EOF
)
ONLY_FIXTURE="@acme/scoped"; FREEZE_SHAS_FIXTURE=""; SHA_EXEMPT_FIXTURE=""
run_bump "$scoped_fix"
assert_rc 0 "only=@acme/scoped → scoped/dotted name ALLOWED (no die)"
assert_reason "@acme/scoped" "not in allowlist" "scoped target reached processing (host-skip), proving it was allowed past validation"
assert_not_skipped "alpha" "only=@acme/scoped → non-target alpha plain-continued"

# 13b. A non-whitespace shell metacharacter is still rejected (rejection coverage
#      isn't whitespace-only).
ONLY_FIXTURE="a;b"; FREEZE_SHAS_FIXTURE=""; SHA_EXEMPT_FIXTURE=""
run_bump "$scoped_fix"
assert_rc 1 "only='a;b' (metachar) → die"
assert_warn "contains unsafe characters" "only='a;b' → unsafe-char die message"

# 14. The freeze-reconciliation warning block is SKIPPED under a single-plugin run
#     (the `[[ -z "$ONLY" ]]` gate). Two-sided so the gate is load-bearing: a typo'd
#     freeze name warns when ONLY is empty, and is suppressed when ONLY is set.
ONLY_FIXTURE=""; FREEZE_SHAS_FIXTURE="frozn-typo"; SHA_EXEMPT_FIXTURE=""
run_bump "$only_fix"
assert_warn "freeze-shas:" "only='' → freeze-reconciliation warning fires (typo'd name)"
ONLY_FIXTURE="alpha"; FREEZE_SHAS_FIXTURE="frozn-typo"; SHA_EXEMPT_FIXTURE=""
run_bump "$only_fix"
assert_no_warn "freeze-shas:" "only=alpha → freeze-reconciliation warning SUPPRESSED (targeted run)"

ONLY_FIXTURE=""  # reset so it can't leak into any later case

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
