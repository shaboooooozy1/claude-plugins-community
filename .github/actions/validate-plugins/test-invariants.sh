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
f=$(mk i10); printf '{"plugins":[{"name":"abc","description":"hello​world ten chars","source":"./x"}]}' > "$f"
assert_fires "I10 hidden unicode" I10 "$f"

# Locale independence for I3/I10. The bash forms these replaced were only
# character-aware in a multibyte locale; under LC_ALL=C they compared bytes,
# and the byte set of the hidden-Unicode literals is shared by almost every
# common non-ASCII character. An em dash alone hard-failed the gate, and 709
# entries of the real marketplace fired I10 with no hidden Unicode in any of
# them. These run under an explicit LC_ALL so a runner with no locale set —
# a `container:` job, a self-hosted runner — is covered, which is exactly the
# false-positive guard CLAUDE.md requires for a boundary like this.
run_invariants_locale() {
  local loc="$1" mp="$2"
  ( export VALIDATE_TMP="$TMP/vl" MARKETPLACE_PATH="$mp" BASE_REF=HEAD \
           WARN_INVARIANTS="" ENTRIES_DIR="" LC_ALL="$loc" LANG="$loc"
    rm -rf "$VALIDATE_TMP"; mkdir -p "$VALIDATE_TMP"
    cp "$mp" "$VALIDATE_TMP/marketplace.json"
    bash scripts/11-validate-invariants.sh 2>&1 || true )
}

# Legitimate non-ASCII text: em dash, accented letter, arrow, CJK. None of it
# is a zero-width or bidi control, so nothing may fire in any locale.
f=$(mk i10_nonascii)
python3 -c "
import json,sys
json.dump({'plugins':[{'name':'abc','description':'Plots — charts, café data, x → y, 日本語',
                       'source':{'source':'url','url':'https://github.com/x/y','sha':'a'*40}}]},
          open(sys.argv[1],'w'), ensure_ascii=False)" "$f"
for loc in C C.utf8; do
  total=$((total+1))
  out="$(run_invariants_locale "$loc" "$f")"
  if grep -qE 'invariant (I3|I10):' <<<"$out"; then
    echo "  FAIL I10 legitimate non-ASCII under LC_ALL=$loc — expected no I3/I10, got:"
    grep -E 'invariant (I3|I10):' <<<"$out" | sed 's/^/    /'
    failures=$((failures+1))
  else echo "  PASS I10 legitimate non-ASCII stays clean under LC_ALL=$loc"; fi
done

# The check must still catch a real one in a C locale, not merely stop firing.
for loc in C C.utf8; do
  total=$((total+1))
  if run_invariants_locale "$loc" "$TMP/i10.json" | grep -q "invariant I10:"; then
    echo "  PASS I10 hidden unicode still fires under LC_ALL=$loc"
  else
    echo "  FAIL I10 hidden unicode under LC_ALL=$loc — expected I10 to fire"
    failures=$((failures+1))
  fi
done

# I3's bound is documented in characters. A 1500-character description of
# 2-byte characters measures 3000 bytes and was flagged under LC_ALL=C.
f=$(mk i3_chars)
python3 -c "
import json,sys
json.dump({'plugins':[{'name':'abc','description':'é'*1500,
                       'source':{'source':'url','url':'https://github.com/x/y','sha':'a'*40}}]},
          open(sys.argv[1],'w'), ensure_ascii=False)" "$f"
for loc in C C.utf8; do
  total=$((total+1))
  if run_invariants_locale "$loc" "$f" | grep -q 'description length'; then
    echo "  FAIL I3 1500-char description under LC_ALL=$loc — measured in bytes"
    failures=$((failures+1))
  else echo "  PASS I3 1500-char description counts characters under LC_ALL=$loc"; fi
done

