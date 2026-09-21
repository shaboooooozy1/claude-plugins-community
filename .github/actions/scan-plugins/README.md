# scan-plugins

Claude-based policy/safety scan of changed external marketplace entries.
Companion to [`validate-plugins`](../validate-plugins/) and
[`bump-plugin-shas`](../bump-plugin-shas/).

**Non-blocking by default.** Findings surface as `::warning` annotations and a
step-summary table. Set `fail-on-findings: true` to make the job fail whenever
the scan did not come back clean, which covers both a policy failure and a
target that could not be scanned.

**Bot-free.** Needs only an `ANTHROPIC_API_KEY` secret (org or repo level). If
the secret is unset, the action skips gracefully — so you can add the workflow
everywhere and roll the secret out incrementally.

## The policy prompt

The bundled [`policy/prompt.md`](policy/prompt.md) is **intentionally
minimal** — it cites the public Software Directory Policy and Acceptable Use
Policy and asks for a pass/fail verdict, without enumerating specific
detection heuristics.

Organizations running this action should maintain a more detailed prompt in a
**private** location (so detection logic and regression fixtures aren't
published alongside the deployed scanner) and pass it via the `policy-prompt`
input:

```yaml
      - uses: anthropics/claude-plugins-community/.github/actions/scan-plugins@<PINNED-SHA>
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          policy-prompt: .github/policy/prompt.md   # repo-local, synced from private source
```

The verdict shape is in [`policy/schema.json`](policy/schema.json)
(`additionalProperties: true`, so a private prompt can add fields without
forking the action).

## What it does

1. Determines targets: external entries that changed vs `base-ref` (or all
   external entries if `scan-all-external: true`).
2. For each target: clone at the pinned SHA into an isolated temp dir (same
   SSRF allowlist, quoting, and `--` discipline as `validate-plugins`).
3. Run `claude -p` headless with the policy prompt and read-only file tools
   (`Read,Glob,Grep`), with `--bare --restricted --strict-mcp-config` so the
   clone's own hooks, `CLAUDE.md`, settings and `.mcp.json` are review
   material, not configuration.
4. Parse the JSON verdict; emit `::warning` (or `::error` if
   `fail-on-findings`) annotations with line numbers into `marketplace.json`.
5. Write a step-summary table with passes/violations and the
   network-calls/software-install flags.

## Usage

> **Always pin to a commit SHA, never `@main`.** See `../validate-plugins/RELEASING.md`.

```yaml
# .github/workflows/scan-plugins.yml
name: Scan Plugins
on:
  pull_request:
    paths:
      - '.claude-plugin/**'

jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: anthropics/claude-plugins-community/.github/actions/scan-plugins@<PINNED-SHA>
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          # fail-on-findings: "true"   # uncomment to hard-block
```

`persist-credentials: false` keeps the job token out of
`$GITHUB_WORKSPACE/.git/config`. `pull_request` runs from forks receive no
secrets, so the scan is a no-op (`result: skipped`) there.

## Inputs

| Input | Default | |
|---|---|---|
| `anthropic-api-key` | `""` | if empty, the scan is skipped (graceful no-op) |
| `marketplace-path` | `.claude-plugin/marketplace.json` | |
| `base-ref` | PR base / push `before` / `origin/main` | |
| `fail-on-findings` | `false` | if true, the job fails unless the scan came back clean: any `passes:false` **or** any unscanned target |
| `scan-all-external` | `false` | nightly full-sweep mode |
| `policy-prompt` | bundled `policy/prompt.md` | override with a repo-local file |
| `allowed-hosts` | `github.com gitlab.com bitbucket.org` | SSRF allowlist |
| `claude-cli-version` | `2.1.278` | pinned; `--restricted` requires >= this version |
| `npm-registry` | `""` | optional internal mirror |
| `scan-timeout-secs` | `300` | per-plugin timeout |

## Outputs

| Output | |
|---|---|
| `scanned` | JSON array of full verdicts `{name, passes, summary, violations, may_make_external_network_calls, may_download_additional_software}` |
| `failed` | JSON array of plugin names with `passes:false` |
| `skipped` | JSON array of `{name, reason}` for targets that could not be scanned (unpinned entry, host not allowlisted, clone failure, unparseable verdict, …) |
| `result` | `pass` / `fail` / `skipped` |

All three arrays are always valid JSON, including on the no-key path, so a
consumer may `fromJSON` them unconditionally.

`result` is `skipped` whenever `anthropic-api-key` is empty (for example on
`pull_request` runs from forks, which receive no secrets). It is `pass` only
when every target was scanned and passed: a policy failure or an unscanned
target reports `fail` even though the job itself stays green unless
`fail-on-findings` is set. That split keeps the default non-blocking while
letting a consumer gate on `== 'pass'` (fail-closed) rather than `!= 'fail'`,
and it means a target the scanner could not reach is never mistaken for a
clean one.

## Isolation note

This runs as a step inside the calling job, so it shares that job's
`GITHUB_TOKEN`. The `claude -p` invocation is restricted to read-only file
tools (`Read,Glob,Grep`) and runs with:

- `--bare` — no hooks, no `CLAUDE.md` auto-discovery from the clone;
- `--restricted` — file tools confined to the clone, the clone's
  `.claude/settings*.json` ignored, command/network tools removed;
- `--strict-mcp-config` — the clone's `.mcp.json` is not loaded as MCP
  configuration (it remains readable as review material).

The prompt is constructed by this action, not by the plugin, and tells the
model that every file it reads is untrusted data. The verdict is still a model
judgement over submitter-controlled text and must not be a repo's sole
admission control. For repos accepting fully untrusted submissions, run this
action in a separate job with `permissions: {}` for stronger isolation — see
the consuming-workflow example above (already `contents: read` only).
