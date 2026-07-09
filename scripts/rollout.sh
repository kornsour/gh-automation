#!/usr/bin/env bash
#
# rollout.sh — idempotently onboard a repo to the shared dependency-automation
# stack (Dependabot auto-merge + lockfile guard).
#
# A reusable workflow centralizes the *logic*, but GitHub's personal-account
# model still requires a few per-repo pieces that can't be centralized:
#   - caller workflow files (.github/workflows/{dependabot-auto-merge,lockfile}.yml)
#   - .github/dependabot.yml
#   - allow_auto_merge enabled on the repo
#   - a branch ruleset listing that repo's required status checks
#
# This script stamps all of those onto a repo. It is safe to re-run: files are
# written only when absent, and the ruleset is created only when one of the same
# name doesn't already exist.
#
# Usage — run from the root of a checked-out consuming repo:
#
#   /path/to/gh-automation/scripts/rollout.sh --checks "ci,lockfile / integrity"
#
# The required-check contexts differ per repo and MUST match that repo's own CI:
#   - a custom single-job CI (job id `ci`)      -> --checks "ci,lockfile / integrity"
#   - the reusable ci.yml (four named jobs)     -> --checks \
#       "ci / Lint & format (Biome),ci / Type check,ci / Unit tests (Vitest),ci / Build,lockfile / integrity"
#
# The workflow files and dependabot.yml are written into the current directory;
# commit them via a PR. The repo settings (allow_auto_merge, ruleset) are applied
# directly through the GitHub API.
#
# Flags:
#   --repo <owner/repo>    Target repo (default: inferred from `gh repo view`)
#   --checks <csv>         Required status-check contexts, comma-separated
#                          (default: "ci,lockfile / integrity")
#   --ruleset-name <name>  Ruleset name (default: "main")
#   --no-files             Skip writing files; only apply repo settings
#   --dry-run              Print what would happen; make no changes
#   -h, --help             Show this help

set -euo pipefail

RULESET_NAME="main"
CHECKS_CSV="ci,lockfile / integrity"
REPO=""
WRITE_FILES=1
DRY_RUN=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--repo) REPO="${2:?}"; shift 2 ;;
		--checks) CHECKS_CSV="${2:?}"; shift 2 ;;
		--ruleset-name) RULESET_NAME="${2:?}"; shift 2 ;;
		--no-files) WRITE_FILES=0; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

for bin in gh jq; do
	command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' is required" >&2; exit 1; }
done

if [ -z "$REPO" ]; then
	REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
fi

echo "Onboarding $REPO"
echo "  required checks: $CHECKS_CSV"
[ "$DRY_RUN" -eq 1 ] && echo "  (dry run — no changes will be made)"

run() { if [ "$DRY_RUN" -eq 1 ]; then echo "  would run: $*"; else "$@"; fi; }

# ---------------------------------------------------------------------------
# 1. Files (written into the current repo; commit them via a PR).
# ---------------------------------------------------------------------------
write_if_absent() {
	local path="$1" content
	content="$(cat)"
	if [ -e "$path" ]; then
		echo "  = $path (exists, skipping)"
		return
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "  would write: $path"
		return
	fi
	mkdir -p "$(dirname "$path")"
	printf '%s\n' "$content" > "$path"
	echo "  + $path"
}

if [ "$WRITE_FILES" -eq 1 ]; then
	write_if_absent .github/workflows/dependabot-auto-merge.yml <<'YAML'
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
YAML

	write_if_absent .github/workflows/lockfile.yml <<'YAML'
name: Lockfile
on:
  pull_request:
  push:
    branches: [main]
jobs:
  lockfile:
    uses: kornsour/gh-automation/.github/workflows/lockfile-guard.yml@main
