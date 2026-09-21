#!/usr/bin/env bash
# Discover stale external SHAs, validate at new HEAD, open one PR with all
# passing bumps. See action.yml for the design rationale.

set -euo pipefail
[[ -f "${VALIDATE_LIB:?VALIDATE_LIB is required}" ]] || { printf '::error::%s: common.sh not found at %s\n' "${0##*/}" "$VALIDATE_LIB"; exit 1; }
source "$VALIDATE_LIB"
declare -F assert_helpers_defined >/dev/null || { printf '::error::%s: common.sh did not define assert_helpers_defined\n' "${0##*/}"; exit 1; }
assert_helpers_defined

# Marketplace names and validator-derived reasons reach the step summary and
# the generated PR body, both Markdown. This action never runs I11, so a raw
# newline would end a table row or list item and let the rest render as
# Markdown, and a raw pipe would split the row. Every such cell goes through
# this filter, matching what 90-report.sh and scan.sh do with their summaries.
MD_CELL='def cell: (. // "") | tostring | gsub("[\\r\\n|]"; " ");'

: "${MARKETPLACE_PATH:?}"
: "${MAX_BUMPS:?}"
[[ "$MAX_BUMPS" =~ ^[0-9]+$ ]] || die "max-bumps must be a non-negative integer (got: $MAX_BUMPS)"
: "${ALLOWED_HOSTS:?}"
: "${PR_BRANCH:?}"
: "${BASE_BRANCH:?}"
: "${GH_TOKEN:?}"

[[ -f "$MARKETPLACE_PATH" ]] || die "marketplace not found at $MARKETPLACE_PATH"

workroot="$(mktemp -d)"
trap 'rm -rf "$workroot"' EXIT

bumped='[]'
skipped='[]'
checked=0
applied=0

skip() {
  local name="$1" reason="$2"
  warn "$name: skipped ($reason)"
  skipped="$(jq -c --arg n "$name" --arg r "$reason" '. + [{name:$n, reason:$r}]' <<<"$skipped")"
}

group_start "Discover stale SHAs and validate at new HEAD"

