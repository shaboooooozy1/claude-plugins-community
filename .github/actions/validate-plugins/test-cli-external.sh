#!/usr/bin/env bash
# Static test suite for 30-validate-cli-external.sh. No network — stubs both
# `claude` and `git` to exercise all logic branches offline.

set -euo pipefail
cd "$(dirname "$0")"
export ACTION_PATH="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
failures=0; total=0

pass() { echo "  PASS $1"; }
fail() { echo "  FAIL $1 — $2"; failures=$((failures+1)); }

REAL_GIT="$(command -v git)"
export ALLOWED_HOSTS="github.com gitlab.com bitbucket.org"

# The git stub scans arguments for the subcommand (skipping -C/-c flags),
# then intercepts clone/fetch/checkout while delegating everything else.
write_git_stub() {
  local stubpath="$1" mode="${2:-pass}" logfile="${3:-/dev/null}"
  cat > "$stubpath" <<GITSTUB
#!/usr/bin/env bash
# Find the git subcommand by skipping -C <dir> and -c <setting> pairs
subcmd=""
i=1
while [[ \$i -le \$# ]]; do
  arg="\${!i}"
  case "\$arg" in
    -C|-c) i=\$((i+2)); continue ;;
    -*) i=\$((i+1)); continue ;;
    *) subcmd="\$arg"; break ;;
  esac
done
case "\$subcmd" in
  clone)
    dest="\${*: -1}"
    echo "CLONE_URL=\${*: -2:1}" >> "$logfile"
GITSTUB

  case "$mode" in
    pass)
      cat >> "$stubpath" <<'GITSTUB'
    mkdir -p "$dest/.claude-plugin"
    echo '{"name":"test"}' > "$dest/.claude-plugin/plugin.json"
    exit 0 ;;
GITSTUB
      ;;
    clone-fail)
      cat >> "$stubpath" <<'GITSTUB'
    echo "fatal: clone failed"; exit 128 ;;
GITSTUB
      ;;
    no-claudedir)
      cat >> "$stubpath" <<'GITSTUB'
    mkdir -p "$dest"
    echo '{"name":"test"}' > "$dest/plugin.json"
    exit 0 ;;
GITSTUB
      ;;
    no-manifest)
      cat >> "$stubpath" <<'GITSTUB'
    mkdir -p "$dest"
    exit 0 ;;
GITSTUB
      ;;
    no-subdir)
      cat >> "$stubpath" <<'GITSTUB'
    mkdir -p "$dest/.claude-plugin"
    echo '{"name":"test"}' > "$dest/.claude-plugin/plugin.json"
    exit 0 ;;
GITSTUB
      ;;
  esac

  cat >> "$stubpath" <<GITSTUB
  fetch) exit 0 ;;
  checkout) exit 0 ;;
  *) "$REAL_GIT" "\$@" ;;
esac
GITSTUB
  chmod +x "$stubpath"
}

write_claude_stub() {
  local stubpath="$1" mode="${2:-pass}"
  case "$mode" in
    pass)
      cat > "$stubpath" <<'STUB'
#!/usr/bin/env bash
echo "Validation passed"
exit 0
STUB
      ;;
    fail)
      cat > "$stubpath" <<'STUB'
#!/usr/bin/env bash
echo "Error: schema violation"
exit 1
STUB
      ;;
  esac
  chmod +x "$stubpath"
}

mk_test() {
  local label="$1" git_mode="${2:-pass}"
  local vtmp="$TMP/ext-$label"
  local stubdir="$TMP/stubs-$label"
  rm -rf "$vtmp" "$stubdir"; mkdir -p "$vtmp" "$stubdir"
  write_git_stub "$stubdir/git" "$git_mode" "$vtmp/git-log.txt"
  write_claude_stub "$stubdir/claude" "pass"
  echo '{"plugins":[]}' > "$vtmp/marketplace.json"
  printf '%s' "$vtmp"
}

run_ext() {
  local vtmp="$1"
  local stubdir="$TMP/stubs-${vtmp##*ext-}"
  ( export PATH="$stubdir:$PATH"
    export VALIDATE_TMP="$vtmp"
    export EXTERNAL_TIMEOUT_SECS=10
    export VALIDATE_ALL_EXTERNAL="${VALIDATE_ALL_EXTERNAL:-false}"
    bash "$ACTION_PATH/scripts/30-validate-cli-external.sh" 2>&1
  )
}

echo "=== cli-external tests ==="

# ---- empty external targets = skip --------------------------------------------
total=$((total+1))
vtmp="$(mk_test empty)"
echo '{"entries":[],"external":[],"folders":[]}' > "$vtmp/changes.json"
VALIDATE_ALL_EXTERNAL=false
set +e; out="$(run_ext "$vtmp" 2>&1)"; rc=$?; set -e
if [[ $rc -eq 0 ]] && grep -qi "skip\|No external" <<<"$out"; then
  pass "empty external targets = skip"
else fail "empty external targets = skip" "exit=$rc"; fi

