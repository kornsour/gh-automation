#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2030,SC2031,SC2015
# (o_* are eval-assigned; PATH is deliberately per-subshell)
# Self-test for .github/workflows/lockfile-guard.yml.
#
# Extracts the guard's real `run:` scripts from the workflow by step id and
# runs them against fixture projects, asserting that good lockfiles pass and
# every kind of bad lockfile (duplicate key, parse error, conflict marker,
# manifest drift) fails. Testing the shipped scripts — not a copy — is the
# point: if someone edits the workflow, this exercises the edit.
#
#   tests/lockfile-guard/run-tests.sh
#
# Needs python3, plus pnpm / npm / uv for those ecosystems' cases. A missing
# tool SKIPs its cases locally; set REQUIRE_ALL=1 (CI does) to fail instead.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
workflow="$repo/.github/workflows/lockfile-guard.yml"
fixtures="$here/fixtures"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0; skip=0

# --- bootstrap: a venv with PyYAML, used to read the workflow -------------
python3 -m venv "$work/tools-venv"
"$work/tools-venv/bin/python" -m pip install --quiet --disable-pip-version-check pyyaml
extract_py="$work/tools-venv/bin/python"

# step_script <step-id> -> writes the step's `run` body to $work/step-<id>.sh
extract() {
  "$extract_py" - "$workflow" "$1" "$work/step-$1.sh" <<'PY'
import sys
import yaml

path, step_id, out = sys.argv[1:4]
wf = yaml.safe_load(open(path))
for step in wf["jobs"]["integrity"]["steps"]:
    if step.get("id") == step_id:
        open(out, "w").write(step["run"])
        break
else:
    sys.exit(f"no step with id {step_id!r} in {path}")
PY
}

for id in detect parser strict pnpm-check npm-check uv-check; do extract "$id"; done

# Run the parser-setup step exactly as the workflow does, so the strict step
# gets the same PyYAML venv it would get in Actions.
export RUNNER_TEMP="$work/runner-temp"; mkdir -p "$RUNNER_TEMP"
export GITHUB_PATH="$work/github-path"; : > "$GITHUB_PATH"
bash "$work/step-parser.sh" >/dev/null
guard_path="$(cat "$GITHUB_PATH")"

# run_guard <dir> [ecosystems]: runs detect + strict + the per-ecosystem
# drift checks in <dir>, mirroring the workflow's step conditions. Returns
# nonzero if ANY step fails; prints which one.
run_guard() {
  local dir="$1" eco="${2:-auto}" out="$work/gh-output"
  : > "$out"
  (
    cd "$dir"
    export PATH="$guard_path:$PATH"
    export GITHUB_OUTPUT="$out" ECOSYSTEMS="$eco"
    bash "$work/step-detect.sh" || { echo "FAILED-STEP: detect"; exit 1; }
    # shellcheck disable=SC1090
    for kv in pnpm npm uv any; do eval "o_$kv=\$(sed -n \"s/^$kv=//p\" \"$out\")"; done
    if [ "$o_any" = true ]; then
      GUARD_PNPM="$o_pnpm" GUARD_NPM="$o_npm" GUARD_UV="$o_uv" \
        bash "$work/step-strict.sh" || { echo "FAILED-STEP: strict"; exit 1; }
    fi
    [ "$o_pnpm" != true ] || bash "$work/step-pnpm-check.sh" || { echo "FAILED-STEP: pnpm-check"; exit 1; }
    [ "$o_npm" != true ] || bash "$work/step-npm-check.sh" || { echo "FAILED-STEP: npm-check"; exit 1; }
    [ "$o_uv" != true ] || bash "$work/step-uv-check.sh" || { echo "FAILED-STEP: uv-check"; exit 1; }
  )
}

# case_ <name> <expect pass|fail> <expected failing step or -> <dir> [eco]
case_() {
  local name="$1" expect="$2" step="$3" dir="$4" eco="${5:-auto}" log rc=0
  log="$work/case.log"
  run_guard "$dir" "$eco" >"$log" 2>&1 || rc=$?
  local ok=true
  if [ "$expect" = pass ] && [ "$rc" -ne 0 ]; then ok=false; fi
  if [ "$expect" = fail ]; then
    [ "$rc" -ne 0 ] || ok=false
    if [ "$step" != - ] && ! grep -q "FAILED-STEP: $step" "$log"; then ok=false; fi
  fi
  if $ok; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL  %s (expected %s%s, got rc=%s)\n' \
      "$name" "$expect" "$([ "$step" = - ] || echo " at $step")" "$rc"
    sed 's/^/        | /' "$log"
  fi
}