# I3 whitespace anchors apply to the whole description, not to each line.
# The sed form this replaced anchored per line, so any description with an
# indented continuation line was reported as having leading/trailing
# whitespace it does not have — 53 entries of the real marketplace, including
# ones containing no non-ASCII character at all.
i3_ws_case() {  # <label> <expect: fire|clean> <python-repr description>
  local label="$1" expect="$2" desc="$3" g
  g=$(mk "i3ws_$(printf '%s' "$label" | tr -c 'a-z0-9' _)")
  python3 -c "
import json,sys
json.dump({'plugins':[{'name':'abc','description':$desc,
                       'source':{'source':'url','url':'https://github.com/x/y','sha':'a'*40}}]},
          open(sys.argv[1],'w'))" "$g"
  total=$((total+1))
  if run_invariants_locale C "$g" | grep -q 'leading/trailing whitespace'; then
    if [[ "$expect" == fire ]]; then echo "  PASS I3 whitespace: $label fires"
    else echo "  FAIL I3 whitespace: $label — false positive"; failures=$((failures+1)); fi
  else
    if [[ "$expect" == clean ]]; then echo "  PASS I3 whitespace: $label clean"
    else echo "  FAIL I3 whitespace: $label — expected it to fire"; failures=$((failures+1)); fi
  fi
}
i3_ws_case "internal trailing space on a non-final line" clean "'ten chars ok   \nsecond line'"
i3_ws_case "indented continuation line"                  clean "'ten chars ok\n   second line'"
i3_ws_case "genuine leading whitespace"                  fire  "' ten chars ok\nsecond line'"
i3_ws_case "genuine trailing whitespace"                 fire  "'ten chars ok\nsecond line '"

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
  local base="${1:-HEAD~1}"
  ( cd "$i7_repo"
    export VALIDATE_TMP="$TMP/v-i7" \
           MARKETPLACE_PATH=".claude-plugin/marketplace.json" \
           BASE_REF="$base" \
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

# I7 must fail closed: an undiffable BASE_REF is an I7 error, not a silent pass.
total=$((total+1))
if i7_run "0000000000000000000000000000000000000000" | grep -q "invariant I7: cannot diff"; then
  echo "  PASS I7 undiffable BASE_REF — I7 fires (fail closed)"
else
  echo "  FAIL I7 undiffable BASE_REF — expected I7 to fire"
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

# I9: traversal / absolute paths in object source.path and vendored source.
f=$(mk i9_traversal <<'EOF'
{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"git-subdir","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path":"../x"}}]}
EOF
); assert_fires "I9 traversal in source.path" I9 "$f"

f=$(mk i9_abs <<'EOF'
{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"git-subdir","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path":"/etc"}}]}
EOF
); assert_fires "I9 absolute source.path" I9 "$f"

f=$(mk i9_vendored_abs <<'EOF'
{"plugins":[{"name":"abc","description":"ten chars ok","source":"/etc/passwd"}]}
EOF
); assert_fires "I9 absolute vendored source" I9 "$f"

# False-positive guard: a dotted (but not '..') relative path is fine.
f=$(mk i9_dotted <<'EOF'
{"plugins":[{"name":"aaa","description":"A valid description here.","source":{"source":"git-subdir","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path":"packages/foo.bar"}}]}
EOF
); assert_clean "I9 dotted path is not traversal" "$f"

