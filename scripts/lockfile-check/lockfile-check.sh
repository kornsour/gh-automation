#!/usr/bin/env bash
# lockfile-check.sh — the ONE implementation of the strict lockfile checks.
#
# Used by:
#   .github/workflows/lockfile-guard.yml          (PRs, and the push backstop)
#   .github/workflows/dependabot-auto-merge.yml   (pre-merge re-check)
#   tests/lockfile-guard/run-tests.sh             (self-test)
#
# Subcommands (all run in the current directory unless --dir is given):
#
#   detect     Decide which lockfiles to check. Reads ECOSYSTEMS (or
#              --ecosystems): "auto" or a comma list of pnpm,npm,uv. An
#              explicitly named ecosystem whose lockfile is missing fails.
#              Writes pnpm/npm/uv/any/js=true|false to $GITHUB_OUTPUT when set.
#   strict     Strict parse (syntax, DUPLICATE KEYS, conflict markers) of the
#              lockfiles selected by GUARD_PNPM / GUARD_NPM / GUARD_UV, or of
#              whatever `detect` finds when those are unset.
#   check      detect + strict.
#   premerge   --base <branch> --head <sha> [--remote origin] [--report FILE]
#              Fetch the CURRENT tip of <branch>, merge <sha> into it locally
#              (detached HEAD; nothing is pushed) and run `check` on the
#              result. This is what the PR's checks would have seen had they
#              run against today's base instead of a stale one. Fails on a
#              merge conflict too. --report writes a Markdown explanation.
#
# Exit status: 0 clean, 1 a lockfile/merge problem, 2 usage/config error.
#
# The strict parse needs PyYAML. If `python3 -c 'import yaml'` fails, a private
# venv is created under $RUNNER_TEMP (or $TMPDIR) and PyYAML installed into it.
# If that fails the check fails — it never silently skips.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^set -euo.*//'; }
die() { echo "::error::$*" >&2; exit 2; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
dir="."; base=""; head=""; remote="origin"; report=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="${2:?--dir needs a value}"; shift 2 ;;
    --ecosystems) ECOSYSTEMS="${2:?--ecosystems needs a value}"; shift 2 ;;
    --base) base="${2:?--base needs a value}"; shift 2 ;;
    --head) head="${2:?--head needs a value}"; shift 2 ;;
    --remote) remote="${2:?--remote needs a value}"; shift 2 ;;
    --report) report="${2:?--report needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# --- detect -----------------------------------------------------------------
# Sets GUARD_PNPM/GUARD_NPM/GUARD_UV (+ GUARD_ANY, GUARD_JS) in this shell.
do_detect() {
  local want="${ECOSYSTEMS:-auto}" e
  want="${want// /}"
  wants() { [ "$want" = auto ] || [[ ",$want," == *",$1,"* ]]; }
  GUARD_PNPM=false; GUARD_NPM=false; GUARD_UV=false
  if wants pnpm && [ -f pnpm-lock.yaml ]; then GUARD_PNPM=true; fi
  if wants npm && { [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; }; then GUARD_NPM=true; fi
  if wants uv && [ -f uv.lock ]; then GUARD_UV=true; fi
  # An explicitly requested ecosystem must have its lockfile.
  if [ "$want" != auto ]; then
    for e in ${want//,/ }; do
      case "$e" in
        pnpm) [ "$GUARD_PNPM" = true ] || { echo "::error::ecosystems names pnpm but there is no pnpm-lock.yaml"; return 2; } ;;
        npm)  [ "$GUARD_NPM" = true ]  || { echo "::error::ecosystems names npm but there is no package-lock.json"; return 2; } ;;
        uv)   [ "$GUARD_UV" = true ]   || { echo "::error::ecosystems names uv but there is no uv.lock"; return 2; } ;;
        *)    echo "::error::unknown ecosystem '$e' (use pnpm, npm, uv or auto)"; return 2 ;;
      esac
    done
  fi
  if [ "$GUARD_PNPM" = true ] && [ "$GUARD_NPM" = true ]; then
    echo "::warning::both pnpm-lock.yaml and package-lock.json exist; checking both, but one is probably stale."
  fi
  GUARD_ANY=false; GUARD_JS=false
  if [ "$GUARD_PNPM$GUARD_NPM$GUARD_UV" != falsefalsefalse ]; then GUARD_ANY=true; fi
  if [ "$GUARD_PNPM" = true ] || [ "$GUARD_NPM" = true ]; then GUARD_JS=true; fi
  if [ "$GUARD_ANY" = false ]; then
    echo "No pnpm-lock.yaml, package-lock.json or uv.lock — nothing to check."
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "pnpm=$GUARD_PNPM"
      echo "npm=$GUARD_NPM"
      echo "uv=$GUARD_UV"
      echo "any=$GUARD_ANY"
      echo "js=$GUARD_JS"
    } >> "$GITHUB_OUTPUT"
  fi
  echo "Detected: pnpm=$GUARD_PNPM npm=$GUARD_NPM uv=$GUARD_UV"
}

