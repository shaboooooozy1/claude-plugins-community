#!/usr/bin/env bash
# Static test suite for detect-changes.sh. Uses temporary git repos only; no
# network, no Claude CLI.

set -euo pipefail
cd "$(dirname "$0")"
export ACTION_PATH="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0; total=0

pass() { echo "  PASS $1"; }
fail() { echo "  FAIL $1 — $2"; failures=$((failures+1)); }

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    git config commit.gpgsign false
    git config gpg.format openpgp
  )
}

commit_all() {
  local repo="$1" msg="$2"
  (
    cd "$repo"
    GIT_CONFIG_GLOBAL=/dev/null git add -A
    GIT_CONFIG_GLOBAL=/dev/null git commit -q --no-gpg-sign -m "$msg"
  )
}

run_detect() {
  local repo="$1" base_ref="$2" marketplace_path="$3" out_dir="$4" entries_dir="${5:-}"
  (
    cd "$repo"
    export VALIDATE_TMP="$out_dir" BASE_REF="$base_ref" MARKETPLACE_PATH="$marketplace_path"
    if [[ -n "$entries_dir" ]]; then
      export ENTRIES_DIR="$entries_dir"
    else
      unset ENTRIES_DIR || true
    fi
    rm -rf "$VALIDATE_TMP"
    mkdir -p "$VALIDATE_TMP"
    bash "$ACTION_PATH/scripts/00-detect-changes.sh" >/dev/null 2>&1
  )
}

assert_jq() {
  total=$((total+1))
  local label="$1" file="$2" filter="$3"
  if jq -e "$filter" -- "$file" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label" "jq assertion failed: $filter"
  fi
}

echo "=== detect-changes static tests ==="

# ---- single-file mode -------------------------------------------------------
single_repo="$TMP/single"
single_out="$TMP/out-single"
init_repo "$single_repo"
mkdir -p "$single_repo/.claude-plugin" "$single_repo/local-plugin/.claude-plugin"
cat > "$single_repo/.claude-plugin/marketplace.json" <<'EOF'
{"plugins":[
  {"name":"alpha","description":"alpha description v1","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
  {"name":"beta","description":"beta description ok","source":"./local-plugin"}
]}
EOF
echo '{"name":"beta"}' > "$single_repo/local-plugin/.claude-plugin/plugin.json"
echo 'v1' > "$single_repo/local-plugin/notes.txt"
commit_all "$single_repo" "init single"

cat > "$single_repo/.claude-plugin/marketplace.json" <<'EOF'
{"plugins":[
  {"name":"alpha","description":"alpha description v2","source":{"source":"url","url":"https://github.com/x/y","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},
  {"name":"beta","description":"beta description ok","source":"./local-plugin"}
]}
EOF
echo 'v2' > "$single_repo/local-plugin/notes.txt"
commit_all "$single_repo" "update single"

run_detect "$single_repo" "HEAD~1" ".claude-plugin/marketplace.json" "$single_out"
assert_jq "single-file mode detects changed marketplace entry" \
  "$single_out/changes.json" '.entries == ["alpha"]'
assert_jq "single-file mode filters changed external entries" \
  "$single_out/changes.json" '.external | length == 1 and .[0].name == "alpha"'
assert_jq "single-file mode finds touched local plugin folder" \
  "$single_out/changes.json" '.folders == ["local-plugin"]'
assert_jq "single-file mode copies current marketplace" \
  "$single_out/marketplace.json" '.plugins[0].description == "alpha description v2"'

# ---- per-file mode ----------------------------------------------------------
per_repo="$TMP/per-file"
per_out="$TMP/out-per-file"
init_repo "$per_repo"
mkdir -p "$per_repo/.claude-plugin" "$per_repo/plugins"
cat > "$per_repo/.claude-plugin/manifest.json" <<'EOF'
{"name":"claude-community","owner":{"name":"Anthropic"}}
EOF
cat > "$per_repo/plugins/zeta.json" <<'EOF'
{"name":"zeta","description":"zeta description ok","source":"./vendored-zeta"}
EOF
cat > "$per_repo/plugins/alpha.json" <<'EOF'
{"name":"alpha","description":"alpha description ok","source":{"source":"url","url":"https://github.com/org/alpha","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
EOF
commit_all "$per_repo" "init per-file"

cat > "$per_repo/plugins/alpha.json" <<'EOF'
{"name":"alpha","description":"alpha description changed","source":{"source":"url","url":"https://github.com/org/alpha","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
EOF
commit_all "$per_repo" "update alpha entry"

run_detect "$per_repo" "HEAD~1" ".claude-plugin/marketplace.json" "$per_out" "plugins"
assert_jq "per-file mode assembles sorted marketplace" \
  "$per_out/marketplace.json" '.plugins | map(.name) == ["alpha","zeta"]'
assert_jq "per-file mode preserves manifest header" \
  "$per_out/marketplace.json" '.owner.name == "Anthropic" and .name == "claude-community"'
assert_jq "per-file mode detects changed entry filenames" \
  "$per_out/changes.json" '.entries == ["alpha"]'
assert_jq "per-file mode emits changed external entry payloads" \
  "$per_out/changes.json" '.external | length == 1 and .[0].source.sha == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'

# ---- unresolved base ref falls back to all changed --------------------------
all_repo="$TMP/all-changed"
all_out="$TMP/out-all"
init_repo "$all_repo"
mkdir -p "$all_repo/.claude-plugin" "$all_repo/plugins" \
  "$all_repo/local-a/.claude-plugin" "$all_repo/nested/local-b/.claude-plugin"
cat > "$all_repo/plugins/beta.json" <<'EOF'
{"name":"beta","description":"beta description ok","source":"./local-a"}
EOF
cat > "$all_repo/plugins/alpha.json" <<'EOF'
{"name":"alpha","description":"alpha description ok","source":{"source":"url","url":"https://github.com/org/alpha","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
EOF
echo '{"name":"beta"}' > "$all_repo/local-a/.claude-plugin/plugin.json"
echo '{"name":"local-b"}' > "$all_repo/nested/local-b/.claude-plugin/plugin.json"
commit_all "$all_repo" "init all changed"

run_detect "$all_repo" "origin/missing-ref" ".claude-plugin/marketplace.json" "$all_out" "plugins"
assert_jq "missing base ref marks all entries changed" \
  "$all_out/changes.json" '.entries | sort == ["alpha","beta"]'
assert_jq "missing base ref marks all external entries changed" \
  "$all_out/changes.json" '.external | length == 1 and .[0].name == "alpha"'
assert_jq "missing base ref discovers every local plugin folder" \
  "$all_out/changes.json" '.folders | sort == ["local-a","nested/local-b"]'

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
