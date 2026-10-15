#!/usr/bin/env bash
# Shared helpers for validate-plugins action scripts.
# Source this at the top of every script: source "$ACTION_PATH/lib/common.sh"

set -euo pipefail

# ---- logging ---------------------------------------------------------------

log()   { printf '%s\n' "$*"; }
info()  { printf '::notice::%s\n' "$*"; }
# For text that came from a plugin, a model or a CLI. GitHub reads ANY line
# starting with `::` as a workflow command, so flattening newlines is not
# enough on its own: a value whose first line is `::error::...` would still
# forge one. Indenting every line makes that structurally impossible while
# keeping the output readable.
log_untrusted() { printf '%s\n' "$*" | sed 's/^/  | /'; }
# Every annotation goes through annot_text: contributor- and model-derived text
# reaches these sinks (plugin names, refs, validator output), and an embedded
# newline would otherwise start a forged ::error:: / ::warning:: command.
warn()  { printf '::warning::%s\n' "$(annot_text "$*")"; }
error() { printf '::error::%s\n' "$(annot_text "$*")"; }
die()   { error "$*"; record_result "fatal" "fail" "die" "$*"; exit 1; }

group_start() { printf '::group::%s\n' "$*"; }
group_end()   { printf '::endgroup::\n'; }

# ---- result tracking -------------------------------------------------------
# Scripts append findings here; 90-report.sh reads it.

RESULTS_FILE="${VALIDATE_TMP:-./.validate-tmp}/results.jsonl"

record_result() {
  local step="$1" status="$2" subject="$3" detail="${4:-}"
  mkdir -p "$(dirname "$RESULTS_FILE")"
  jq -cn \
    --arg step "$step" \
    --arg status "$status" \
    --arg subject "$subject" \
    --arg detail "$detail" \
    '{step:$step, status:$status, subject:$subject, detail:$detail}' \
    >> "$RESULTS_FILE"
}

# ---- step completion tracking ---------------------------------------------
# 90-report.sh runs with `if: always()`, so it also runs after a step aborted
# part-way. Counting `status=="fail"` rows is not enough to catch that: a step
# that dies from `set -e` on an unexpected error (a failed jq, a failed mkdir)
# records nothing, so a run whose earlier steps logged passes still aggregates
# to zero failures and reports PASS. Presence of the results file does not help
# either, for the same reason.
#
# Each step marks itself begun and, on every path that is a real completion
# (including the early "nothing to do" exits), done. The report then fails on
# any step that began without finishing. A step skipped by its `if:` in
# action.yml never begins, so it is never required to finish — no expected-step
# list to keep in sync.
STEPS_DIR="${VALIDATE_TMP:-./.validate-tmp}/steps"

step_begin() { mkdir -p "$STEPS_DIR"; : > "$STEPS_DIR/$1.begin"; }
step_done()  { mkdir -p "$STEPS_DIR"; : > "$STEPS_DIR/$1.done"; }