# ---- missing url = fail recorded -----------------------------------------------
total=$((total+1))
vtmp="$(mk_test no-url)"
echo '{"entries":[],"external":[{"name":"no-url","source":{"source":"url"}}],"folders":[]}' > "$vtmp/changes.json"
VALIDATE_ALL_EXTERNAL=false
set +e; out="$(run_ext "$vtmp" 2>&1)"; rc=$?; set -e
if grep -q "no url/repo" <<<"$out"; then
  pass "missing url = fail recorded"
else fail "missing url = fail recorded" "output: $out"; fi

# ---- missing sha = fail recorded -----------------------------------------------
total=$((total+1))
vtmp="$(mk_test no-sha)"
echo '{"entries":[],"external":[{"name":"no-sha","source":{"source":"url","url":"https://github.com/x/y"}}],"folders":[]}' > "$vtmp/changes.json"
VALIDATE_ALL_EXTERNAL=false
set +e; out="$(run_ext "$vtmp" 2>&1)"; rc=$?; set -e
if grep -q "no sha pin" <<<"$out"; then
  pass "missing sha = fail recorded"
else fail "missing sha = fail recorded" "output: $out"; fi

# ---- owner/repo shorthand expansion -------------------------------------------
total=$((total+1))
vtmp="$(mk_test shorthand)"
echo '{"entries":[],"external":[{"name":"sh","source":{"source":"url","url":"owner/repo","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}],"folders":[]}' > "$vtmp/changes.json"
VALIDATE_ALL_EXTERNAL=false
set +e; out="$(run_ext "$vtmp" 2>&1)"; rc=$?; set -e
if grep -q "CLONE_URL=https://github.com/owner/repo" "$vtmp/git-log.txt" 2>/dev/null; then
  pass "owner/repo shorthand expanded to full URL"
else fail "owner/repo shorthand expanded to full URL" "log=$(cat "$vtmp/git-log.txt" 2>/dev/null)"; fi

# ---- git clone failure = fail recorded -----------------------------------------
total=$((total+1))
vtmp="$(mk_test clone-fail clone-fail)"
echo '{"entries":[],"external":[{"name":"cf","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}],"folders":[]}' > "$vtmp/changes.json"
VALIDATE_ALL_EXTERNAL=false
set +e; out="$(run_ext "$vtmp" 2>&1)"; rc=$?; set -e
if grep -q "git clone failed" <<<"$out"; then
  pass "git clone failure = fail recorded"
else fail "git clone failure = fail recorded" "output: $out"; fi

# ---- subdir not found = fail recorded ------------------------------------------
total=$((total+1))
vtmp="$(mk_test subdir-miss no-subdir)"
echo '{"entries":[],"external":[{"name":"sd","source":{"source":"git-subdir","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path":"nonexistent"}}],"folders":[]}' > "$vtmp/changes.json"
VALIDATE_ALL_EXTERNAL=false
set +e; out="$(run_ext "$vtmp" 2>&1)"; rc=$?; set -e
if grep -q "subdir.*not found" <<<"$out"; then
  pass "subdir not found = fail recorded"
else fail "subdir not found = fail recorded" "output: $out"; fi

# ---- plugin.json fallback (no .claude-plugin/) --------------------------------
total=$((total+1))
vtmp="$(mk_test manifest-fb no-claudedir)"
echo '{"entries":[],"external":[{"name":"fb","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}],"folders":[]}' > "$vtmp/changes.json"
VALIDATE_ALL_EXTERNAL=false
set +e; out="$(run_ext "$vtmp" 2>&1)"; rc=$?; set -e
if grep -q "OK" <<<"$out"; then
  pass "plugin.json fallback (no .claude-plugin/)"
else fail "plugin.json fallback (no .claude-plugin/)" "output: $out"; fi

# ---- no plugin manifest anywhere = fail ----------------------------------------
total=$((total+1))
vtmp="$(mk_test no-manifest no-manifest)"
echo '{"entries":[],"external":[{"name":"nm","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}],"folders":[]}' > "$vtmp/changes.json"
VALIDATE_ALL_EXTERNAL=false
set +e; out="$(run_ext "$vtmp" 2>&1)"; rc=$?; set -e
if grep -q "no plugin manifest" <<<"$out"; then
  pass "no plugin manifest anywhere = fail"
else fail "no plugin manifest anywhere = fail" "output: $out"; fi

# ---- VALIDATE_ALL_EXTERNAL reads from marketplace -----------------------------
total=$((total+1))
vtmp="$(mk_test val-all)"
echo '{"plugins":[{"name":"ext1","description":"ten chars ok","source":{"source":"url","url":"https://github.com/x/y","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}' > "$vtmp/marketplace.json"
echo '{"entries":[],"external":[],"folders":[]}' > "$vtmp/changes.json"
VALIDATE_ALL_EXTERNAL=true
set +e; out="$(run_ext "$vtmp" 2>&1)"; rc=$?; set -e
VALIDATE_ALL_EXTERNAL=false
if grep -q "ext1" <<<"$out" && grep -q "OK" <<<"$out"; then
  pass "VALIDATE_ALL_EXTERNAL reads from marketplace"
else fail "VALIDATE_ALL_EXTERNAL reads from marketplace" "output: $out"; fi

echo
echo "=== $((total-failures))/$total passed ==="
[[ "$failures" -eq 0 ]]
