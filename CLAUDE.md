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
.cursor/
  environment.json            # Cloud Agent env: runs install.sh
  install.sh                  # idempotent: jq + the pinned claude CLI, chmod the scripts
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
.gitignore                    # validate scratch dir, *.json.tmp, env files, key material
LICENSE
README.md
```

The three actions are designed as a system (gate → policy → maintenance)
and share `validate-plugins/lib/common.sh` for safety helpers.
`scan-plugins` and `bump-plugin-shas` source it via `$VALIDATE_LIB` (a
relative path set in their action.yml setup steps). When touching one
action, check whether the same change is needed in the others — every
duplicated predicate in this codebase has eventually drifted.

| Helper | Shape | What it is for |
|---|---|---|
| `has_unsafe_chars` | 0 = unsafe | Character check: shell metacharacters plus whitespace, including newline and CR. The base of the other string predicates. |
| `assert_safe_string` | dies | Wraps `has_unsafe_chars`. `assert_safe_path` delegates to it. |
| `url_safe_or_reason` | **0 = safe**, reason on stdout | The one URL implementation: https only, safe charset, bare IP or port rejected regardless of `ALLOWED_HOSTS`, then the allowlist. Empty `ALLOWED_HOSTS` fails closed. |
| `assert_safe_url` | dies | Asserting wrapper around `url_safe_or_reason`. |
| `assert_safe_sha` / `assert_safe_path` / `assert_safe_ref` | die | 40-hex sha; relative path with no `..`; a git ref that cannot parse as an option. |
| `annot_text` | echoes | Flattens CR/LF and caps length for text interpolated **into** a `::workflow-command` line. |
| `log_untrusted` | prints | For plugin/model/CLI text printed **as** whole lines: indents every line so none can begin with `::`. |
| `assert_helpers_defined` | exits 1 | Checks `REQUIRED_HELPERS`, every helper a security gate depends on. Both standalone actions call it after sourcing. |
| `path_contained_or_reason` | **0 = contained**, reason on stdout | The one physical-containment implementation: resolves both paths and requires the target to be the root or below it. Every lexical path check is followed by something that resolves symlinks, so anything deciding *what gets read* must call this — on the plugin root as well as the manifest, since a root symlinked out whose manifest symlinks back in passes a manifest-only test. |
| `step_begin` / `step_done` / `incomplete_steps` | mark / mark / echo | Step-completion tracking for `90-report.sh`. Each step marks itself begun on entry and done only on a zero exit (via an `EXIT` trap), so a step killed part-way is visible. Without it a step that aborts before recording anything leaves a results file full of passes and the report announces PASS. |
| `cli_validate` | 0/1 | Runs `claude plugin validate`, classifies pass/warn/fail, honours `FAIL_ON_WARNINGS`. |

Note the polarity split. `has_unsafe_chars` returns 0 for *unsafe*, but
`url_safe_or_reason` returns 0 for *safe*, deliberately: its callers gate on
success, so a failure of the function itself (an older `common.sh` where it is
undefined) must land on the reject side rather than being waved through. Add
new URL rules to `url_safe_or_reason`, not to `assert_safe_url`, and add any
new gate dependency to `REQUIRED_HELPERS`.

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
  `source "$ACTION_PATH/lib/common.sh"`. `scan.sh` and `bump.sh` source
  `$VALIDATE_LIB` instead, then call `assert_helpers_defined` before
  anything else so a stale library cannot silently drop a gate.
- Every step marks itself with `step_begin` on entry and `step_done` from
  an `EXIT` trap that fires only on a zero exit. A step that already owns
  a trap (step 30 cleans up its clone workroot) **re-arms** it rather than
  replacing it; a bare `trap ... EXIT` there would drop the completion
  handler and the step would never read as finished.
- Every contributor-controlled string (`url`, `sha`, `path`, names from
  `marketplace.json`, `BASE_REF`) is re-validated immediately before any
  shell use, even if a schema or invariant already ran. Two forms, by
  context: top-level code uses the asserting `assert_safe_*` helpers and
  dies; a per-entry loop (step 30, `scan.sh`, `bump.sh`) uses the
  non-fatal `*_or_reason` helpers, records the rejection with
  `record_result` or `skipped`, and `continue`s. One off-allowlist entry
  must not end a sweep over the other 1700.
- Every git invocation uses `--` end-of-options markers and quoted
  arguments: `git clone --quiet --depth 1 -- "$url" "$dest"`. `BASE_REF`
  goes through `assert_safe_ref` before `fetch`/`diff`/`show`. Don't
  remove these; they are SSRF/argument-injection defense.
- Clone targets are **index-derived** (`ext-$idx`), never name-derived.
  Don't change this without reading the security model in
  `validate-plugins/README.md`.
- Anything that decides **what gets read** goes through
  `path_contained_or_reason`, but the scope differs by step and you must
  not assume more than each one does. Steps 30 and 40 and `bump.sh` test
  the manifest with `-L` and then check both the plugin root and the
  manifest. Step 11 checks the vendored root and manifest for
  containment but has no `-L` test, so a manifest symlink that resolves
  *inside* the workspace passes. Step 41 checks the changed folder and
  each aux file (`-L` plus containment), not the manifest. `scan.sh`
  resolves only its `cd` target against the clone, with an inline
  `realpath` comparison rather than the shared helper, and has no
  manifest guard. Lexical checks (`-f`, `..`, leading `/`) are never
  enough on their own because every one of them is followed by something
  that resolves symlinks.
- Hosts that external sources may point to come from `ALLOWED_HOSTS`
  (default `github.com gitlab.com bitbucket.org`). Bare IPs are always
  rejected. Subdomains of allowed hosts are accepted.
- Use `record_result <step> <pass|warn|fail|skip> <subject> <detail>`
  for everything that the report step (`90-report.sh`) needs to know
  about. Don't print findings only to stdout.
- Emit GitHub annotations with `::notice::`, `::warning file=...,line=...::`,
  `::error file=...,line=...::` rather than plain `echo` for things a
  reviewer should see. Untrusted text has two sinks and you must pick
  the right one: interpolated **into** a command line it goes through
  `annot_text` (automatic inside `warn`/`error`; call it yourself for a
  bare `printf '::warning ...'`); printed **as** whole lines (validator
  output, a model's raw verdict, a changed-file list) it goes through
  `log_untrusted`, because a line that merely *begins* with `::` is a
  command even after newlines are flattened. Markdown report cells go
  through one jq `cell` filter that strips CR, LF and `|`; it is copied
  verbatim in `90-report.sh`, `scan.sh` and `bump.sh` and must stay
  identical.
- **Character-level tests on plugin text belong in `jq`, not in bash or
  `sed`.** Bash glob bracket expressions and `${#s}` are character-aware only
  in a multibyte locale and fall back to bytes under `LC_ALL=C`, which is what
  a `container:` job or a self-hosted runner with no locale set gets; `sed`
  anchors `^`/`$` per line, not per string. Both produced silent false
  positives here, one of them on a blocking invariant. `jq` decodes JSON to
  codepoints, so it behaves identically on every runner. Anchor any regex you
  write there with Oniguruma escapes (`\x{a0}`), not `\uXXXX` — jq resolves
  `\uXXXX` in a string literal, but a string that *is* a regex needs an escape
  the regex engine understands, and `\u` silently degrades into a character
  range spanning most of ASCII.

### Validation pipeline (step-by-step)

The `validate-plugins` action runs these scripts in order:

| Step | Script | What it does |
|---|---|---|
| 00 | `00-detect-changes.sh` | `assert_safe_ref` on `BASE_REF`, then diff against it and output `changes.json` with changed entries, external sources, and in-repo folders. If the diff itself fails, per-file entries fall back to *every* entry, but single-file entries are still computed by comparing the base marketplace to the head, so when the base is readable unchanged external entries stay out of the sweep. Assembles marketplace from per-file entries if `ENTRIES_DIR` is set. |
| 11 | `11-validate-invariants.sh` | I1–I11 policy invariants on the full marketplace. I3/I10 are computed in `jq` (see conventions). I7 fails closed when `git diff` against `BASE_REF` errors. I9 also covers vendored-source containment (see severity contract). |
| 20 | `20-validate-cli-marketplace.sh` | `claude plugin validate` on the assembled marketplace.json (canonical schema check). |
| 30 | `30-validate-cli-external.sh` | For each changed external entry: reject-and-continue on a bad URL, sha or path; clone at the pinned SHA; reject a symlinked manifest or a root/manifest that resolves outside the clone; run `claude plugin validate`. Skippable via `skip-external`. |
| 40 | `40-validate-cli-local.sh` | For each changed in-repo plugin folder: the same symlink and containment guard against the workspace root (this runs **before** 41 and step 00 selects folders with `-f`, which follows symlinks), then `claude plugin validate`. Skippable via `skip-local-folders`. |
| 41 | `41-validate-aux-files.sh` | JSON-parse auxiliary files (`.mcp.json`, `.lsp.json`, `hooks/hooks.json`) in changed folders — catches malformed JSON that `claude plugin validate` may not surface. Containment is physical, so an ancestor symlink (`hooks/ -> /etc`) is caught, not just a leaf `-L`. |
| 90 | `90-report.sh` | Aggregate `results.jsonl` into a markdown step summary; set the `result` output. Runs `if: always()` and fails the run on a missing, empty or unparseable results file **and** on any step that began but did not finish. |

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
| `test-invariants.sh` | I1–I11 against synthetic `marketplace.json` fixtures; plus a real-git fixture for I7 (per-file mode, `BASE_REF=HEAD~1`); plus boundary/false-positive guards and `WARN_INVARIANTS` demotion behaviour; plus locale guards for I3/I10 (each asserted under both `LC_ALL=C` and `LC_ALL=C.utf8`) and whole-string-vs-per-line anchor guards for I3's whitespace rule | `scripts/11-validate-invariants.sh` |
| `test-common.sh` | The `lib/common.sh` security predicates directly: `has_unsafe_chars`, `annot_text`, the `warn`/`error`/`log_untrusted` sinks, `assert_safe_sha`, `assert_safe_path`, `assert_safe_ref`, `assert_safe_url` and `url_safe_or_reason` (allowlist match, lookalike-host rejection, SSRF guards, bare IP rejected even when allowlisted, missing helper rejects), `assert_helpers_defined`, `path_contained_or_reason`, and the step-completion helpers including the `EXIT`-trap shape each step installs | `lib/common.sh` |

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
(per-file mode integrity; I7 also fails when it *cannot* diff against
`BASE_REF`, rather than passing), I9, I10 (hidden Unicode), I11 (name
regex).

I9 is wider than its one-line name. It blocks on: shell metacharacters,
including newline and CR, in **any** string field under `.source`; a
`source.path` that is absolute or contains `..`; an absolute vendored
source; and a vendored source root or its manifest that **resolves**
outside the workspace. That last case is deliberately I9 rather than I8:
a path escape has to block, and I8 is warn-by-default. The containment
check is guarded on the path existing, so a plain typo in a vendored
path (or a dangling symlink) still lands on warn-tier I8 and the
severity contract holds.

Consumers can override `WARN_INVARIANTS` (empty string = everything
blocks) or set `FAIL_ON_WARNINGS=true` to turn the warning tier into
hard failures. Keep this contract stable — downstream `*-plugins` repos
rely on it. If you tighten a default, ship it as a separately-pinned SHA
so consumers can roll forward deliberately.

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

It has no `entries-dir` input and rewrites the assembled
`marketplace.json`, which is exactly what I7 blocks in a per-file repo.
Do not wire it into one; its README says why.

### scan-plugins: contract and isolation

`scan.sh` runs `claude -p` against each changed external entry with
`--bare --restricted --strict-mcp-config` and stdin from `/dev/null`, so
the clone's `.claude/settings*.json`, hooks, `CLAUDE.md` and `.mcp.json`
are review *material* rather than configuration, and the file tools are
confined to the clone. The scan `cd`s into the resolved target, not the
lexical `source.path`; note that this is an inline `realpath` comparison
against the clone rather than `path_contained_or_reason`, and nothing
checks the manifest. `claude-cli-version` is pinned in its `action.yml`
(not `latest`) because those flags are version-dependent.

Because it runs standalone and never sees step 11, it re-checks each
entry name's type and the I11 regex itself. The outputs are always JSON
arrays, `[]` on the no-API-key path: `scanned`, `failed`, and `skipped`
(`{name, reason}` for every target it could not reach — invalid name,
missing sha, blocked host, clone failure, unparseable verdict). `result`
is `pass`, `fail` or `skipped` and reports the true scan outcome: a
policy failure **or** an unscanned target is `fail` even when the job is
non-blocking, so gating on `result == 'pass'` fails closed.
`FAIL_ON_FINDINGS=true` then means "fail the job unless the scan came
back clean", on either count.

### Releasing changes to the actions

Consumers of these actions pin by full commit SHA, never by branch or
tag. See `validate-plugins/RELEASING.md`. When you ship a change:

1. Land on `main`.
2. Tag the merge commit (`validate-plugins/vX.Y.Z`, etc.) for human
   reference, but the source of truth for consumers is the SHA.
3. Bump pinned SHAs in any consuming repo with separate PRs.

Never recommend `@main` or `@v1` in any `uses:` example you write —
that's a supply-chain footgun for the consumers. The same rule applies
inside this repo: every `uses:` in `.github/` is pinned to a commit SHA
with the tag in a trailing comment.

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
`skip-local-folders: "true"` since this repo has no vendored plugins,
and an explicit `claude-cli-version` — the action's own default is
`latest`, so this repo pins it in the workflow instead).

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

