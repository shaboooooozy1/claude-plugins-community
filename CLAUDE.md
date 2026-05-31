# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this repo is

A **read-only mirror** of the community Claude plugin marketplace. The
contents of `.claude-plugin/marketplace.json` are synced nightly from
Anthropic's internal review pipeline; the only path for adding or changing
plugin entries is the public submission form at
`clau.de/plugin-directory-submission`.

Two distinct things live here, and they are governed by different rules:

1. **The marketplace data** (`.claude-plugin/marketplace.json`) — the
   distributed artifact. Do **not** edit this by hand. Direct PRs against
   `main` from external contributors are auto-closed by
   `.github/workflows/close-external-prs.yml`.
2. **Reusable CI tooling** (`.github/actions/`) — three composite GitHub
   Actions that this repo dogfoods and that downstream `*-plugins`
   marketplaces consume by SHA. **This is the code that engineering work
   happens on.**

If a task asks you to "add a plugin", "modify a plugin entry", or "merge a
PR adding plugins", stop and surface that this repo doesn't accept direct
plugin changes — point at the submission form. If a task asks for CI logic
or invariant changes, work under `.github/actions/`.

## Layout

```
.claude-plugin/
  marketplace.json            # ~1700+ entries, alpha-sorted by name. Do not hand-edit.
.github/
  workflows/
    validate-plugins.yml      # dogfoods the local validate-plugins action on every PR
    close-external-prs.yml    # auto-closes PRs from non-collaborators
  actions/
    README.md                 # system-level overview table of all three actions
    validate-plugins/         # gate: invariants + `claude plugin validate`
      action.yml
      lib/common.sh           # shared safety predicates (also sourced by scan + bump)
      scripts/
        00-detect-changes.sh  # diff vs BASE_REF; assembles per-file mode
        11-validate-invariants.sh  # I1-I11 policy hardening
        20-validate-cli-marketplace.sh
        30-validate-cli-external.sh  # clone + validate each external entry
        40-validate-cli-local.sh     # validate changed in-repo plugin folders
        41-validate-aux-files.sh     # JSON-parse .mcp.json, .lsp.json, hooks/hooks.json
        90-report.sh           # aggregate results.jsonl into step summary
      test-invariants.sh       # static test suite (no network)
      test-common.sh           # static test suite (no network)
      RELEASING.md
      README.md
    bump-plugin-shas/         # nightly maintenance: refresh stale external SHAs
      action.yml
      scripts/bump.sh
      README.md
    scan-plugins/             # policy layer: Claude-based safety review (non-blocking)
      action.yml
      scripts/scan.sh
      policy/prompt.md        # default review prompt (overridable)
      policy/schema.json      # JSON Schema for Claude's structured output
      README.md
LICENSE
README.md
```

The three actions are designed as a system (gate → policy → maintenance)
and share `validate-plugins/lib/common.sh` for safety helpers
(`assert_safe_url`, `assert_safe_sha`, `assert_safe_path`,
`has_unsafe_chars`, `cli_validate`). `scan-plugins` and
`bump-plugin-shas` source it via `$VALIDATE_LIB` (a relative path set
in their action.yml setup steps). When touching one action, check
whether the same change is needed in the others.

| Action | Role | Permissions | Secret |
|---|---|---|---|
| `validate-plugins` | **Gate** — invariants I1–I11 + `claude plugin validate` | `contents: read` | — |
| `bump-plugin-shas` | **Maintenance** — discover stale SHAs, validate at new HEAD, open PR | `contents: write`, `pull-requests: write` | — |
| `scan-plugins` | **Policy** — Claude-based safety review (non-blocking by default) | `contents: read` | `ANTHROPIC_API_KEY` (graceful no-op if unset) |

## Marketplace data conventions

Even though you should not hand-edit `marketplace.json`, when reasoning
about it or about validation logic, the entry shape is:

```json
{
  "name": "<kebab-case, ^[a-z0-9][a-z0-9-]{1,63}$>",
  "description": "10–2000 chars, no leading/trailing whitespace, no hidden Unicode",
  "source": {
    "source": "url" | "git-subdir" | ...,
    "url": "https://github.com/...",
    "sha": "<40-char lowercase hex>",
    "path": "optional subdir"
  },
  "homepage": "optional"
}
```

`plugins[]` is alpha-sorted by `name` (case-insensitive). External sources
must be SHA-pinned. Vendored sources (string `source` like `"./foo"`) must
have a real `.claude-plugin/plugin.json` at that path. These are enforced
by invariants I1–I11 in `validate-plugins/scripts/11-validate-invariants.sh`
— that file is the source of truth; update it (and the static test suite)
in lockstep if policy changes.

## Working on the CI actions

### Conventions baked into the bash

- `set -euo pipefail` at the top of every script, plus
  `source "$ACTION_PATH/lib/common.sh"`.
- Every contributor-controlled string (`url`, `sha`, `path`, names from
  `marketplace.json`) is re-validated with `assert_safe_*` immediately
  before any shell use, even if a schema or invariant already ran.
