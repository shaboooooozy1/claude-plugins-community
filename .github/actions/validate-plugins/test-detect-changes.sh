#!/usr/bin/env bash
# Static test suite for 00-detect-changes.sh. No API key, no network — uses
# local git repos as fixtures. Runs in CI on every PR touching validate-plugins/.

set -euo pipefail
cd "$(dirname "$0")"
export ACTION_PATH="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0; total=0

pass() { echo "  PASS $1"; }
fail() { echo "  FAIL $1 — $2"; failures=$((failures+1)); }

GIT_AUTHOR_DATE="2020-01-01T00:00:00+00:00"
GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
export GIT_AUTHOR_DATE GIT_COMMITTER_DATE

init_repo() {
  local repo="$TMP/$1"
  mkdir -p "$repo/.claude-plugin"
  ( cd "$repo"
    git init -q -b main
    git config user.email t@t.t; git config user.name t
    git config commit.gpgsign false; git config gpg.format openpgp
  )
  printf '%s' "$repo"
}

run_detect() {
  local repo="$1" mp="$2" base_ref="$3" entries_dir="${4:-}"
  ( cd "$repo"
    export VALIDATE_TMP="$repo/.validate-tmp"
    export ACTION_PATH="$OLDPWD"
    export GITHUB_OUTPUT="$repo/.github-output"
    export MARKETPLACE_PATH="$mp"
    export BASE_REF="$base_ref"
    export ENTRIES_DIR="$entries_dir"
    rm -rf "$VALIDATE_TMP"; mkdir -p "$VALIDATE_TMP"
    : > "$GITHUB_OUTPUT"
    bash "$ACTION_PATH/scripts/00-detect-changes.sh" 2>&1 || true
  )
}

echo "=== detect-changes tests ==="

