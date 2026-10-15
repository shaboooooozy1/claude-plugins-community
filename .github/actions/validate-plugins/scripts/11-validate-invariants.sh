#!/usr/bin/env bash
# Custom hardening invariants beyond the JSON Schema.
# Always runs on the full marketplace.
#
# I1  plugins[] alpha-sorted by name
# I2  no duplicate names
# I3  description 10-2000 chars, no leading/trailing whitespace
# I4  all source.url are https:// (re-checked here as defense-in-depth)
# I5  every external source has a 40-char sha
# I6  per-file mode: filename matches .name
# I7  per-file mode: PR does not edit assembled marketplace.json directly
# I8  vendored source path exists and contains .claude-plugin/plugin.json
# I9  url/path/sha contain no shell metacharacters; path is relative and has no '..'
# I10 name/description contain no hidden-Unicode (zero-width / bidi controls)
# I11 name matches ^[a-z0-9][a-z0-9-]{1,63}$

source "$ACTION_PATH/lib/common.sh"

# Marks this step done only on a zero exit, so an abort part-way through
# (a die, or set -e on an unexpected error) leaves it begun-but-unfinished
# and 90-report.sh fails the run rather than aggregating to PASS.
STEP_ID=11-invariants
step_begin "$STEP_ID"
trap 'rc=$?; if [[ $rc -eq 0 ]]; then step_done "$STEP_ID"; fi' EXIT

: "${VALIDATE_TMP:?}"
: "${MARKETPLACE_PATH:?}"
MP="$VALIDATE_TMP/marketplace.json"
WARN_INVARIANTS=" ${WARN_INVARIANTS:-I1 I3 I5 I8} "
failures=0
warnings=0

entry_line() {
  local name="$1"
  [[ -n "$name" ]] || return 0
  grep -nF -e "\"name\": \"$name\"" -- "$MARKETPLACE_PATH" 2>/dev/null | head -1 | cut -d: -f1 || true
}

flag() {
  local code="$1" msg="$2" name="${3:-}"
  msg="$(annot_text "$msg")"
  local line; line="$(entry_line "$name")"
  local loc="file=$MARKETPLACE_PATH${line:+,line=$line}"
  if [[ "$WARN_INVARIANTS" == *" $code "* ]]; then
    printf '::warning %s::invariant %s: %s\n' "$loc" "$code" "$msg"
    record_result "invariants" "warn" "$code" "$msg"; warnings=$((warnings+1))
  else
    printf '::error %s::invariant %s: %s\n' "$loc" "$code" "$msg"
    record_result "invariants" "fail" "$code" "$msg"; failures=$((failures+1))
  fi
}

group_start "Custom invariants I1-I11"

# I1 sort (case-insensitive, matching upstream assembler convention)
sorted="$(jq -r '[.plugins[].name | ascii_downcase] | . == (.|sort)' -- "$MP")"
[[ "$sorted" == "true" ]] || flag "I1" "plugins[] is not alpha-sorted by name (case-insensitive)"

# I2 dups
dups="$(jq -r '[.plugins[].name] | group_by(.) | map(select(length>1) | .[0]) | .[]' -- "$MP")"
[[ -z "$dups" ]] || flag "I2" "duplicate plugin names: $(tr '\n' ' ' <<<"$dups")"