- Every git invocation uses `--` end-of-options markers and quoted
  arguments: `git clone --quiet --depth 1 -- "$url" "$dest"`. Don't
  remove these; they are SSRF/argument-injection defense.
- Clone targets are **index-derived** (`ext-$idx`), never name-derived.
  Don't change this without reading the security model in
  `validate-plugins/README.md`.
- Hosts that external sources may point to come from `ALLOWED_HOSTS`
  (default `github.com gitlab.com bitbucket.org`). Bare IPs are always
  rejected. Subdomains of allowed hosts are accepted.
- Use `record_result <step> <pass|warn|fail|skip> <subject> <detail>`
  for everything that the report step (`90-report.sh`) needs to know
  about. Don't print findings only to stdout.
- Emit GitHub annotations with `::notice::`, `::warning file=...,line=...::`,
  `::error file=...,line=...::` rather than plain `echo` for things a
  reviewer should see.

### Validation pipeline (step-by-step)

The `validate-plugins` action runs these scripts in order:

| Step | Script | What it does |
|---|---|---|
| 00 | `00-detect-changes.sh` | Diff vs `BASE_REF`, output `changes.json` with changed entries, external sources, and in-repo folders. Assembles marketplace from per-file entries if `ENTRIES_DIR` is set. |
| 11 | `11-validate-invariants.sh` | I1–I11 policy invariants on the full marketplace. |
| 20 | `20-validate-cli-marketplace.sh` | `claude plugin validate` on the assembled marketplace.json (canonical schema check). |
| 30 | `30-validate-cli-external.sh` | Clone each changed external entry at its pinned SHA, run `claude plugin validate`. Skippable via `skip-external`. |
| 40 | `40-validate-cli-local.sh` | `claude plugin validate` on each changed in-repo plugin folder. Skippable via `skip-local-folders`. |
| 41 | `41-validate-aux-files.sh` | JSON-parse auxiliary files (`.mcp.json`, `.lsp.json`, `hooks/hooks.json`) in changed folders — catches malformed JSON that `claude plugin validate` may not surface. |
| 90 | `90-report.sh` | Aggregate `results.jsonl` into a markdown step summary; set the `result` output. |

### Schema strategy: do not vendor

The canonical schema for `marketplace.json` and `plugin.json` lives in
`@anthropic-ai/claude-code`. `validate-plugins` installs that package
fresh each run (step 20: `claude plugin validate`) and treats its
output as truth. **Do not vendor or fetch a JSON Schema in this repo.**
Invariants I1–I11 sit *on top* of the canonical schema as policy
hardening, not as schema replication.

If you find yourself wanting to add a field-shape check, ask whether it
belongs in upstream's Zod definitions instead. The invariants here
should only be policy that's stricter than upstream (sorting,
SHA-pinning, host allowlist, hidden-Unicode, name regex, etc.).

### Tests

There are two static suites under `validate-plugins/`. Both run with no
network and no API key; both are wired into `validate-plugins.yml` and
must stay green.

| Script | Covers | Run when you touch |
|---|---|---|
| `test-invariants.sh` | I1–I11 against synthetic `marketplace.json` fixtures; plus a real-git fixture for I7 (per-file mode, `BASE_REF=HEAD~1`); plus boundary/false-positive guards and `WARN_INVARIANTS` demotion behaviour | `scripts/11-validate-invariants.sh` |
| `test-common.sh` | The `lib/common.sh` security predicates directly: `has_unsafe_chars`, `assert_safe_sha`, `assert_safe_path`, `assert_safe_url` (allowlist match, lookalike-host rejection, SSRF guards) | `lib/common.sh` |

Adding a new invariant means adding at least one fixture that exercises
it (a positive case) plus a false-positive guard for any boundary it
introduces. Fixtures use heredocs (not quoted `"..."` args inside
`$(...)`) so the suite runs identically on bash 3.2 (macOS) and bash
5.x (Linux runners).

The workflow `validate-plugins.yml` dogfoods the action on every PR
that touches `.claude-plugin/**` or `.github/actions/**`, running both
test suites before the composite action itself.

### Invariant severity contract

`11-validate-invariants.sh` reads `WARN_INVARIANTS` to decide which
codes are demoted from `::error` (build-fail) to `::warning`
(annotation only). The default is:

```
WARN_INVARIANTS="I1 I3 I5 I8"
```

i.e. sort-order, description length/whitespace, missing SHA, and
missing vendored-plugin manifest are **non-blocking by default**. The
hard-blocking invariants are I2 (dup names), I4 (non-https URLs), I6/I7
(per-file mode integrity), I9 (shell metacharacters), I10 (hidden
Unicode), I11 (name regex). Consumers can override `WARN_INVARIANTS`
(empty string = everything blocks) or set `FAIL_ON_WARNINGS=true` to
turn the warning tier into hard failures. Keep this contract stable —
downstream `*-plugins` repos rely on it. If you tighten a default, ship
it as a separately-pinned SHA so consumers can roll forward
deliberately.