# A vendored source may be a symlink out of the checkout. The lexical checks
# above cannot see that, and `-f` follows it, so containment is checked on the
# resolved path. Needs a real workspace, so it runs in its own directory.
# $3 is WARN_INVARIANTS, defaulting to "" so everything blocks. The severity
# guards below pass the shipped default instead, because what they assert is
# that a finding stays in the warn tier.
run_in_workspace() {
  local ws="$1" mp="$2" warn="${3-}"
  ( cd "$ws" \
    && VALIDATE_TMP="$ws/.v" MARKETPLACE_PATH="$mp" BASE_REF=HEAD WARN_INVARIANTS="$warn" \
       ENTRIES_DIR="" GITHUB_WORKSPACE="$ws" ACTION_PATH="$ACTION_PATH" \
       bash -c 'rm -rf "$VALIDATE_TMP"; mkdir -p "$VALIDATE_TMP"
                cp "$MARKETPLACE_PATH" "$VALIDATE_TMP/marketplace.json"
                bash "$ACTION_PATH/scripts/11-validate-invariants.sh" 2>&1 || true' )
}

ws="$TMP/ws"; outside="$TMP/outside"
mkdir -p "$ws" "$outside/.claude-plugin" "$ws/real-plugin/.claude-plugin"
echo '{"name":"real-plugin"}' > "$ws/real-plugin/.claude-plugin/plugin.json"
echo '{"name":"escaped"}'     > "$outside/.claude-plugin/plugin.json"
ln -s "$outside" "$ws/escaped"
cat > "$ws/mp-escape.json" <<'EOF'
{"plugins":[{"name":"escaped","description":"ten chars ok","source":"./escaped"}]}
EOF
cat > "$ws/mp-real.json" <<'EOF'
{"plugins":[{"name":"real-plugin","description":"ten chars ok","source":"./real-plugin"}]}
EOF
total=$((total+1))
if run_in_workspace "$ws" "$ws/mp-escape.json" | grep -q "invariant I9:"; then
  echo "  PASS I9 symlinked vendored source — I9 fires"
else echo "  FAIL I9 symlinked vendored source — expected I9 to fire"; failures=$((failures+1)); fi
total=$((total+1))
if run_in_workspace "$ws" "$ws/mp-real.json" | grep -qE '::error|::warning'; then
  echo "  FAIL I9 real vendored source stays clean — unexpected finding"; failures=$((failures+1))
else echo "  PASS I9 real vendored source stays clean"; fi

# The escape must be caught even when the target carries no plugin.json. The
# manifest-existence branch ends in `continue`, so testing containment after it
# let this case report only a warn-by-default I8 "no manifest" and exit 0 —
# naming the wrong problem and not blocking. Root containment is tested first.
mkdir -p "$TMP/bare-outside"
ln -s "$TMP/bare-outside" "$ws/nomanifest"
ln -s "$TMP/does-not-exist-anywhere" "$ws/dangling"
cat > "$ws/mp-nomanifest.json" <<'EOF'
{"plugins":[{"name":"sneaky","description":"ten chars ok","source":"./nomanifest"}]}
EOF
cat > "$ws/mp-missing.json" <<'EOF'
{"plugins":[{"name":"typo","description":"ten chars ok","source":"./does-not-exist"}]}
EOF
cat > "$ws/mp-dangling.json" <<'EOF'
{"plugins":[{"name":"dangly","description":"ten chars ok","source":"./dangling"}]}
EOF
total=$((total+1))
if run_in_workspace "$ws" "$ws/mp-nomanifest.json" | grep -q "invariant I9:"; then
  echo "  PASS I9 escaped vendored source with no manifest — I9 fires"
else echo "  FAIL I9 escaped vendored source with no manifest — expected I9 to fire"; failures=$((failures+1)); fi

# Severity guards for the existence condition on that check. A source that is
# simply absent, or a dangling symlink, is the genuine I8 case and must stay in
# the warn tier under the shipped default; promoting it would break the
# WARN_INVARIANTS contract downstream repos rely on.
for case_name in missing dangling; do
  total=$((total+1))
  out="$(run_in_workspace "$ws" "$ws/mp-$case_name.json" "I1 I3 I5 I8")"
  if grep -q "invariant I8:" <<<"$out" && ! grep -q '::error' <<<"$out"; then
    echo "  PASS I8 $case_name vendored source stays a warning"
  else
    echo "  FAIL I8 $case_name vendored source — expected a warning-only I8"
    failures=$((failures+1))
  fi
done

# Annotation injection: a newline inside a source field must fire I9 AND must
# not be able to start a forged ::error line of its own.
f=$(mk i9_newline <<'EOF'
{"plugins":[{"name":"abc","description":"ten chars ok","source":{"source":"git-subdir","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path":"a\n::error::forged"}}]}
EOF
); assert_fires "I9 newline in path" I9 "$f"
total=$((total+1))
if run_invariants "$f" | grep -q '^::error::forged'; then
  echo "  FAIL I9 newline in path — forged annotation line reached output"
  failures=$((failures+1))
else
  echo "  PASS I9 newline in path — no forged annotation line"
fi

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

# FAIL_ON_WARNINGS: same fixture as warn_mode (I1 demoted), but with
# FAIL_ON_WARNINGS=true the script should exit non-zero.
total=$((total+1))
set +e
fow_out="$(
  export VALIDATE_TMP="$TMP/v-fow" MARKETPLACE_PATH="$f" BASE_REF=HEAD WARN_INVARIANTS="I1" FAIL_ON_WARNINGS=true
  rm -rf "$VALIDATE_TMP"; mkdir -p "$VALIDATE_TMP"
  cp "$f" "$VALIDATE_TMP/marketplace.json"
  bash scripts/11-validate-invariants.sh 2>&1
)"
fow_exit=$?
set -e
if [[ "$fow_exit" -ne 0 ]] && grep -q '::warning .*invariant I1:' <<<"$fow_out"; then
  echo "  PASS FAIL_ON_WARNINGS turns demoted warning into failure exit"
else
  echo "  FAIL FAIL_ON_WARNINGS — exit=$fow_exit, output:"
  sed 's/^/    /' <<<"$fow_out"
  failures=$((failures+1))
fi

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