To run the full pipeline (steps 20–41 need the `claude` CLI),
`bash .cursor/install.sh` installs `jq` and the same pinned CLI version
the workflow uses, and chmods the scripts so they run without the
composite-action wrapper.

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
into shell evaluation, git argument injection, GitHub workflow commands,
or reads outside the checkout — and against a gate that silently
degrades into a pass:

1. **Input validation** — `assert_safe_url`, `assert_safe_sha`,
   `assert_safe_path`, `assert_safe_ref` immediately before any shell
   use of contributor data, even when schema/invariant checks already
   ran (defense-in-depth). Per-entry loops use the non-fatal
   `url_safe_or_reason` / `path_contained_or_reason` forms and skip the
   entry instead of aborting the sweep.
2. **Host allowlist** — `ALLOWED_HOSTS` (default: `github.com`,
   `gitlab.com`, `bitbucket.org`). Bare IPs and ports are rejected
   *before* and independently of the allowlist, so an operator cannot
   open a metadata endpoint by listing it. Empty allowlist fails closed.
   Subdomains accepted.
3. **Index-derived paths** — clone targets use `ext-$idx`, never
   user/plugin names. Prevents path injection.
4. **`--` discipline** — every `git` invocation uses end-of-options
   markers and double-quoted arguments.
5. **Physical containment** — `path_contained_or_reason` wherever a
   path decides what gets read, with per-step scope: root and manifest
   in steps 11/30/40 and `bump.sh`; folder and aux files in step 41; the
   `cd` target only in `scan.sh` (an inline `realpath` check, no
   manifest guard). Steps 30/40 and `bump.sh` also reject a symlinked
   manifest outright; step 11 does not.
6. **No forged workflow commands** — `annot_text` at the `warn`/`error`
   sink, `log_untrusted` for whole-line output, and one escaped-cell
   filter for every markdown report. A plugin name, ref, or model
   verdict cannot start a `::error::` line or forge a `Result: PASS`.
7. **No execution of cloned content** — `claude plugin validate` is a
   static check. `scan.sh` isolates `claude -p` with `--bare --restricted
   --strict-mcp-config` so the clone's settings, hooks and MCP config are
   never loaded. Nothing from cloned repos is sourced/executed.
8. **Fail closed** — `assert_helpers_defined` after sourcing; I7 fails
   when it cannot diff; `90-report.sh` fails on a missing/empty results
   file or an unfinished step; `scan.sh` reports `result=fail` for any
   target it could not scan.
9. **GraphQL commit creation** — `bump-plugin-shas` creates commits
   server-side; no signing key on the runner, nothing to leak.
10. **Pinned supply chain** — every `uses:` in `.github/` is pinned to
    a commit SHA; `scan-plugins` pins `claude-cli-version` by default;
    this repo's workflow pins it for `validate-plugins` too.
