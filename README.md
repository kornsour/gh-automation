# gh-automation

Central, reusable GitHub Actions workflows shared across my repositories, so the
logic lives in one place instead of being copy-pasted into every repo.

> Historical/superseded docs and records for this repo live under
> [`archive/`](archive/). That folder reflects past decisions or state — it is
> not current, and should not be used to understand this repo or to inform new
> work.

## Scope

This repo works around a specific gap: GitHub **personal accounts** have no
org-level required workflows, org rulesets, or org-wide Actions/Dependabot
policy — every repo's settings are independent, so getting consistent, safe
dependency automation across many personal repos means stamping the same
config onto each one individually. That's what `scripts/rollout.sh` does, and
it's the reason this repo exists at all.

**If your repos live in a GitHub organization, don't use this pattern.**
Organizations can enforce reusable workflows and required status checks
centrally through organization-level rulesets and an org-wide Actions policy,
instead of stamping caller files and a ruleset onto every repo individually.
Reach for those first — this repo's per-repo approach is a personal-account
workaround, not a recommendation for org use.

## Versioning

Releases are tagged `vX.Y.Z` (immutable) with a floating major tag `vX` that's
moved to the latest `vX.y.z` on each release — the same convention most GitHub
Actions use. **Callers should pin to `@v1`**, not `@main`: `@main` changes the
instant a commit lands here, with no review step on the consumer's side, while
`@v1` only moves when a release is deliberately cut. `scripts/release.sh` cuts
releases; see its `--help` for usage.

## Workflows

All reusable workflows below default to GitHub-hosted runners. A repo can opt
into self-hosted runners by setting its `USE_SELF_HOSTED_RUNNER` repository
variable to `true` — but this only takes effect on **private** repos. A public
repo always runs on `ubuntu-latest`, because a fork PR on a public repo would
otherwise get arbitrary code execution on the runner.

### `ci.yml`
Standardized CI for template-derived Node/TypeScript repos: Biome lint/format,
type-check, unit tests (Vitest), build, an optional DB migration guard, and a
Semgrep security scan (blocks on ERROR-severity findings only) — one job per
check. Call it:

```yaml
# .github/workflows/ci.yml in a consuming repo
name: CI
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  ci:
    uses: lurking-walrus/gh-automation/.github/workflows/ci.yml@v1
    with:
      node-version: "24"          # optional
      migration-check: true       # optional, for repos with src/db/schema.ts
      security-scan: true         # optional, defaults to true
```

Required-check contexts: **`ci / Lint & format (Biome)`**, **`ci / Type check`**,
**`ci / Unit tests (Vitest)`**, **`ci / Build`** — plus **`ci / DB migration
check`** when `migration-check: true`.

### `auto-merge.yml`
Turns on GitHub auto-merge (squash by default) for every non-draft,
same-repository PR that Dependabot did not open, so a green PR lands without
anyone clicking Merge. GitHub still holds each PR until the default branch's
required checks pass, so the repo **must have required checks** — with none,
GitHub refuses to enable auto-merge rather than merging instantly. Fork PRs are
never auto-merged. Dependabot PRs are left to `dependabot-auto-merge.yml`.

```yaml
# .github/workflows/auto-merge.yml in a consuming repo
name: Auto-merge
on:
  pull_request:
    types: [opened, reopened, ready_for_review]
permissions:
  contents: write
  pull-requests: write
jobs:
  auto-merge:
    uses: lurking-walrus/gh-automation/.github/workflows/auto-merge.yml@<sha>
    with:
      require-token: true   # set where push workflows deploy or publish
    secrets:
      AUTOMERGE_TOKEN: ${{ secrets.AUTOMERGE_TOKEN }}
```

The repo also needs **Allow auto-merge** and **Always suggest updating pull
request branches** turned on (`gh api -X PATCH repos/OWNER/REPO -F
allow_auto_merge=true -F allow_update_branch=true`).

`AUTOMERGE_TOKEN` here is an **Actions** secret (the Dependabot workflow's is a
Dependabot secret; a repo that wants both stores the PAT twice). Without it the
merge is made with `GITHUB_TOKEN` and triggers no push workflows on main; with
`require-token: true` the job fails instead and the PR waits for a hand merge.