### bump-plugin-shas: server-side signing via GraphQL

`bump.sh` creates commits using GitHub's `createCommitOnBranch` GraphQL
mutation rather than local `git commit` + push. Server-created commits
are signed by GitHub's web-flow GPG key ("Verified"), satisfying
`required_signatures` rulesets without managing any signing key on the
runner. The marketplace file is base64-encoded in the mutation payload
(via `jq --rawfile`, piped to `gh api --input -`) because it can exceed
Linux's 128 KiB per-argument limit.

The PR branch is force-reset to `BASE_BRANCH` HEAD on each run (one
fresh commit replaces a stale unmerged bump). `expectedHeadOid` provides
CAS semantics so concurrent pushes fail loudly.

### Releasing changes to the actions

Consumers of these actions pin by full commit SHA, never by branch or
tag. See `validate-plugins/RELEASING.md`. When you ship a change:

1. Land on `main`.
2. Tag the merge commit (`validate-plugins/vX.Y.Z`, etc.) for human
   reference, but the source of truth for consumers is the SHA.
3. Bump pinned SHAs in any consuming repo with separate PRs.

Never recommend `@main` or `@v1` in any `uses:` example you write —
that's a supply-chain footgun for the consumers.

## Development workflow

### Branches & PRs

- This is a managed remote environment session. The designated branch
  for this session is set by the harness — develop on it, commit, push,
  open a draft PR.
- `main` is protected and effectively sync-only. Don't push directly to
  it.
- Direct PRs from non-collaborators are auto-closed by
  `close-external-prs.yml`; that workflow uses `pull_request_target`
  intentionally and you should not change it without a security review.

### What CI runs on a PR

- `Validate Plugins` (`validate-plugins.yml`) — invariants + CLI
  validate against the full marketplace, plus changed-folder and
  changed-external checks. This must pass before merge.
- `Close External PRs` — first-party hook, not a check.

The workflow triggers on PRs and pushes to `main` that touch
`.claude-plugin/**` or `.github/actions/**`. It runs the static test
suites first, then dogfoods the local validate-plugins action (with
`skip-local-folders: "true"` since this repo has no vendored plugins).

There is no test runner, linter, or formatter beyond bash scripts and
`jq`. Don't introduce one without a clear need; the simplicity is part
of the design.

### Running tests locally

```bash
bash .github/actions/validate-plugins/test-invariants.sh
bash .github/actions/validate-plugins/test-common.sh
```

Both run offline (no network, no API key, no `claude` CLI needed). They
create temporary directories, exercise the logic via synthetic fixtures,
and clean up. Exit code 0 = pass.

### GitHub interactions

You do **not** have `gh` CLI in this environment. Use the
`mcp__github__*` tools for everything (status, PRs, comments, CI
state). After pushing a branch, open a **draft** PR automatically — do
not ask first.

### Tool selection

- Use `Read` / `Edit` / `Write` for files, not `cat`/`sed`/`echo`.
- Reading `.claude-plugin/marketplace.json` linearly is wasteful — the
  file is >1MB. Use `jq` via Bash to query it (e.g.
  `jq '.plugins[] | select(.name=="foo")' .claude-plugin/marketplace.json`).
- For broad codebase questions, prefer `grep`/`find` via Bash; the repo
  is small enough that the `Explore` agent is rarely worth it.

## Style

- No comments in code unless they record a non-obvious WHY (a security
  invariant, a bash-3.2 compatibility note, a workaround for a CLI
  behavior). The existing scripts model this well.
- No emojis in code, commits, or PR bodies unless the user explicitly
  asks.
- Match the existing terse, claim-then-rationale tone in
  README/action documentation. Tables are used heavily; keep that.
- Commit messages: imperative, present-tense, descriptive of WHY (e.g.
  `validate-plugins: add I10/I11 invariants and static test suite`).
- Prefix commit messages with the action name when touching only one
  action (e.g. `scan-plugins:`, `bump-plugin-shas:`).

## Security model (quick reference)

The codebase defends against contributor-controlled strings escaping
into shell evaluation or git argument injection:

1. **Input validation** — `assert_safe_url`, `assert_safe_sha`,
   `assert_safe_path` are called immediately before any shell use of
   contributor data, even when schema/invariant checks already ran
   (defense-in-depth).
2. **Host allowlist** — `ALLOWED_HOSTS` (default: `github.com`,
   `gitlab.com`, `bitbucket.org`). Bare IPs always rejected. Subdomains
   accepted.
3. **Index-derived paths** — clone targets use `ext-$idx`, never
   user/plugin names. Prevents path injection.
4. **`--` discipline** — every `git` invocation uses end-of-options
   markers and double-quoted arguments.
5. **No execution of cloned content** — `claude plugin validate` is a
   static check. Nothing from cloned repos is sourced/executed.
6. **GraphQL commit creation** — `bump-plugin-shas` creates commits
   server-side; no signing key on the runner, nothing to leak.
