#!/usr/bin/env bash
# Static test suite for invariants I1-I11. No API key, no network — pure
# bash/jq against synthetic marketplace.json fixtures. Run locally or in CI
# on every PR touching validate-plugins/.
#
# Fixtures use heredocs (not quoted args) so the suite runs identically on
# macOS bash 3.2 and Linux bash 5.x — nested \"...\" inside $(...) triggers
# brace expansion under 3.2's parser.

set -euo pipefail
cd "$(dirname "$0")"
export ACTION_PATH="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0; total=0

mk() { local f="$TMP/$1.json"; cat > "$f"; printf '%s' "$f"; }

run_invariants() {
  export VALIDATE_TMP="$TMP/v" MARKETPLACE_PATH="$1" BASE_REF=HEAD WARN_INVARIANTS="" ENTRIES_DIR="${2:-}"
  rm -rf "$VALIDATE_TMP"; mkdir -p "$VALIDATE_TMP"
  cp "$1" "$VALIDATE_TMP/marketplace.json"
  bash scripts/11-validate-invariants.sh 2>&1 || true
}

assert_fires() {
  total=$((total+1))
  if run_invariants "$3" "${4:-}" | grep -q "invariant $2:"; then
    echo "  PASS $1 — $2 fires"
  else echo "  FAIL $1 — expected $2 to fire"; failures=$((failures+1)); fi
}

assert_clean() {
  total=$((total+1))
  out="$(run_invariants "$2")"
  if grep -qE '::error|::warning' <<<"$out"; then
    echo "  FAIL $1 — expected clean, got:"; grep -E '::error|::warning' <<<"$out" | sed 's/^/    /'
    failures=$((failures+1))
  else echo "  PASS $1 — clean"; fi
}

echo "=== validate-plugins invariant tests ==="