# Echoes the id of every step that began and did not finish, one per line.
incomplete_steps() {
  local b id
  [[ -d "$STEPS_DIR" ]] || return 0
  for b in "$STEPS_DIR"/*.begin; do
    [[ -e "$b" ]] || continue
    id="$(basename -- "$b" .begin)"
    [[ -e "$STEPS_DIR/$id.done" ]] || printf '%s\n' "$id"
  done
}

# ---- safety predicates / assertions ---------------------------------------

# Returns 0 if the value contains shell metacharacters or whitespace.
# Newline/CR are rejected explicitly ($'\n'/$'\r'): they are not caught by the
# space/tab patterns, and an embedded newline in a path/subdir/source field is
# both illegitimate and a classic log/workflow-command injection vector. URL and
# SHA call sites are additionally anchored by their own ^...$ regexes.
has_unsafe_chars() {
  case "$1" in
    *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'('*|*')'*|*'<'*|*'>'*|*' '*|*'	'*|*$'\n'*|*$'\r'*|*'"'*|*"'"*|*'\'*)
      return 0 ;;
  esac
  return 1
}

# Flatten CR/LF and cap length so contributor- or model-authored text cannot
# start a new ::workflow-command line when interpolated into an annotation.
annot_text() {
  local s="${1//$'\r'/ }"; s="${s//$'\n'/ }"
  printf '%s' "${s:0:${2:-500}}"
}

assert_safe_string() {
  local label="$1" value="$2"
  if has_unsafe_chars "$value"; then
    die "$label contains unsafe characters: $value"
  fi
}

# URL must be https://<allowed-host>/<safe-chars> only.
# Host must be in ALLOWED_HOSTS (space-separated) and must not be a bare IP.
# SSRF guard: prevents cloning from metadata endpoints / internal ranges.
#
# Non-fatal form: returns 0 only when the URL is safe to hand to git, and
# non-zero with a short reason on stdout otherwise. scan.sh and bump.sh skip
# one target and keep going rather than aborting, so they call this directly
# instead of the asserting wrapper. One implementation is what stops the three
# actions drifting apart on the SSRF contract.
#
# The polarity is deliberately the OPPOSITE of has_unsafe_chars. Callers gate
# on success, so any failure of this function itself must land on the reject
# side: sourcing an older common.sh where it is undefined makes the call
# substitution exit 127, and under `success == safe` that would wave the URL
# through to git. Only an explicit `return 0` here means safe.
url_safe_or_reason() {
  local url="$1"
  if has_unsafe_chars "$url"; then
    printf 'contains unsafe characters'; return 1
  fi
  if [[ ! "$url" =~ ^https://[A-Za-z0-9./_-]+$ ]]; then
    printf 'does not match ^https://[A-Za-z0-9./_-]+$'; return 1
  fi
  local host="${url#https://}"
  host="${host%%/*}"
  # Rejected ahead of the allowlist and independently of it: an operator who
  # puts an IP in ALLOWED_HOSTS must not thereby open a path to a metadata
  # endpoint or an internal range.
  if [[ "$host" =~ ^[0-9.]+$ ]] || [[ "$host" =~ : ]]; then
    printf 'host is a bare IP address or carries a port'; return 1
  fi
  # Empty is fail-closed rather than fatal: this runs inside a command
  # substitution, where an exiting `:?` would be swallowed.
  local allowed="${ALLOWED_HOSTS:-}"
  if [[ -z "$allowed" ]]; then
    printf 'ALLOWED_HOSTS is empty'; return 1
  fi
  local h
  for h in $allowed; do
    if [[ "$host" == "$h" ]] || [[ "$host" == *".$h" ]]; then
      return 0
    fi
  done
  printf "host '%s' is not in the allowlist" "$host"; return 1
}

assert_safe_url() {
  local reason
  if ! reason="$(url_safe_or_reason "$1")"; then
    die "url rejected (${reason:-unvalidated}): $1"
  fi
}

# Physical containment. Every lexical path check in this codebase is followed
# by an operation that resolves symlinks (-f, -d, cd, jq, claude plugin
# validate), so anything deciding WHAT gets read must compare resolved paths.
# Returns 0 only when $1 resolves to $2 or below it, with a reason on stdout
# otherwise — same polarity as url_safe_or_reason, so a failure of the check
# itself cannot be read as containment. Three steps had their own copy of this
# and they did not agree; keep it here.
path_contained_or_reason() {
  local target="$1" root="$2"
  local root_phys target_phys
  # Tested explicitly rather than with `realpath -e`: plain realpath succeeds
  # on a path whose final component is absent (so a missing target would read
  # as contained), and BSD realpath has no -e. A dangling symlink fails -e too,
  # which is the outcome we want.
  if [[ ! -e "$root" ]]; then
    printf 'root %s does not exist' "$root"; return 1
  fi
  if [[ ! -e "$target" ]]; then
    printf 'does not exist'; return 1
  fi
  root_phys="$(realpath -- "$root" 2>/dev/null || true)"
  if [[ -z "$root_phys" ]]; then
    printf 'cannot resolve root %s' "$root"; return 1
  fi
  target_phys="$(realpath -- "$target" 2>/dev/null || true)"
  if [[ -z "$target_phys" ]]; then
    printf 'cannot resolve %s' "$target"; return 1
  fi
  if [[ "$target_phys" != "$root_phys" && "$target_phys" != "$root_phys"/* ]]; then
    printf 'resolves outside %s' "$root"; return 1
  fi
  return 0
}

# Every helper a security gate depends on, for the sentinel check each script
# runs after sourcing. A missing one means the gate would not run at all.
REQUIRED_HELPERS=(has_unsafe_chars annot_text log_untrusted url_safe_or_reason
                  path_contained_or_reason
                  assert_safe_sha assert_safe_path assert_safe_ref)

assert_helpers_defined() {
  local fn
  for fn in "${REQUIRED_HELPERS[@]}"; do
    if ! declare -F "$fn" >/dev/null; then
      printf '::error::%s: common.sh did not define %s\n' "${0##*/}" "$fn"
      exit 1
    fi
  done
}

# SHA must be exactly 40 lowercase hex.
assert_safe_sha() {
  local sha="$1"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    die "sha is not a 40-char lowercase hex string: $sha"
  fi
}

# Ref must be a SHA, branch, tag or rev expression that cannot parse as a git option.
assert_safe_ref() {
  local r="$1"
  if [[ ! "$r" =~ ^[A-Za-z0-9][A-Za-z0-9._/~^-]*$ ]]; then
    die "base-ref is not a safe git ref: $r"
  fi
}

# Path must be relative, no .., safe chars only.
assert_safe_path() {
  local p="$1"
  assert_safe_string "path" "$p"
  if [[ "$p" == /* ]] || [[ "$p" == *".."* ]]; then
    die "path is absolute or contains '..': $p"
  fi
}

# ---- CLI validation helper -------------------------------------------------
# Runs `claude plugin validate <path>`, classifies pass/warn/fail, honours
# FAIL_ON_WARNINGS, records the result. Returns 0 on pass/warn, 1 on fail.
cli_validate() {
  local step="$1" subject="$2" path="$3"
  local out
  if out="$(claude plugin validate "$path" 2>&1)"; then
    log_untrusted "$out"
    if grep -qE '^⚠|passed with warnings' <<<"$out"; then
      if [[ "${FAIL_ON_WARNINGS:-false}" == "true" ]]; then
        error "$subject: warnings (fail-on-warnings is set)"
        record_result "$step" "fail" "$subject" "$out"
        return 1
      fi
      warn "$subject: warnings"
      record_result "$step" "warn" "$subject" "$out"
    else
      record_result "$step" "pass" "$subject" ""
    fi
    return 0
  fi
  error "$subject: claude plugin validate failed"
  log_untrusted "$out"
  record_result "$step" "fail" "$subject" "$out"
  return 1
}