YAML

	# dependabot.yml: detect the repo's ecosystems so the config is useful out of
	# the box. github-actions is always included; language ecosystems are added
	# when their manifest is present.
	if [ -e .github/dependabot.yml ]; then
		echo "  = .github/dependabot.yml (exists, skipping)"
	else
		ecosystems=()
		[ -f package.json ] && ecosystems+=("npm")
		[ -f go.mod ] && ecosystems+=("gomod")
		{ [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f Pipfile ]; } && ecosystems+=("pip")
		[ -f Cargo.toml ] && ecosystems+=("cargo")
		{ [ -f Dockerfile ] || ls ./*/Dockerfile >/dev/null 2>&1; } && ecosystems+=("docker")
		ecosystems+=("github-actions")

		{
			echo "version: 2"
			echo "updates:"
			for eco in "${ecosystems[@]}"; do
				extra_label=""
				[ "$eco" = "github-actions" ] && extra_label=$'\n      - "ci"'
				group_name="minor-and-patch"
				[ "$eco" = "github-actions" ] && group_name="actions"
				cat <<YAML
  - package-ecosystem: "$eco"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
    open-pull-requests-limit: 10
    labels:
      - "dependencies"$extra_label
    groups:
      $group_name:
        update-types:
          - "minor"
          - "patch"
YAML
			done
		} > /tmp/rollout-dependabot.$$.yml
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  would write: .github/dependabot.yml (ecosystems: ${ecosystems[*]})"
			rm -f /tmp/rollout-dependabot.$$.yml
		else
			mkdir -p .github
			mv /tmp/rollout-dependabot.$$.yml .github/dependabot.yml
			echo "  + .github/dependabot.yml (ecosystems: ${ecosystems[*]})"
		fi
	fi
fi

# ---------------------------------------------------------------------------
# 2. Repo settings: auto-merge must be allowed for `gh pr merge --auto` to work.
# ---------------------------------------------------------------------------
run gh api -X PATCH "repos/$REPO" \
	-F allow_auto_merge=true \
	-F delete_branch_on_merge=true >/dev/null || true
echo "  ✓ allow_auto_merge + delete_branch_on_merge"

# ---------------------------------------------------------------------------
# 3. Ruleset: the required status checks are what let auto-merge *engage* — a PR
#    with --auto stays queued until they pass. Without this, --auto is rejected.
# ---------------------------------------------------------------------------
existing_id="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name==\"$RULESET_NAME\") | .id" 2>/dev/null || true)"
if [ -n "$existing_id" ]; then
	echo "  = ruleset '$RULESET_NAME' (exists, id $existing_id, skipping)"
else
	checks_json="$(jq -Rn --arg csv "$CHECKS_CSV" '
		$csv | split(",")
		| map(gsub("^\\s+|\\s+$"; ""))
		| map(select(length > 0))
		| map({context: .})')"
	ruleset_body="$(jq -n \
		--arg name "$RULESET_NAME" \
		--argjson checks "$checks_json" '{
			name: $name,
			target: "branch",
			enforcement: "active",
			conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
			rules: [
				{ type: "deletion" },
				{ type: "non_fast_forward" },
				{ type: "pull_request", parameters: {
					allowed_merge_methods: ["merge", "squash", "rebase"],
					dismiss_stale_reviews_on_push: false,
					require_code_owner_review: false,
					require_last_push_approval: false,
					required_approving_review_count: 0,
					required_review_thread_resolution: false,
					required_reviewers: []
				} },
				{ type: "required_status_checks", parameters: {
					do_not_enforce_on_create: false,
					strict_required_status_checks_policy: false,
					required_status_checks: $checks
				} }
			]
		}')"
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "  would create ruleset '$RULESET_NAME' with checks: $CHECKS_CSV"
	else
		printf '%s' "$ruleset_body" | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null
		echo "  + ruleset '$RULESET_NAME' created"
	fi
fi

echo "Done."
[ "$WRITE_FILES" -eq 1 ] && echo "Next: commit the .github/ files via a PR (checks run on the PR; auto-merge takes over afterward)."
