#!/usr/bin/env bash
# Run `claude plugin validate` on the full assembled marketplace.json.
# This is the canonical schema check — always current with the CLI.

source "$ACTION_PATH/lib/common.sh"

# Marks this step done only on a zero exit, so an abort part-way through
# (a die, or set -e on an unexpected error) leaves it begun-but-unfinished
# and 90-report.sh fails the run rather than aggregating to PASS.
STEP_ID=20-cli-marketplace
step_begin "$STEP_ID"
trap 'rc=$?; if [[ $rc -eq 0 ]]; then step_done "$STEP_ID"; fi' EXIT

: "${VALIDATE_TMP:?}"
MP="$VALIDATE_TMP/marketplace.json"

group_start "CLI: claude plugin validate (marketplace)"

command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH"

cli_validate "cli-marketplace" "marketplace.json" "$MP" || exit 1

group_end
