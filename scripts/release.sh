#!/usr/bin/env bash
#
# release.sh — cut a tagged release of this repo's reusable workflows.
#
# Consumers pin to a floating major tag (e.g. `@v1`) rather than `@main`, so a
# push to main doesn't change their behavior until a release is deliberately
# cut. This script, run from main:
#   1. creates an immutable annotated tag `vX.Y.Z` on the current commit
#   2. moves the floating major tag `vX` to point at the same commit
#   3. pushes both to origin
#
# Usage:
#   scripts/release.sh <version>      e.g. scripts/release.sh v1.1.0
#
# Flags:
#   --dry-run     Print what would happen; make no changes
#   -h, --help    Show this help

set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; }

VERSION=""
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
		*)
			if [ -n "$VERSION" ]; then
				echo "unexpected extra argument: $1" >&2; usage >&2; exit 2
			fi
			VERSION="$1"; shift ;;
	esac
done

[ -n "$VERSION" ] || { echo "error: version is required (e.g. v1.1.0)" >&2; usage >&2; exit 2; }
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like vX.Y.Z, got '$VERSION'" >&2; exit 1; }

MAJOR="${VERSION%%.*}"

command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }

branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "main" ]; then
	echo "error: release from 'main', currently on '$branch'" >&2
	exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
	echo "error: working tree is not clean" >&2
	exit 1
fi

git fetch origin main --quiet
local_sha="$(git rev-parse HEAD)"
remote_sha="$(git rev-parse origin/main)"
if [ "$local_sha" != "$remote_sha" ]; then
	echo "error: local main ($local_sha) is not in sync with origin/main ($remote_sha)" >&2
	exit 1
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
	echo "error: tag '$VERSION' already exists" >&2
	exit 1
fi

echo "Releasing $VERSION (major: $MAJOR) at $local_sha"
[ "$DRY_RUN" -eq 1 ] && echo "  (dry run — no changes will be made)"

run() { if [ "$DRY_RUN" -eq 1 ]; then echo "  would run: $*"; else "$@"; fi; }

run git tag -a "$VERSION" -m "Release $VERSION"
run git tag -f "$MAJOR" "$VERSION"
run git push origin "refs/tags/$VERSION"
run git push origin "refs/tags/$MAJOR" --force

echo "Done. Consumers pinned to '$MAJOR' now get $VERSION."