need() { # need <tool> ; returns 1 (and counts a skip) when absent
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  if [ "${REQUIRE_ALL:-}" = 1 ]; then
    echo "FAIL  required tool '$1' is not installed"; fail=$((fail + 1))
  else
    echo "skip  $1 not installed (set REQUIRE_ALL=1 to make this fatal)"; skip=$((skip + 1))
  fi
  return 1
}

fresh() { # fresh <fixture> -> prints a private writable copy
  local d; d="$(mktemp -d "$work/case.XXXXXX")"; cp -R "$fixtures/$1/." "$d"; echo "$d"
}

# dup_first_line_matching <regex> <file>: write the first matching line twice.
dup_first_line_matching() {
  awk -v re="$1" '{ print } !done && $0 ~ re { print; done = 1 }' "$2" >"$2.new" && mv "$2.new" "$2"
}

echo "== empty / unrelated repo =="
empty="$(mktemp -d "$work/case.XXXXXX")"
case_ "no lockfile at all passes (back compat)" pass - "$empty"
case_ "explicit ecosystem without its lockfile fails" fail detect "$empty" pnpm

echo "== pnpm =="
if need pnpm; then
  case_ "pnpm: good lockfile passes" pass - "$(fresh pnpm-good)"
fi
d="$(fresh pnpm-dup)"
case_ "pnpm: duplicate key (the design-system incident shape) fails the strict parse" fail strict "$d"
grep -q "duplicate" <(run_guard "$d" 2>&1 || true) \
  && { pass=$((pass + 1)); echo "ok    pnpm: failure message names the duplicate key"; } \
  || { fail=$((fail + 1)); echo "FAIL  pnpm: failure message does not mention a duplicate"; }
# Second layer: even with the strict parse bypassed, pnpm itself rejects it.
if need pnpm; then
  d="$(fresh pnpm-dup)"
  rc=0; (cd "$d" && PATH="$guard_path:$PATH" bash "$work/step-pnpm-check.sh") >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then pass=$((pass + 1)); echo "ok    pnpm: frozen-lockfile layer also rejects the duplicate"; else fail=$((fail + 1)); echo "FAIL  pnpm install accepted the duplicate-key lockfile"; fi

  d="$(fresh pnpm-good)"
  sed -i.bak 's/"ms": "2.1.3"/"ms": "2.1.3", "ms-old": "npm:ms@2.0.0"/' "$d/package.json"; rm -f "$d/package.json.bak"
  case_ "pnpm: package.json drifted from lockfile fails" fail pnpm-check "$d"
fi
d="$(fresh pnpm-good)"; printf '\n<<<<<<< HEAD\n' >>"$d/pnpm-lock.yaml"
case_ "pnpm: git conflict marker fails" fail strict "$d"
d="$(fresh pnpm-good)"; printf '\nbroken: [unclosed\n' >>"$d/pnpm-lock.yaml"
case_ "pnpm: YAML syntax error fails" fail strict "$d"
d="$(fresh pnpm-good)"; : >"$d/pnpm-lock.yaml"
case_ "pnpm: empty lockfile fails" fail strict "$d"
d="$(fresh pnpm-good)"
# duplicate key in the IMPORTERS block, not just packages/snapshots
sed -i.bak 's/^      ms:$/      ms:\n        specifier: 2.1.3\n        version: 2.1.3\n      ms:/' "$d/pnpm-lock.yaml"; rm -f "$d/pnpm-lock.yaml.bak"
case_ "pnpm: duplicate key in a nested importers block fails" fail strict "$d"

echo "== npm =="
if need npm; then
  case_ "npm: good lockfile passes" pass - "$(fresh npm-good)"
  d="$(fresh npm-good)"
  sed -i.bak 's/"ms": "2.1.3"/"ms": "2.1.3", "debug": "4.3.4"/' "$d/package.json"; rm -f "$d/package.json.bak"
  case_ "npm: package.json drifted from lockfile fails" fail npm-check "$d"
  d="$(fresh npm-good)"
  dup_first_line_matching '"lockfileVersion"' "$d/package-lock.json"
  case_ "npm: duplicate JSON key fails" fail strict "$d"
fi

echo "== uv =="
if need uv; then
  case_ "uv: good lockfile passes" pass - "$(fresh uv-good)"
  d="$(fresh uv-good)"
  sed -i.bak 's/six==1.16.0/six==1.16.0", "idna/' "$d/pyproject.toml"; rm -f "$d/pyproject.toml.bak"
  case_ "uv: pyproject drifted from lockfile fails" fail uv-check "$d"
  d="$(fresh uv-good)"
  dup_first_line_matching '^version = ' "$d/uv.lock"
  case_ "uv: duplicate TOML key fails" fail strict "$d"
fi

echo
echo "passed: $pass  failed: $fail  skipped: $skip"
[ "$fail" -eq 0 ]