# --- strict -----------------------------------------------------------------
python_with_yaml() {
  if [ -n "${LOCKFILE_CHECK_PYTHON:-}" ]; then echo "$LOCKFILE_CHECK_PYTHON"; return; fi
  if python3 -c 'import yaml' >/dev/null 2>&1; then echo python3; return; fi
  local venv="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lockfile-check-venv"
  if ! "$venv/bin/python" -c 'import yaml' >/dev/null 2>&1; then
    # A private venv works on runners whose system Python is externally
    # managed (PEP 668). No `|| true`: no parser means fail closed.
    python3 -m venv "$venv" >&2
    "$venv/bin/python" -m pip install --quiet --disable-pip-version-check pyyaml >&2
  fi
  echo "$venv/bin/python"
}

do_strict() {
  if [ -z "${GUARD_PNPM:-}${GUARD_NPM:-}${GUARD_UV:-}" ]; then
    do_detect || return $?
  fi
  if [ "${GUARD_PNPM:-false}${GUARD_NPM:-false}${GUARD_UV:-false}" = falsefalsefalse ]; then
    return 0
  fi
  local py
  py="$(python_with_yaml)"
  GUARD_PNPM="${GUARD_PNPM:-false}" GUARD_NPM="${GUARD_NPM:-false}" GUARD_UV="${GUARD_UV:-false}" \
    "$py" "$here/lockfile_strict.py"
}

# --- premerge ---------------------------------------------------------------
write_report() { # write_report <headline> <log-file>
  [ -n "$report" ] || return 0
  {
    echo "**Auto-merge stopped: pre-merge lockfile re-check failed.**"
    echo
    echo "$1"
    echo
    echo "This PR's checks passed against an older \`$base\`. Before merging, the"
    echo "auto-merge workflow merged it into the **current** \`$base\` tip"
    echo "(\`${base_sha:-unknown}\`) and re-ran the strict lockfile checks; merging"
    echo "now would put a broken lockfile on \`$base\`. Usually another lockfile PR"
    echo "merged first. Rebase this PR (\`@dependabot rebase\`) or regenerate its"
    echo "lockfile; the workflow re-checks on the next push."
    echo
    echo '```'
    tail -n 40 "$2"
    echo '```'
  } >"$report"
}

do_premerge() {
  [ -n "$base" ] || die "premerge needs --base <branch>"
  [ -n "$head" ] || die "premerge needs --head <sha>"
  git rev-parse --git-dir >/dev/null 2>&1 || die "premerge must run inside a git checkout"
  local log rc=0
  log="$(mktemp)"
  git fetch --no-tags --quiet "$remote" "+refs/heads/${base}:refs/remotes/${remote}/${base}"
  base_sha="$(git rev-parse "refs/remotes/${remote}/${base}")"
  if ! git cat-file -e "${head}^{commit}" 2>/dev/null; then
    git fetch --no-tags --quiet "$remote" "$head"
  fi
  git checkout --quiet --detach "$base_sha"
  echo "Re-checking ${head} merged into the current ${remote}/${base} (${base_sha})"
  if ! git -c user.name=lockfile-check -c user.email=lockfile-check@users.noreply.github.com \
        merge --no-ff --no-edit --quiet "$head" >"$log" 2>&1; then
    cat "$log"
    git merge --abort >/dev/null 2>&1 || true
    echo "::error::${head} does not merge cleanly into the current ${base} (${base_sha})"
    write_report "The PR no longer merges cleanly into the current \`$base\`." "$log"
    return 1
  fi
  (cd "$dir" && do_detect && do_strict) >"$log" 2>&1 || rc=$?
  cat "$log"
  if [ "$rc" -ne 0 ]; then
    echo "::error::lockfile check failed on ${head} merged into the current ${base} (${base_sha})"
    write_report "Merged with the current \`$base\`, the lockfile fails the strict check:" "$log"
    return 1
  fi
  echo "Pre-merge re-check passed against ${base} at ${base_sha}."
}

case "$cmd" in
  detect)   cd "$dir" && do_detect ;;
  strict)   cd "$dir" && do_strict ;;
  check)    cd "$dir" && do_detect && do_strict ;;
  premerge) do_premerge ;;
  -h|--help|help) usage ;;
  "") usage >&2; exit 2 ;;
  *) die "unknown subcommand: $cmd" ;;
esac
