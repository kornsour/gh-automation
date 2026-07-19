# gh-automation

Central, reusable GitHub Actions workflows shared across my repositories, so the
logic lives in one place instead of being copy-pasted into every repo.

## Workflows

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
    uses: kornsour/gh-automation/.github/workflows/dependabot-auto-merge.yml@main
    secrets: inherit
```

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
    uses: kornsour/gh-automation/.github/workflows/lockfile-guard.yml@main
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
    uses: kornsour/gh-automation/.github/workflows/python-ci.yml@main
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
