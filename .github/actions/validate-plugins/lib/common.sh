#!/usr/bin/env bash
# Shared helpers for validate-plugins action scripts.
# Source this at the top of every script: source "$ACTION_PATH/lib/common.sh"

set -euo pipefail

# ---- logging ---------------------------------------------------------------

log()   { printf '%s\n' "$*"; }
info()  { printf '::notice::%s\n' "$*"; }
warn()  { printf '::warning::%s\n' "$*"; }
error() { printf '::error::%s\n' "$*"; }
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

assert_safe_string() {
  local label="$1" value="$2"
  if has_unsafe_chars "$value"; then
    die "$label contains unsafe characters: $value"
  fi
}

# URL must be https://<allowed-host>/<safe-chars> only.
# Host must be in ALLOWED_HOSTS (space-separated) and must not be a bare IP.
# SSRF guard: prevents cloning from metadata endpoints / internal ranges.
assert_safe_url() {
  local url="$1"
  assert_safe_string "url" "$url"
  if [[ ! "$url" =~ ^https://[A-Za-z0-9./_-]+$ ]]; then
    die "url does not match ^https://[A-Za-z0-9./_-]+\$ : $url"
  fi
  local host="${url#https://}"
  host="${host%%/*}"
  if [[ "$host" =~ ^[0-9.]+$ ]] || [[ "$host" =~ : ]]; then
    die "url host is a bare IP address (not permitted): $host"
  fi
  : "${ALLOWED_HOSTS:?ALLOWED_HOSTS must be set (action.yml provides the default)}"
  local allowed="$ALLOWED_HOSTS"
  local ok=""
  for h in $allowed; do
    if [[ "$host" == "$h" ]] || [[ "$host" == *".$h" ]]; then
      ok=1; break
    fi
  done
  if [[ -z "$ok" ]]; then
    die "url host '$host' is not in the allowlist ($allowed)"
  fi
}

# SHA must be exactly 40 lowercase hex.
assert_safe_sha() {
  local sha="$1"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    die "sha is not a 40-char lowercase hex string: $sha"
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
    log "$out"
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
  log "$out"
  record_result "$step" "fail" "$subject" "$out"
  return 1
}

