#!/usr/bin/env bash
# Cloud Agent install: idempotent, non-interactive dependency setup.
# The engineering surface of this repo is the CI tooling under
# .github/actions/. Its two static test suites need only bash + jq (both in
# the base image). We additionally install the `claude` CLI so agents can run
# the full validation pipeline locally (`claude plugin validate`, the
# source-of-truth schema check the validate-plugins action shells out to).
set -euo pipefail

# jq: used by the validate scripts and for querying the >1MB marketplace.json.
if ! command -v jq >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends jq
fi

# claude CLI: canonical marketplace/plugin schema check. Installed to a
# user-writable npm prefix, then symlinked onto /usr/local/bin (on PATH for
# every shell) since the published binary is self-contained.
NPM_PREFIX="$HOME/.npm-global"
npm config set prefix "$NPM_PREFIX"
npm install -g @anthropic-ai/claude-code@latest

CLAUDE_BIN="$NPM_PREFIX/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
if [ ! -e "$CLAUDE_BIN" ]; then
  # Older/alternate layouts expose the launcher directly under bin/.
  CLAUDE_BIN="$NPM_PREFIX/bin/claude"
fi
sudo ln -sf "$CLAUDE_BIN" /usr/local/bin/claude

# The action's Setup step normally chmods these; do it here so agents can run
# the scripts directly without the composite action wrapper.
chmod +x .github/actions/*/scripts/*.sh .github/actions/validate-plugins/lib/*.sh 2>/dev/null || true

echo "jq:     $(jq --version)"
echo "claude: $(claude --version)"
