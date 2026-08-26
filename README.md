# gh-automation

Central, reusable GitHub Actions workflows shared across my repositories, so the
logic lives in one place instead of being copy-pasted into every repo.

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
    uses: kornsour/gh-automation/.github/workflows/ci.yml@v1
    with:
      node-version: "24"          # optional
      migration-check: true       # optional, for repos with src/db/schema.ts
      security-scan: true         # optional, defaults to true
```

Required-check contexts: **`ci / Lint & format (Biome)`**, **`ci / Type check`**,
**`ci / Unit tests (Vitest)`**, **`ci / Build`** — plus **`ci / DB migration
check`** when `migration-check: true`.

### `dependabot-auto-merge.yml`
Auto-merges Dependabot **patch/minor** PRs once the calling repo's required
status checks pass; majors are left for manual review. Call it:

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
    uses: kornsour/gh-automation/.github/workflows/dependabot-auto-merge.yml@v1
```

Do **not** pass `secrets: inherit`. This workflow declares no `secrets:` in its
`workflow_call` and uses only `secrets.GITHUB_TOKEN`, which GitHub provides to
called workflows automatically. Inheriting would hand it every secret in the
calling repo for no benefit — and the Semgrep step in `ci.yml` flags it as an
ERROR-severity finding, which blocks the caller's build.

### `lockfile-guard.yml`
Rejects duplicate-key `pnpm-lock.yaml` corruption. Self-contained; passes when
the repo has no `pnpm-lock.yaml`. Call it:

```yaml
# .github/workflows/lockfile.yml in a consuming repo
name: Lockfile
on:
  pull_request:
  push:
    branches: [main]
jobs:
  lockfile:
    uses: kornsour/gh-automation/.github/workflows/lockfile-guard.yml@v1
```

Required-check context: **`lockfile / integrity`**.

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
    uses: kornsour/gh-automation/.github/workflows/python-ci.yml@v1
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