# I3/I10/I11 — per-entry name/description checks.
#
# The hidden-Unicode test, the length and the whitespace test are all computed
# in jq rather than in bash, because every bash equivalent is locale-dependent
# and this action runs on runners whose locale nobody controls. A glob bracket
# expression is character-aware only in a multibyte locale; `${#s}` counts
# characters only in one. Under LC_ALL=C — which is what a `container:` job or
# a self-hosted runner with no locale set gets — both fall back to bytes, and
# the byte set of the hidden-Unicode literals (E2, EF, 80, 8B-8F, BB, BF, ...)
# is shared by almost every common non-ASCII character. An em dash was enough:
# 709 of this repo's own entries fired I10 under C and none of them contain any
# hidden Unicode, while I10 blocks by default, so the whole gate hard-failed on
# ordinary text. jq decodes JSON to codepoints, so these give the documented
# character semantics identically on every runner.
#
# U+200B ZWSP, U+200C ZWNJ, U+200D ZWJ, U+200E LRM, U+200F RLM,
# U+202A-202E bidi embedding/override, U+2066-2069 bidi isolates, U+FEFF BOM.
#
# The whitespace test moved here for a second reason on top of the locale one
# (`[[:space:]]` covers Unicode spaces under some locales and ASCII only under
# others): it used sed, whose ^ and $ anchor to each LINE. A description with
# an indented continuation line was therefore reported as having leading or
# trailing whitespace it does not have — 53 entries of this marketplace,
# several containing no non-ASCII character at all. These anchors apply to the
# whole description, which is what the rule has always meant.
#
# One jq invocation for the whole stream rather than two per entry, which also
# takes this loop from ~10.7s to ~0.04s on the 1714-entry marketplace.
# @tsv escapes any tab or newline inside a name, so a hostile value cannot
# forge extra fields or extra lines.
while IFS=$'\t' read -r name hidden dlen badws; do
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{1,63}$ ]]; then
    flag "I11" "$name: name does not match ^[a-z0-9][a-z0-9-]{1,63}\$" "$name"
  fi
  if [[ "$hidden" == "true" ]]; then
    flag "I10" "$name: name/description contains hidden-Unicode (zero-width or bidi control)" "$name"
  fi
  if (( dlen < 10 || dlen > 2000 )); then
    flag "I3" "$name: description length $dlen not in [10,2000]" "$name"
  fi
  if [[ "$badws" == "true" ]]; then
    flag "I3" "$name: description has leading/trailing whitespace" "$name"
  fi