while IFS= read -r entry; do
  (( applied >= MAX_BUMPS )) && { log "Reached max-bumps=$MAX_BUMPS; stopping discovery."; break; }
  checked=$((checked+1))

  name="$(jq -r '.name' <<<"$entry")"
  url="$(jq -r '.source.url // .source.repo // empty' <<<"$entry")"
  old_sha="$(jq -r '.source.sha // empty' <<<"$entry")"
  subdir="$(jq -r '.source.path // ""' <<<"$entry")"

  [[ -n "$url" ]] || { skip "$name" "no url/repo on source"; continue; }

  if [[ "$url" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    full_url="https://github.com/$url"
  else
    full_url="$url"
  fi
  # Shared with validate-plugins and scan-plugins so the SSRF contract cannot
  # drift: https only, safe charset, bare IP rejected whatever ALLOWED_HOSTS
  # says, then the allowlist.
  if ! url_reason="$(url_safe_or_reason "$full_url")"; then
    skip "$name" "url rejected: ${url_reason:-unvalidated}"; continue
  fi
  if [[ -n "$subdir" ]] && { has_unsafe_chars "$subdir" || [[ "$subdir" == *".."* ]] || [[ "$subdir" == /* ]]; }; then
    skip "$name" "unsafe subdir"; continue
  fi

  # || true masks SIGPIPE from head -1; the regex below catches partial reads.
  new_sha="$(git ls-remote -- "$full_url" HEAD 2>/dev/null | awk '{print $1}' | head -1 || true)"
  if [[ ! "$new_sha" =~ ^[0-9a-f]{40}$ ]]; then
    skip "$name" "ls-remote failed or returned no HEAD"; continue
  fi
  if [[ "$new_sha" == "$old_sha" ]]; then
    continue
  fi

  # name and old_sha come straight from marketplace.json and this action never
  # runs I11, so both are flattened. The constant prefix keeps the line from
  # starting with `::`, which is the other half of forging a workflow command.
  log "---- $(annot_text "$name" 100): $(annot_text "$old_sha" 64) -> $new_sha ----"

  dest="$workroot/ext-$checked"
  mkdir -p -- "$dest"
  if ! timeout 120 git clone --quiet --depth 1 -- "$full_url" "$dest" 2>&1; then
    skip "$name" "clone failed"; rm -rf -- "$dest"; continue
  fi
  if ! git -C "$dest" fetch --quiet --depth 1 origin -- "$new_sha" 2>&1; then
    skip "$name" "fetch of new sha failed"; rm -rf -- "$dest"; continue
  fi
  if ! git -C "$dest" -c advice.detachedHead=false checkout --quiet "$new_sha" -- 2>&1; then
    skip "$name" "checkout of new sha failed"; rm -rf -- "$dest"; continue
  fi

  target="$dest${subdir:+/$subdir}"
  manifest="$target/.claude-plugin/plugin.json"
  [[ -f "$manifest" ]] || manifest="$target/plugin.json"
  if [[ ! -f "$manifest" ]]; then
    skip "$name" "no plugin manifest at $full_url@${new_sha:0:8}"; rm -rf -- "$dest"; continue
  fi
  if [[ -L "$manifest" ]] || [[ "$(realpath -- "$manifest")" != "$(realpath -- "$dest")"/* ]]; then
    skip "$name" "manifest is a symlink or resolves outside the clone"; rm -rf -- "$dest"; continue
  fi
  if ! out="$(timeout 120 claude plugin validate "$manifest" 2>&1)"; then
    # || true: grep exits 1 when the validator output carries none of these
    # markers, and under `set -euo pipefail` that would abort the whole run
    # instead of skipping this one plugin.
    detail="$(grep -E '❯|Error:' <<<"$out" | head -1 | sed -E 's/^[[:space:]]+//' || true)"
    skip "$name" "validation failed at $full_url@${new_sha:0:8}: ${detail:-$(head -1 <<<"$out")}"
    rm -rf -- "$dest"; continue
  fi
  rm -rf -- "$dest"

  jq --arg n "$name" --arg s "$new_sha" \
    '(.plugins[] | select(.name==$n) | .source.sha) = $s' \
    -- "$MARKETPLACE_PATH" > "$MARKETPLACE_PATH.tmp"
  mv -- "$MARKETPLACE_PATH.tmp" "$MARKETPLACE_PATH"

  bumped="$(jq -c --arg n "$name" --arg o "$old_sha" --arg s "$new_sha" \
    '. + [{name:$n, old_sha:$o, new_sha:$s}]' <<<"$bumped")"
  applied=$((applied+1))
  log "  ✓ $(annot_text "$name" 100) validated and bumped"
done < <(jq -c '.plugins[] | select(.source | type=="object")' -- "$MARKETPLACE_PATH")

group_end

{
  echo "bumped=$bumped"
  echo "skipped=$skipped"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

{
  echo "## Bump Plugin SHAs"
  echo
  echo "Checked $checked external entries. Bumped $applied, skipped $(jq 'length' <<<"$skipped")."
  echo
  if (( applied > 0 )); then
    echo "| Plugin | Old SHA | New SHA |"
    echo "|---|---|---|"
    jq -r "$MD_CELL"'
           .[] | "| \(.name|cell) | `\(.old_sha[0:12]//"(none)"|cell)` | `\(.new_sha[0:12])` |"' <<<"$bumped"
  fi
  if [[ "$(jq 'length' <<<"$skipped")" -gt 0 ]]; then
    echo
    echo "<details><summary>Skipped</summary>"
    echo
    jq -r "$MD_CELL"'
           .[] | "- **\(.name|cell)** — \(.reason|cell)"' <<<"$skipped"
    echo
    echo "</details>"
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if (( applied == 0 )); then
  log "Nothing to bump."
  echo "pr-url=" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 0
fi

group_start "Open PR"

# Commit via GitHub's GraphQL `createCommitOnBranch` mutation rather than a
# local `git commit` + push. Commits created server-side are signed by GitHub's
# web-flow GPG key and show as "Verified" — required when the base branch
# enforces `required_signatures` (e.g. via an org-level ruleset). A local
# commit in CI has no signing key and would be unmergeable.
#
# This also avoids importing any signing key material onto the runner: there
# is nothing to leak, rotate, or revoke. The token already in scope is the
# only credential involved, and `expectedHeadOid` gives compare-and-swap
# semantics so a concurrent push fails loudly instead of being clobbered
# (the workflow's `concurrency` group already serializes runs; this is
# belt-and-suspenders).

base_sha="$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/heads/${BASE_BRANCH}" --jq '.object.sha')"
[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve $BASE_BRANCH HEAD"

# Point the PR branch at base HEAD: create if absent, force-reset if present.
# Force-reset is intentional — each run produces one fresh commit on top of
# base, replacing a stale unmerged bump rather than stacking on it (matches
# the previous `git checkout -B` + force-push semantics).
if ! gh api -X POST "repos/${GITHUB_REPOSITORY}/git/refs" \
       -f ref="refs/heads/${PR_BRANCH}" -f sha="$base_sha" >/dev/null 2>&1; then
  gh api -X PATCH "repos/${GITHUB_REPOSITORY}/git/refs/heads/${PR_BRANCH}" \
    -f sha="$base_sha" -F force=true >/dev/null \
    || die "could not create or reset $PR_BRANCH"
fi

commit_msg="Bump $applied plugin SHA pin(s) to upstream HEAD"

# Build the request body with jq and pipe it: the base64-encoded marketplace
# can exceed Linux's per-argument limit (MAX_ARG_STRLEN, 128 KiB), so the file
# content must travel via stdin rather than `gh api -f/-F`.
new_oid="$(
  jq -n \
    --rawfile content "$MARKETPLACE_PATH" \
    --arg repo   "$GITHUB_REPOSITORY" \
    --arg branch "$PR_BRANCH" \
    --arg oid    "$base_sha" \
    --arg msg    "$commit_msg" \
    --arg path   "$MARKETPLACE_PATH" \
    '{
      query: "mutation($repo:String!,$branch:String!,$oid:GitObjectID!,$msg:String!,$path:String!,$contents:Base64String!){createCommitOnBranch(input:{branch:{repositoryNameWithOwner:$repo,branchName:$branch},message:{headline:$msg},fileChanges:{additions:[{path:$path,contents:$contents}]},expectedHeadOid:$oid}){commit{oid}}}",
      variables: {
        repo: $repo, branch: $branch, oid: $oid, msg: $msg,
        path: $path, contents: ($content | @base64)
      }
    }' \
  | gh api graphql --input - --jq '.data.createCommitOnBranch.commit.oid'
)" || die "createCommitOnBranch failed"
[[ "$new_oid" =~ ^[0-9a-f]{40}$ ]] || die "createCommitOnBranch did not return a commit OID (got: $new_oid)"
log "Created signed commit $new_oid on $PR_BRANCH"

body="$workroot/pr-body.md"
{
  echo "Automated SHA bump. Each entry below was cloned at the new SHA and passed \`claude plugin validate\` in [this workflow run]($RUN_URL) before being included."
  echo
  echo "| Plugin | Old SHA | New SHA |"
  echo "|---|---|---|"
  jq -r "$MD_CELL"'
         .[] | "| \(.name|cell) | `\(.old_sha[0:12]//"(none)"|cell)` | `\(.new_sha[0:12])` |"' <<<"$bumped"
  if [[ "$(jq 'length' <<<"$skipped")" -gt 0 ]]; then
    echo
    echo "Skipped (not bumped — see run for details): $(jq -r "$MD_CELL"'[.[].name|cell] | join(", ")' <<<"$skipped")"
  fi
} > "$body"

if existing="$(gh pr list --head "$PR_BRANCH" --base "$BASE_BRANCH" --state open --json url -q '.[0].url' 2>/dev/null)" && [[ -n "$existing" ]]; then
  gh pr edit "$existing" --body-file "$body"
  pr_url="$existing"
else
  pr_url="$(gh pr create --base "$BASE_BRANCH" --head "$PR_BRANCH" \
    --title "Bump $applied plugin SHA pin(s)" --body-file "$body")"
fi

echo "pr-url=$pr_url" >> "${GITHUB_OUTPUT:-/dev/stdout}"
log "PR: $pr_url"
group_end