# ---- single-file mode: no changes --------------------------------------------
total=$((total+1))
repo="$(init_repo sf-nochange)"
( cd "$repo"
  echo '{"plugins":[{"name":"aaa","description":"ten chars ok","source":"./x"}]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD" "" >/dev/null 2>&1
entries="$(jq -r '.entries | length' "$repo/.validate-tmp/changes.json" 2>/dev/null || echo err)"
if [[ "$entries" == "0" ]]; then
  pass "single-file: no changes = empty entries"
else fail "single-file: no changes = empty entries" "got $entries entries"; fi

# ---- single-file mode: added entry -------------------------------------------
total=$((total+1))
repo="$(init_repo sf-add)"
( cd "$repo"
  echo '{"plugins":[{"name":"aaa","description":"ten chars ok","source":"./x"}]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
  echo '{"plugins":[{"name":"aaa","description":"ten chars ok","source":"./x"},{"name":"bbb","description":"ten chars ok","source":"./y"}]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "add bbb"
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD~1" "" >/dev/null 2>&1
if jq -e '.entries | index("bbb")' "$repo/.validate-tmp/changes.json" >/dev/null 2>&1; then
  pass "single-file: added entry detected"
else fail "single-file: added entry detected" "bbb not in entries"; fi

# ---- single-file mode: modified entry ----------------------------------------
total=$((total+1))
repo="$(init_repo sf-mod)"
( cd "$repo"
  echo '{"plugins":[{"name":"aaa","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
  echo '{"plugins":[{"name":"aaa","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "mod aaa"
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD~1" "" >/dev/null 2>&1
if jq -e '.entries | index("aaa")' "$repo/.validate-tmp/changes.json" >/dev/null 2>&1; then
  pass "single-file: modified entry detected"
else fail "single-file: modified entry detected" "aaa not in entries"; fi

# ---- single-file mode: unchanged entry excluded ------------------------------
total=$((total+1))
repo="$(init_repo sf-unchanged)"
( cd "$repo"
  cat > .claude-plugin/marketplace.json <<'J'
{"plugins":[{"name":"aaa","description":"ten chars ok","source":"./x"},{"name":"bbb","description":"ten chars ok","source":"./y"}]}
J
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
  cat > .claude-plugin/marketplace.json <<'J'
{"plugins":[{"name":"aaa","description":"updated description here","source":"./x"},{"name":"bbb","description":"ten chars ok","source":"./y"}]}
J
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "mod aaa only"
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD~1" "" >/dev/null 2>&1
entries_json="$(jq -c '.entries' "$repo/.validate-tmp/changes.json" 2>/dev/null)"
if jq -e 'index("aaa")' <<<"$entries_json" >/dev/null 2>&1 \
   && ! jq -e 'index("bbb")' <<<"$entries_json" >/dev/null 2>&1; then
  pass "single-file: unchanged entry excluded"
else fail "single-file: unchanged entry excluded" "entries=$entries_json"; fi

# ---- single-file mode: external vs vendored in changed-external ---------------
total=$((total+1))
repo="$(init_repo sf-external)"
( cd "$repo"
  echo '{"plugins":[]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
  cat > .claude-plugin/marketplace.json <<'J'
{"plugins":[{"name":"ext","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},{"name":"ven","description":"ten chars ok","source":"./v"}]}
J
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "add both"
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD~1" "" >/dev/null 2>&1
ext_json="$(jq -c '.external' "$repo/.validate-tmp/changes.json" 2>/dev/null)"
if jq -e 'length == 1 and .[0].name == "ext"' <<<"$ext_json" >/dev/null 2>&1; then
  pass "single-file: external in changed-external, vendored excluded"
else fail "single-file: external in changed-external, vendored excluded" "external=$ext_json"; fi

# ---- per-file mode: assembles marketplace ------------------------------------
total=$((total+1))
repo="$(init_repo pf-assemble)"
( cd "$repo"
  mkdir -p plugins
  echo '{"name":"bbb","description":"ten chars ok","source":"./y"}' > plugins/bbb.json
  echo '{"name":"aaa","description":"ten chars ok","source":"./x"}' > plugins/aaa.json
  echo '{"plugins":[]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD" "plugins" >/dev/null 2>&1
assembled="$(jq -c '[.plugins[].name]' "$repo/.validate-tmp/marketplace.json" 2>/dev/null)"
if [[ "$assembled" == '["aaa","bbb"]' ]]; then
  pass "per-file: assembles marketplace sorted by name"
else fail "per-file: assembles marketplace sorted by name" "got $assembled"; fi

# ---- per-file mode: changed file under ENTRIES_DIR detected -------------------
total=$((total+1))
repo="$(init_repo pf-changed)"
( cd "$repo"
  mkdir -p plugins
  echo '{"name":"aaa","description":"ten chars ok","source":"./x"}' > plugins/aaa.json
  echo '{"plugins":[]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
  echo '{"name":"bbb","description":"ten chars ok","source":"./y"}' > plugins/bbb.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "add bbb"
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD~1" "plugins" >/dev/null 2>&1
if jq -e '.entries | index("bbb")' "$repo/.validate-tmp/changes.json" >/dev/null 2>&1; then
  pass "per-file: changed file detected as changed entry"
else fail "per-file: changed file detected as changed entry" "bbb not in entries"; fi

# ---- BASE_REF unresolvable falls back to ALL_CHANGED --------------------------
total=$((total+1))
repo="$(init_repo fallback)"
( cd "$repo"
  echo '{"plugins":[{"name":"aaa","description":"ten chars ok","source":"./x"}]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
) >/dev/null 2>&1
out="$(run_detect "$repo" ".claude-plugin/marketplace.json" "nonexistent-ref-xyz-123" "" 2>&1)"
if grep -qi "ALL.*changed\|treating ALL" <<<"$out"; then
  pass "BASE_REF unresolvable falls back to ALL_CHANGED"
else fail "BASE_REF unresolvable falls back to ALL_CHANGED" "no ALL_CHANGED warning in output"; fi

# ---- GITHUB_OUTPUT receives all three outputs ---------------------------------
total=$((total+1))
repo="$(init_repo gh-output)"
( cd "$repo"
  echo '{"plugins":[{"name":"aaa","description":"ten chars ok","source":"./x"}]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD" "" >/dev/null 2>&1
gh_out="$(cat "$repo/.github-output" 2>/dev/null)"
if grep -q "changed-entries=" <<<"$gh_out" \
   && grep -q "changed-external=" <<<"$gh_out" \
   && grep -q "changed-folders=" <<<"$gh_out"; then
  pass "GITHUB_OUTPUT receives all three outputs"
else fail "GITHUB_OUTPUT receives all three outputs" "missing keys in: $gh_out"; fi

# ---- folder detection: walk-up to .claude-plugin/plugin.json ------------------
total=$((total+1))
repo="$(init_repo folder-walkup)"
( cd "$repo"
  mkdir -p partner/slack/.claude-plugin partner/slack/src
  echo '{"name":"slack"}' > partner/slack/.claude-plugin/plugin.json
  echo '{"plugins":[]}' > .claude-plugin/marketplace.json
  echo "initial" > partner/slack/src/foo.txt
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
  echo "changed" > partner/slack/src/foo.txt
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "edit foo.txt"
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD~1" "" >/dev/null 2>&1
if jq -e '.folders | index("partner/slack")' "$repo/.validate-tmp/changes.json" >/dev/null 2>&1; then
  pass "folder detection: walk-up finds partner/slack"
else fail "folder detection: walk-up finds partner/slack" "folders=$(jq -c '.folders' "$repo/.validate-tmp/changes.json" 2>/dev/null)"; fi

# ---- ALL_CHANGED discovers all plugin folders ---------------------------------
total=$((total+1))
repo="$(init_repo folder-all)"
( cd "$repo"
  mkdir -p p1/.claude-plugin p2/.claude-plugin
  echo '{"name":"p1"}' > p1/.claude-plugin/plugin.json
  echo '{"name":"p2"}' > p2/.claude-plugin/plugin.json
  echo '{"plugins":[]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "nonexistent-ref-xyz-456" "" >/dev/null 2>&1
folders="$(jq -c '.folders' "$repo/.validate-tmp/changes.json" 2>/dev/null)"
if jq -e 'index("p1") and index("p2")' <<<"$folders" >/dev/null 2>&1; then
  pass "ALL_CHANGED discovers all plugin folders"
else fail "ALL_CHANGED discovers all plugin folders" "folders=$folders"; fi

# ---- no plugin.json = no folder match ----------------------------------------
total=$((total+1))
repo="$(init_repo folder-nomatch)"
( cd "$repo"
  mkdir -p somedir/src
  echo "initial" > somedir/src/code.txt
  echo '{"plugins":[]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m init
  echo "changed" > somedir/src/code.txt
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "edit code.txt"
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD~1" "" >/dev/null 2>&1
folders="$(jq -c '.folders' "$repo/.validate-tmp/changes.json" 2>/dev/null)"
if [[ "$folders" == "[]" ]]; then
  pass "no plugin.json = no folder match"
else fail "no plugin.json = no folder match" "folders=$folders"; fi

# ---- base marketplace not in git = empty base ---------------------------------
total=$((total+1))
repo="$(init_repo base-missing)"
( cd "$repo"
  echo '{}' > .claude-plugin/dummy.txt
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "init no mp"
  echo '{"plugins":[{"name":"new","description":"ten chars ok","source":"./x"}]}' > .claude-plugin/marketplace.json
  GIT_CONFIG_GLOBAL=/dev/null git add -A
  GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "add mp"
) >/dev/null 2>&1
run_detect "$repo" ".claude-plugin/marketplace.json" "HEAD~1" "" >/dev/null 2>&1
if jq -e '.entries | index("new")' "$repo/.validate-tmp/changes.json" >/dev/null 2>&1; then
  pass "base marketplace missing = all entries detected as changed"
else fail "base marketplace missing = all entries detected as changed" "entries=$(jq -c '.entries' "$repo/.validate-tmp/changes.json" 2>/dev/null)"; fi

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