done < <(jq -r '
  def hidden: test("[\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]");
  # \x{...}, not \u.... jq resolves \uXXXX inside a string literal, but this
  # string IS the regex, so the escape has to be one Oniguruma understands.
  # Written \u here it degrades to a literal `u` plus digits, and the ranges
  # then span most of ASCII: "ten chars ok" matched, and every entry was
  # flagged for trailing whitespace it does not have.
  def ws: "[\\s\\x{00a0}\\x{1680}\\x{2000}-\\x{200a}\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}]";
  .plugins[]
  | (.name // "") as $n
  | (.description // "") as $d
  | [ $n,
      (($n + $d) | hidden),
      ($d | length),
      ($d | test("^" + ws) or test(ws + "$"))
    ] | @tsv' -- "$MP")

# I4 / I5 / I9 — external sources (shape-agnostic: applies to any object source).
# We don't enumerate source kinds here; the canonical schema check is step 20.
# This layer enforces security policy on whichever fields are present.
while IFS= read -r entry; do
  name="$(jq -r '.name' <<<"$entry")"
  url="$(jq -r '.source.url // .source.repo // empty' <<<"$entry")"
  sha="$(jq -r '.source.sha // empty' <<<"$entry")"

  if [[ -n "$url" ]]; then
    if [[ ! "$url" =~ ^https://[A-Za-z0-9./_-]+$ ]] && \
       [[ ! "$url" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
      flag "I4" "$name: source url/repo is not a safe https URL or owner/repo shorthand: $url" "$name"
    fi
  fi
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    flag "I5" "$name: source.sha is missing or not a 40-char hex SHA" "$name"
  fi

  sp="$(jq -r '.source.path // empty' <<<"$entry")"
  if [[ -n "$sp" ]] && { [[ "$sp" == /* ]] || [[ "$sp" == *".."* ]]; }; then
    flag "I9" "$name: source.path is absolute or contains '..': $sp" "$name"
  fi

  # I9: every string-valued field under .source must be free of shell metacharacters.
  # NUL-delimited so an embedded newline stays inside one value instead of
  # splitting into two lines that each look clean.
  while IFS= read -r -d '' v; do
    [[ -z "$v" ]] && continue
    if has_unsafe_chars "$v"; then
      flag "I9" "$name: source field contains shell metacharacters: $v" "$name"
    fi
  done < <(jq -j '.source | to_entries[] | select(.value|type=="string") | .value + "\u0000"' <<<"$entry")
done < <(jq -c '.plugins[] | select(.source | type == "object")' -- "$MP")

# I6 / I7 — per-file mode only
if [[ -n "${ENTRIES_DIR:-}" ]]; then
  assert_safe_ref "$BASE_REF"
  for f in "$ENTRIES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .json)"
    inner="$(jq -r '.name' -- "$f")"
    [[ "$base" == "$inner" ]] || flag "I6" "$f: filename '$base' != .name '$inner'" "$inner"
  done
  if ! i7_diff="$(git diff --name-only "$BASE_REF"...HEAD -- 2>&1)"; then
    flag "I7" "cannot diff against '$BASE_REF' ($i7_diff); unable to verify $MARKETPLACE_PATH was not edited directly"
  elif grep -qxF -- "$MARKETPLACE_PATH" <<<"$i7_diff"; then
    flag "I7" "PR edits $MARKETPLACE_PATH directly; per-file repos must edit $ENTRIES_DIR/*.json only"
  fi
fi

# I8 — vendored paths exist
WS_ROOT="${GITHUB_WORKSPACE:-$PWD}"
while IFS= read -r entry; do
  name="$(jq -r '.name' <<<"$entry")"
  p="$(jq -r '.source' <<<"$entry")"
  if has_unsafe_chars "$p" || [[ "$p" == *".."* ]] || [[ "$p" == /* ]]; then
    flag "I9" "$name: vendored source path is absolute or contains unsafe characters: $p" "$name"
    continue
  fi
  p_clean="${p#./}"
  manifest="$p_clean/.claude-plugin/plugin.json"
  # The checks above are lexical and `-f`/`-e` follow symlinks, so BOTH the
  # source root and the manifest must be tested for containment. The root is
  # tested FIRST, ahead of the manifest-existence branch: that branch ends in
  # `continue`, so an escaped source whose target happens to carry no
  # plugin.json would otherwise be reported as a warn-by-default I8 "no
  # manifest" and the escape never named at all. I9 rather than I8 because a
  # path escape has to block.
  # Guarded on existence so the severity contract holds: a source that is
  # simply absent is the genuine I8 case and must stay in the warn tier, and
  # only a path that exists and resolves outside is promoted. A dangling
  # symlink fails -e and lands on I8 too, correctly — nothing can read it.
  if [[ -e "$p_clean" ]] && ! why="$(path_contained_or_reason "$p_clean" "$WS_ROOT")"; then
    flag "I9" "$name: vendored source '$p' ${why:-is not contained}" "$name"
    continue
  fi
  if [[ ! -f "$manifest" ]]; then
    flag "I8" "$name: vendored source '$p' has no .claude-plugin/plugin.json" "$name"
    continue
  fi
  if ! why="$(path_contained_or_reason "$manifest" "$WS_ROOT")"; then
    flag "I9" "$name: manifest for vendored source '$p' ${why:-is not contained}" "$name"
  fi
done < <(jq -c '.plugins[] | select(.source | type == "string")' -- "$MP")

if (( failures > 0 )); then
  die "$failures invariant error(s), $warnings warning(s)"
fi

if (( warnings > 0 )) && [[ "${FAIL_ON_WARNINGS:-false}" == "true" ]]; then
  die "$warnings invariant warning(s) (fail-on-warnings is set)"
fi

record_result "invariants" "pass" "summary" "0 errors, $warnings warning(s)"
log "invariants: 0 errors, $warnings warning(s)"
group_end