f=$(mk good <<'EOF'
{"plugins":[{"name":"aaa","description":"A valid description here.","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}
EOF
); assert_clean "baseline good entry" "$f"

f=$(mk i1 <<'EOF'
{"plugins":[{"name":"zzz","description":"ten chars ok","source":"./z"},{"name":"aaa","description":"ten chars ok","source":"./a"}]}
EOF
); assert_fires "I1 unsorted" I1 "$f"

f=$(mk i2 <<'EOF'
{"plugins":[{"name":"aaa","description":"ten chars ok","source":"./x"},{"name":"aaa","description":"ten chars ok","source":"./y"}]}
EOF
); assert_fires "I2 duplicate name" I2 "$f"

f=$(mk i3 <<'EOF'
{"plugins":[{"name":"abc","description":"short","source":"./x"}]}
EOF
); assert_fires "I3 desc too short" I3 "$f"

f=$(mk i4 <<'EOF'
{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"url","url":"http://insecure.example/x","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}
EOF
); assert_fires "I4 unsafe url" I4 "$f"

f=$(mk i5 <<'EOF'
{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y"}}]}
EOF
); assert_fires "I5 missing sha" I5 "$f"

# I6/I7: per-file mode invariants — need an entries-dir with a misnamed file
mkdir -p "$TMP/entries"
cat > "$TMP/entries/wrong.json" <<'EOF'
{"name":"right","description":"ten chars ok","source":"./x"}
EOF
f=$(mk i6 <<'EOF'
{"plugins":[{"name":"right","description":"ten chars ok","source":"./x"}]}
EOF
); assert_fires "I6 filename != name" I6 "$f" "$TMP/entries"

f=$(mk i8 <<'EOF'
{"plugins":[{"name":"abc","description":"ten chars ok","source":"./does-not-exist"}]}
EOF
); assert_fires "I8 vendored path missing" I8 "$f"

f=$(mk i9 <<'EOF'
{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y;rm","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}
EOF
); assert_fires "I9 shell metachar" I9 "$f"

# I10: U+200B ZWSP embedded in description
f="$TMP/i10.json"; printf '{"plugins":[{"name":"abc","description":"hello​world ten chars","source":"./x"}]}' > "$f"
assert_fires "I10 hidden unicode" I10 "$f"

f=$(mk i11 <<'EOF'
{"plugins":[{"name":"Bad_Name","description":"ten chars ok","source":"./x"}]}
EOF
); assert_fires "I11 bad name format" I11 "$f"

# I7: per-file mode forbids editing the assembled marketplace.json directly.
# Simulate by initializing a real git repo and committing a change to MP.
i7_repo="$TMP/i7-repo"
mkdir -p "$i7_repo/plugins" "$i7_repo/.claude-plugin"
( cd "$i7_repo"
  git init -q -b main
  git config user.email t@t.t; git config user.name t
  git config commit.gpgsign false; git config gpg.format openpgp
  echo '{"plugins":[]}' > .claude-plugin/marketplace.json
  cat > plugins/abc.json <<'EOF'
{"name":"abc","description":"ten chars ok","source":"./x"}
EOF
  mkdir -p x/.claude-plugin
  echo '{"name":"abc"}' > x/.claude-plugin/plugin.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
  # Now edit MP directly on a new commit — this is what I7 forbids.
  echo '{"plugins":[{"name":"abc","description":"ten chars ok","source":"./x"}]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "edit MP directly"
) >/dev/null 2>&1

i7_run() {
  ( cd "$i7_repo"
    export VALIDATE_TMP="$TMP/v-i7" \
           MARKETPLACE_PATH=".claude-plugin/marketplace.json" \
           BASE_REF="HEAD~1" \
           WARN_INVARIANTS="" \
           ENTRIES_DIR="plugins"
    rm -rf "$VALIDATE_TMP"; mkdir -p "$VALIDATE_TMP"
    cp .claude-plugin/marketplace.json "$VALIDATE_TMP/marketplace.json"
    bash "$ACTION_PATH/scripts/11-validate-invariants.sh" 2>&1 || true
  )
}
total=$((total+1))
if i7_run | grep -q "invariant I7:"; then
  echo "  PASS I7 direct MP edit — I7 fires"
else
  echo "  FAIL I7 direct MP edit — expected I7 to fire"
  failures=$((failures+1))
fi

# ---- false-positive guards: confirm invariants do NOT fire on edge cases ---

# I3 boundary: description exactly 10 chars (the minimum) must pass.
f=$(mk i3_min <<'EOF'
{"plugins":[{"name":"aaa","description":"0123456789","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}
EOF
); assert_clean "I3 description exactly 10 chars" "$f"

# I1: case-insensitive sort — "Apple" before "banana" must NOT fire I1.
f=$(mk i1_case <<'EOF'
{"plugins":[{"name":"apple","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},{"name":"banana","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]}
EOF
); assert_clean "I1 case-insensitive sorted entries" "$f"

# I3: leading whitespace in description (alternate path within I3).
f=$(mk i3_ws <<'EOF'
{"plugins":[{"name":"abc","description":"  ten chars ok with leading ws","source":"./x"}]}
EOF
); assert_fires "I3 leading whitespace in description" I3 "$f"

# I9: shell metacharacter in non-url object source field (e.g. path).
f=$(mk i9_path <<'EOF'
{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"git-subdir","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path":"sub;rm"}}]}
EOF
); assert_fires "I9 metachar in source.path" I9 "$f"

# Warning mode: when a code is in WARN_INVARIANTS, the script emits a warning
# (not an error) and exits 0. Validate I1 demoted to warning does NOT fail.
# Use URL sources so only I1 fires (vendored paths would also trip I8).
total=$((total+1))
f=$(mk warn_mode <<'EOF'
{"plugins":[{"name":"zzz","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},{"name":"aaa","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]}
EOF
)
set +e
warn_out="$(
  export VALIDATE_TMP="$TMP/v-warn" MARKETPLACE_PATH="$f" BASE_REF=HEAD WARN_INVARIANTS="I1"
  rm -rf "$VALIDATE_TMP"; mkdir -p "$VALIDATE_TMP"
  cp "$f" "$VALIDATE_TMP/marketplace.json"
  bash scripts/11-validate-invariants.sh 2>&1
)"
warn_exit=$?
set -e
if [[ "$warn_exit" -eq 0 ]] && grep -q '::warning .*invariant I1:' <<<"$warn_out" \
   && ! grep -q '::error .*invariant I1:' <<<"$warn_out"; then
  echo "  PASS WARN_INVARIANTS demotes I1 to warning, exits 0"
else
  echo "  FAIL WARN_INVARIANTS demotion — exit=$warn_exit, output:"
  sed 's/^/    /' <<<"$warn_out"
  failures=$((failures+1))
fi

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