### `dependabot-auto-merge.yml`
Auto-merges Dependabot PRs — patch, minor **and major** — once the calling
repo's required status checks pass: green CI is the whole gate. A caller can
hold majors for manual review with `merge-majors: false`. By default it does
not hand the merge to GitHub's auto-merge: it waits for the required checks,
then merges itself under a per-repo lock after re-checking the lockfile
against the current base — see [The lockfile merge race](#the-lockfile-merge-race).
Call it:

```yaml
# .github/workflows/dependabot-auto-merge.yml in a consuming repo
name: Dependabot auto-merge
on:
  pull_request:
permissions:
  contents: write
  pull-requests: write
jobs:
  automerge:
    uses: lurking-walrus/gh-automation/.github/workflows/dependabot-auto-merge.yml@v1
    with:
      require-token: true        # fail rather than merge with GITHUB_TOKEN
      # merge-majors: false      # optional; hold majors for manual review
      # recheck-before-merge: true   # default; false = legacy `gh pr merge --auto`
      # working-directory: "."       # where the lockfile lives (pre-merge re-check)
      # ecosystems: auto             # as in lockfile-guard.yml
      # wait-timeout-minutes: 60     # how long to wait for required checks
    secrets:
      AUTOMERGE_TOKEN: ${{ secrets.AUTOMERGE_TOKEN }}
```

**Which token merges decides whether anything runs after the merge.** The
workflow merges with `AUTOMERGE_TOKEN` when it is set (in legacy mode GitHub
merges on behalf of whoever enabled auto-merge), and events caused by
`GITHUB_TOKEN` never start workflow runs. A merge made with `GITHUB_TOKEN`
therefore lands on `main` without triggering
that repo's `push` workflows: no CI run on `main`, no Pages deploy, no image
publish, no release. `AUTOMERGE_TOKEN` fixes that by attributing the merge to a
real identity. One-time setup per consuming repo:

1. Create a **fine-grained personal access token** (Settings → Developer
   settings → Personal access tokens → Fine-grained) scoped to the consuming
   repos, with repository permissions **Contents: read and write**, **Pull
   requests: read and write** and **Workflows: read and write** (needed because
   Dependabot PRs often edit `.github/workflows/*.yml`). A GitHub App
   installation token with the same permissions also works.
2. Store it as a **Dependabot secret** — not an Actions secret. The caller
   runs as `dependabot[bot]`, which can only read Dependabot secrets:

   ```bash
   gh secret set AUTOMERGE_TOKEN --app dependabot -R lurking-walrus/<repo>
   ```

Without the secret the workflow falls back to `GITHUB_TOKEN` and logs a
warning (`Running with GITHUB_TOKEN (no AUTOMERGE_TOKEN)`, and again at merge
time), so callers that predate it keep merging as before — but nothing runs
on `main` afterwards, including the lockfile backstop. `require-token:
true` turns that fallback into a failure, which is the right setting for any
repo whose `push` workflows matter; `scripts/rollout.sh` writes new callers
that way.

Do **not** pass `secrets: inherit`; pass `AUTOMERGE_TOKEN` by name. Inheriting
would hand the called workflow every secret in the calling repo for no benefit
— and the Semgrep step in `ci.yml` flags it as an ERROR-severity finding, which
blocks the caller's build.

### `lockfile-guard.yml`
Proves a repo's lockfile is well-formed and in sync with its manifest.
Ecosystem-detecting: one workflow serves pnpm, npm and uv repos, and a repo
with none of those lockfiles passes. Every check runs on whichever lockfiles
exist:

| Check | Applies to | Fails on |
| --- | --- | --- |
| Strict parse | `pnpm-lock.yaml`, `package-lock.json`, `uv.lock` | syntax errors, **duplicate mapping keys**, empty file, git conflict markers |
| `pnpm install --frozen-lockfile --lockfile-only` | pnpm | `package.json` / lockfile drift, anything pnpm itself calls `ERR_PNPM_BROKEN_LOCKFILE` |
| `npm ci --dry-run` | npm | `package.json` / `package-lock.json` drift |
| `uv lock --check` | uv | `pyproject.toml` / `uv.lock` drift |

It is **not skippable for any actor**: there is no `if:` on the actor, so
`dependabot[bot]` PRs are checked like every other (they are the main source
of lockfile corruption). On a `pull_request` it also merges the *current* base
branch tip into the checkout first (`merge-base: true`), because GitHub's
pre-computed merge ref can be stale — see below. Add no new third-party
actions: it uses the same pinned `checkout`, `setup-node` and `setup-uv` as the
other workflows here, plus plain shell and Python.

Call it. Include `push` to the default branch, and `merge_group` if the repo
uses a merge queue, so the same check runs on the code that actually lands:

```yaml
# .github/workflows/lockfile.yml in a consuming repo
name: Lockfile
on:
  pull_request:
  push:
    branches: [main]
  merge_group:        # only if the repo uses a merge queue
jobs:
  lockfile:
    uses: lurking-walrus/gh-automation/.github/workflows/lockfile-guard.yml@v1
    # with:             # all optional; existing callers need none of this
    #   working-directory: "."   # where the lockfile lives
    #   ecosystems: auto         # or "pnpm,uv"; a named ecosystem without its lockfile fails
    #   node-version: "24"
    #   pnpm-version: ""         # default: package.json packageManager pin, else 10
    #   merge-base: true
    #   strict-only: false       # true = strict parse only (the push backstop)
    #   tooling-ref: ""          # default: the ref you pinned this workflow to
```

Required-check context: **`lockfile / integrity`**.

**What the guard cannot do on its own.** A PR check is a snapshot of one base
commit; it cannot see a PR that merges after it ran. That is the lockfile
merge race — see [below](#the-lockfile-merge-race) for the two controls that
close it.

**Where the checks live.** The detect and strict-parse logic is one script,
[`scripts/lockfile-check/lockfile-check.sh`](scripts/lockfile-check/lockfile-check.sh)
(+ `lockfile_strict.py`), used by both this workflow and the auto-merge
pre-merge re-check. A reusable workflow cannot read its own repo's files, so
each workflow fetches that script with plain `git` at the ref the caller
pinned it to (read from the caller's workflow file; full 40-char SHAs, tags
and branches all work), or at `tooling-ref` if set, else `v1`.

**Self-test.** `tests/lockfile-guard/run-tests.sh` runs the shared script and
the guard's drift steps (extracted from the workflow by step id) against
fixture projects: good pnpm/npm/uv lockfiles must pass; duplicate keys
(including the design-system shape), YAML/JSON/TOML errors, conflict markers,
an empty file and manifest drift must each fail the right step. It then
replays the two-PR race against a local git "origin" — two lockfile edits that
each pass, merge textually clean, and produce a duplicate `tslib@2.9.1` key —
and asserts the pre-merge re-check refuses the second PR (and a conflicting
one) with a report, and passes an unrelated one. Last, it checks the
workflows' wiring: per-repo lock, re-check before merge, the shared script in
both places. Run it locally (needs
`python3`; `pnpm`, `npm` and `uv` for their cases, skipped if absent unless
`REQUIRE_ALL=1`). `lockfile-guard-selftest.yml` runs it in CI whenever the
guard or its tests change.

### The lockfile merge race

**What happened.** On 2026-11-09, Dependabot PRs #137 and #138 in
`kornsour/design-system` each edited `pnpm-lock.yaml`. Each passed the lockfile
guard — against a base that did not yet contain the other. Both auto-merged
about 35 seconds apart. Git merged the two edits textually clean, and the
result had a duplicate `tslib@2.9.1` key, which broke every later install and
CI run. Nothing caught it on `main` either: auto-merge had been enabled with
`GITHUB_TOKEN`, so the merges started no `push` workflows.

The cause is structural, not a guard bug: a PR's checks describe the PR merged
into the base *as it was when they ran*. Without "require branches to be up to
date", GitHub will merge a green PR into a base that has moved since.

**Control 1 — serialize and re-check immediately before merging**
(`dependabot-auto-merge.yml`, on by default):

1. The `auto-merge` job waits until the PR's required checks have passed.
2. The `merge` job takes a per-repo lock: `concurrency: dependabot-auto-merge-${{ github.repository }}`,
   `cancel-in-progress: false`, so Dependabot merges in one repo happen one at
   a time. (The key includes `github.repository` because inside a reusable
   workflow `github.workflow`/`github.ref` resolve in the caller.)
3. Inside the lock it fetches the **current** base tip, merges the PR head
   into it locally and runs the strict lockfile checks on the result
   (`lockfile-check.sh premerge`).
4. Pass: `gh pr merge --match-head-commit <sha>` — exactly the commit checked.
   Fail (duplicate key, parse error, conflict): no merge, the job fails, and
   the workflow comments on the PR explaining why; `@dependabot rebase`
   regenerates the lockfile on top of the new base and the next run re-checks.

The second PR of an #137/#138 pair now waits for the first to merge, sees it in
the base, and is refused instead of merged. GitHub keeps at most one *pending*
run per concurrency group, so if three PRs queue within one merge's few
seconds the oldest pending one is cancelled — its PR just stays open (re-run
the workflow or `@dependabot rebase`). That is fail-safe: nothing unchecked
merges. An older version of this workflow may have left GitHub auto-merge
enabled on open PRs; the new one disables it when it runs, so GitHub cannot
merge outside the lock.

**Control 2 — a push-to-`main` backstop.** For anything that lands without the
lock (a human merge, a non-Dependabot PR, a cancelled run that someone merged
by hand), run only the strict checks on every push to the default branch:

```yaml
# .github/workflows/lockfile-backstop.yml in a consuming repo
# (or just add `push: branches: [main]` to the existing lockfile.yml caller)
name: Lockfile backstop
on:
  push:
    branches: [main]
jobs:
  lockfile:
    uses: lurking-walrus/gh-automation/.github/workflows/lockfile-guard.yml@v1
    with:
      strict-only: true     # strict parse only: seconds, no installs
```

It turns `main` red the moment a corrupted lockfile lands instead of when the
next unrelated PR's install fails. **It only runs if the merge was made by a
real identity**: merges made (or auto-merge enabled) with `GITHUB_TOKEN` start
no workflows. So the auto-merge caller must pass `AUTOMERGE_TOKEN` — a
fine-grained PAT or a GitHub App token, stored as a *Dependabot* secret — and
should set `require-token: true`. Without it the workflow logs a warning on
every run saying the backstop will not fire.

**Cost.** The pre-merge re-check and the backstop are each a strict parse —
seconds, no `node_modules`, no CI rerun. The only added wait is the
`auto-merge` job idling while the PR's own CI runs (free on public repos and on
the self-hosted fleet). Neither control reruns any PR's full CI.

**Rejected alternatives.**

- *Require branches to be up to date* (`strict_required_status_checks_policy`)
  closes the race by forcing every PR to be rebased onto the latest base and
  fully re-run before merge. With N open Dependabot PRs that is O(N²) CI runs —
  each merge invalidates the other N−1, which must all rebase and rerun — on a
  week where Dependabot opens a dozen PRs at once. The pre-merge re-check gets
  the property that matters (the lockfile of *base + PR* is valid) for seconds
  per merge.
- *Merge queues* would serialize merges natively, but are not available for
  private repositories on every plan (historically they needed GitHub
  Enterprise Cloud) — **check your plan** before relying on one. They also
  rerun the full required checks per queued PR. If a repo does use one, add
  `merge_group` to the lockfile-guard caller.

### `python-ci.yml`
Standardized Python CI for `python-template`-derived repos: ruff lint + format
check, pyright type-check, and pytest — all in **one job** to keep billed
Actions minutes low. Installs only the given extras (default `dev`), so heavy
runtime frameworks never download in CI. Call it:

```yaml
# .github/workflows/ci.yml in a consuming repo
name: CI
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  ci:
    uses: lurking-walrus/gh-automation/.github/workflows/python-ci.yml@v1
    with:
      python-version: "3.14"   # optional
      extras: "dev"            # optional
```

Required-check context: **`ci / Lint, type-check & test`**.

## Per-repo pieces (not centralizable on a personal account)

A reusable workflow centralizes the *logic*, but each consuming repo still needs,
per GitHub's personal-account model:

- the caller workflow files (`.github/workflows/dependabot-auto-merge.yml`,
  `.github/workflows/lockfile.yml`)
- `.github/dependabot.yml`
- `allow_auto_merge` enabled on the repo
- an `AUTOMERGE_TOKEN` Dependabot secret (see `dependabot-auto-merge.yml`
  above; the one piece `rollout.sh` cannot do for you). Check with
  `gh secret list --app dependabot -R lurking-walrus/<repo>` — it must list
  `AUTOMERGE_TOKEN` (`gh secret list -R …` alone shows only Actions secrets)
- a **repository ruleset** with the required status checks (matched to that
  repo's own CI check names + `lockfile / integrity`)

`scripts/rollout.sh` stamps all of those onto a repo idempotently. Run it from
the root of a checked-out consuming repo:

```bash
# From a template-derived repo using the reusable ci.yml (four CI jobs):
/path/to/gh-automation/scripts/rollout.sh --checks \
  "ci / Lint & format (Biome),ci / Type check,ci / Unit tests (Vitest),ci / Build,lockfile / integrity"

# From a repo with its own single-job CI (job id `ci`):
/path/to/gh-automation/scripts/rollout.sh --checks "ci,lockfile / integrity"
```

The `--checks` contexts **must** match the consuming repo's actual CI check
names — that's the one thing the script can't infer. It writes the workflow
files and a `.github/dependabot.yml` (with ecosystems detected from the repo's
manifests) only when they're absent — commit those via a PR — then applies the
`allow_auto_merge` and ruleset settings directly through the API. Re-running is
safe: existing files are skipped and an existing ruleset of the same name is
left untouched. Requires `gh` (authenticated) and `jq`; pass `--dry-run` to
preview. Run `rollout.sh --help` for all flags.
