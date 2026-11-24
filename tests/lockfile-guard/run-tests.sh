#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2030,SC2031,SC2015
# (o_* are eval-assigned; PATH is deliberately per-subshell)
# Self-test for the lockfile checks shared by .github/workflows/lockfile-guard.yml
# and .github/workflows/dependabot-auto-merge.yml.
#
# Runs the shared script (scripts/lockfile-check/lockfile-check.sh) plus the
# guard's drift steps (extracted from the workflow by step id) against fixture
# projects, asserting that good lockfiles pass and every kind of bad lockfile
# (duplicate key, parse error, conflict marker, manifest drift) fails. Then
# exercises the auto-merge PRE-MERGE path against a local git "origin",
# including the two-PR race that produced a duplicate key in design-system.
# Finally checks the workflows are wired to the script (lock, re-check order).
# Testing the shipped scripts — not a copy — is the point.
#
#   tests/lockfile-guard/run-tests.sh
#
# Needs python3, plus pnpm / npm / uv for those ecosystems' cases. A missing
# tool SKIPs its cases locally; set REQUIRE_ALL=1 (CI does) to fail instead.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
workflow="$repo/.github/workflows/lockfile-guard.yml"
automerge="$repo/.github/workflows/dependabot-auto-merge.yml"
check="$repo/scripts/lockfile-check/lockfile-check.sh"
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

for id in detect strict pnpm-check npm-check uv-check; do extract "$id"; done

# The workflow's detect/strict steps call "$LOCKFILE_CHECK" (set by its tooling
# step); point it at this checkout's script. With no PyYAML on python3 the
# script builds its private venv under RUNNER_TEMP, exactly as in Actions.
export LOCKFILE_CHECK="$check"
export RUNNER_TEMP="$work/runner-temp"; mkdir -p "$RUNNER_TEMP"
guard_path="$work/tools-venv/bin"

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
# pnpm 11+ lockfiles are two YAML documents: the packageManager pin, then the
# lockfile proper. Strict parse only (no pnpm needed): both must be checked.
pnpm11_lock() { # pnpm11_lock <dir>: prepend the pnpm 11+ pin document
  { printf -- "---\nlockfileVersion: '9.0'\n\nimporters:\n\n  .:\n    configDependencies: {}\n"
    printf "    packageManagerDependencies:\n      pnpm:\n        specifier: 12.18.0\n        version: 12.18.0\n\n---\n"
    cat "$1/pnpm-lock.yaml"; } >"$1/lock.new" && mv "$1/lock.new" "$1/pnpm-lock.yaml"
}
strict_only() { # strict_only <dir>: the strict step alone, as the push backstop runs it
  (cd "$1" && PATH="$guard_path:$PATH" GUARD_PNPM=true bash "$work/step-strict.sh")
}
d="$(fresh pnpm-good)"; pnpm11_lock "$d"
if strict_only "$d" >"$work/case.log" 2>&1; then
  pass=$((pass + 1)); echo "ok    pnpm: multi-document (pnpm 11+) lockfile passes the strict parse"
else
  fail=$((fail + 1)); echo "FAIL  pnpm: multi-document (pnpm 11+) lockfile rejected"; sed 's/^/        | /' "$work/case.log"
fi
d="$(fresh pnpm-good)"; pnpm11_lock "$d"; dup_first_line_matching '^  ms@2\.1\.3:' "$d/pnpm-lock.yaml"
case_ "pnpm: duplicate key in the lockfile document of a pnpm 11+ lockfile fails" fail strict "$d"
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

echo "== pre-merge re-check (dependabot-auto-merge path) =="
# ok_if <name> <command...>: pass when the command succeeds.
ok_if() {
  local name="$1"; shift
  if "$@" >"$work/assert.log" 2>&1; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL  %s\n' "$name"; sed 's/^/        | /' "$work/assert.log"
  fi
}
not() { ! "$@"; }
# Hermetic git: ignore the developer's global hooks (e.g. a gitleaks
# templateDir) for every git call in this section, the script's included.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

# A local bare repo plays GitHub's "origin". Base lockfile: enough snapshot
# entries that edits near the top and near the bottom are separate hunks, so
# git merges them without a conflict.
origin="$work/origin.git"; g init --quiet --bare "$origin"
seed="$work/seed"; g clone --quiet "$origin" "$seed" 2>/dev/null
cp "$fixtures/pnpm-good/package.json" "$seed/"
{
  printf "lockfileVersion: '9.0'\n\nsettings:\n  autoInstallPeers: true\n  excludeLinksFromLockfile: false\n\n"
  printf "importers:\n\n  .:\n    dependencies:\n      ms:\n        specifier: 2.1.3\n        version: 2.1.3\n\n"
  printf "packages:\n\n  ms@2.1.3:\n    resolution: {integrity: sha512-x}\n\nsnapshots:\n"
  for p in aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll; do printf "\n  %s@1.0.0: {}\n" "$p"; done
} >"$seed/pnpm-lock.yaml"
(cd "$seed" && g add -A && g commit --quiet -m base && g push --quiet origin HEAD:main)

# Two "Dependabot PRs" branched from the same base. PR A adds tslib@2.9.1
# near the top of snapshots, PR B adds the same key near the bottom (as two
# independent bumps that each pull tslib@2.9.1 in would). Each lockfile is
# valid on its own; together they hold a duplicate key.
mkpr() { # mkpr <branch> <after-entry> -> prints head sha
  (
    cd "$seed" && g checkout --quiet -B "$1" origin/main
    awk -v after="  $2@1.0.0: {}" '{ print } $0 == after { print ""; print "  tslib@2.9.1: {}" }' pnpm-lock.yaml >x && mv x pnpm-lock.yaml
    g commit --quiet -am "bump via $1" && g push --quiet origin "$1" && g rev-parse HEAD
  )
}
sha_a="$(mkpr pr-a bbb)"
sha_b="$(mkpr pr-b kkk)"

# The runner's checkout: a clone of origin, as actions/checkout leaves it.
clone="$work/runner-checkout"; g clone --quiet "$origin" "$clone" 2>/dev/null
premerge() { (cd "$clone" && g -c advice.detachedHead=false status >/dev/null && "$check" premerge --base main --head "$1" "${@:2}"); }

ok_if "PR A alone passes the lockfile check" bash -c "cd '$seed' && git checkout --quiet '$sha_a' && '$check' check"
ok_if "PR B alone passes the lockfile check" bash -c "cd '$seed' && git checkout --quiet '$sha_b' && '$check' check"
ok_if "premerge: PR A against the current base passes" premerge "$sha_a"

# GitHub merges A (squash). main now contains A's lockfile edit.
(cd "$seed" && g checkout --quiet -B squash-a origin/main && g merge --quiet --squash "$sha_a" >/dev/null && g commit --quiet -m "A (#137)" && g push --quiet origin HEAD:main)

# The race: B's checks ran against the OLD base, so they are green...
ok_if "race: B merged into the STALE base still passes (what the PR check saw)" \
  bash -c "cd '$seed' && git checkout --quiet --detach '$sha_b' && '$check' check"
# ...and A+B merges textually clean, so GitHub would happily merge it.
ok_if "race: B merges into the new base with no textual conflict" \
  bash -c "cd '$seed' && git checkout --quiet --detach origin/main && git fetch --quiet origin && git checkout --quiet --detach origin/main && git -c user.name=t -c user.email=t@x merge --quiet --no-edit '$sha_b'"
ok_if "race: ...and that textually-clean merge has a duplicate tslib@2.9.1 key" \
  not bash -c "cd '$seed' && '$check' strict"
(cd "$seed" && g merge --abort >/dev/null 2>&1 || g reset --quiet --hard)

# The fix: the pre-merge re-check fetches the CURRENT base and refuses.
report="$work/premerge-report.md"
ok_if "premerge: PR B against the current base (A merged) FAILS" not premerge "$sha_b" --report "$report"
ok_if "premerge: failure names the duplicate key" grep -q "duplicate mapping key 'tslib@2.9.1'" "$report"
ok_if "premerge: report explains why the merge was refused" grep -q "Auto-merge stopped" "$report"
ok_if "premerge: report names the base commit it checked" grep -q "$(git -C "$origin" rev-parse main)" "$report"
ok_if "premerge: nothing was pushed to origin" test "$(git -C "$origin" rev-parse main)" = "$(git -C "$seed" rev-parse origin/main)"

# A PR that edits the same lines as A conflicts: refuse, with a reason.
sha_c="$(cd "$seed" && g checkout --quiet -B pr-c "$sha_a~1" && sed 's/^  ccc@1.0.0: {}$/  ccc@2.0.0: {}/; s/^  bbb@1.0.0: {}$/  bbb@2.0.0: {}/' pnpm-lock.yaml >x && mv x pnpm-lock.yaml && g commit --quiet -am c && g push --quiet origin pr-c && g rev-parse HEAD)"
ok_if "premerge: a PR that no longer merges cleanly FAILS" not premerge "$sha_c" --report "$report"
ok_if "premerge: conflict report says so" grep -q "no longer merges cleanly" "$report"

# A harmless PR (manifest only) against the new base passes.
sha_d="$(cd "$seed" && g checkout --quiet -B pr-d "$sha_a~1" && printf '\n' >>package.json && g commit --quiet -am d && g push --quiet origin pr-d && g rev-parse HEAD)"
# pr-d was pushed after the runner's checkout was cloned, so this also
# proves a head commit missing locally is fetched on demand.
ok_if "premerge: an unrelated PR (head not yet fetched) against the new base passes" premerge "$sha_d"

ok_if "premerge: usage error without --head exits 2" \
  bash -c "cd '$clone'; '$check' premerge --base main; test \$? -eq 2"

echo "== auto-merge wait-for-checks loop (stubbed gh) =="
"$extract_py" - "$automerge" "$work/step-wait.sh" <<'PY'
import sys
import yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"]["auto-merge"]["steps"] if s.get("id") == "wait")
open(sys.argv[2], "w").write(step["run"])
PY
stub="$work/stub-bin"; mkdir -p "$stub"
# Fake gh: `pr view --json state,...` pops the next line of $STUB/views
# ("STATE<TAB>mergeStateStatus<TAB>head"); `pr checks` prints $STUB/checks;
# `pr view --json autoMergeRequest` prints $STUB/auto. Every call is logged.
cat >"$stub/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >>"$STUB/calls"
case "$*" in
  *autoMergeRequest*) cat "$STUB/auto" ;;
  "pr view"*) head -n1 "$STUB/views"; [ "$(wc -l <"$STUB/views")" -le 1 ] || sed -i.bak 1d "$STUB/views" ;;
  "pr checks"*) cat "$STUB/checks" ;;
  "pr merge --disable-auto"*) ;;
  *) echo "unexpected gh $*" >&2; exit 99 ;;
esac
GH
chmod +x "$stub/gh"
# wait_case <name> <expect ready> <auto> <checks> <views...>
wait_case() {
  local name="$1" expect="$2" auto="$3" checks="$4"; shift 4
  local s; s="$(mktemp -d "$work/stub.XXXXXX")"
  printf '%s\n' "$auto" >"$s/auto"; printf '%s\n' "$checks" >"$s/checks"
  printf '%s\n' "$@" | sed 's/ /\t/g' >"$s/views"; : >"$s/calls"
  : >"$s/out"
  if ! STUB="$s" PATH="$stub:$PATH" GITHUB_OUTPUT="$s/out" PR_URL=https://example.invalid/pr/1 \
       HEAD_SHA=abc TIMEOUT_MINUTES=1 POLL_SECONDS=0 bash "$work/step-wait.sh" >"$s/log" 2>&1; then
    fail=$((fail + 1)); printf 'FAIL  %s (step errored)\n' "$name"; sed 's/^/        | /' "$s/log"; return
  fi
  local got; got="$(sed -n 's/^ready=//p' "$s/out" | tail -n1)"
  if [ "$got" = "$expect" ]; then pass=$((pass + 1)); printf 'ok    %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL  %s (ready=%s, want %s)\n' "$name" "$got" "$expect"; sed 's/^/        | /' "$s/log"; fi
  WAIT_CALLS="$s/calls"
}
wait_case "wait: green immediately -> ready" true false "" "OPEN CLEAN abc"
wait_case "wait: only non-required checks pending (UNSTABLE) -> ready" true false "" "OPEN UNSTABLE abc"
wait_case "wait: required checks pending, then green -> ready" true false "pending" "OPEN BLOCKED abc" "OPEN BLOCKED abc" "OPEN CLEAN abc"
wait_case "wait: checks unreadable (no checks: read) keeps polling -> ready" true false "" "OPEN BLOCKED abc" "OPEN BLOCKED abc" "OPEN BLOCKED abc" "OPEN BLOCKED abc" "OPEN BLOCKED abc" "OPEN CLEAN abc"
wait_case "wait: a required check failed -> not ready" false false "fail" "OPEN BLOCKED abc"
wait_case "wait: green checks but blocked (review) -> gives up, not ready" false false "pass" "OPEN BLOCKED abc"
wait_case "wait: PR head moved -> not ready (newer run takes over)" false false "" "OPEN CLEAN def"
wait_case "wait: PR closed -> not ready" false false "" "CLOSED CLEAN abc"
wait_case "wait: conflicts -> not ready" false false "" "OPEN DIRTY abc"
wait_case "wait: a transient empty/failed gh read is retried -> ready" true false "" "" "OPEN CLEAN abc"
wait_case "wait: legacy GitHub auto-merge is disabled first" true true "" "OPEN CLEAN abc"
ok_if "wait: ...via gh pr merge --disable-auto" grep -q -- "pr merge --disable-auto" "$WAIT_CALLS"

echo "== workflow wiring =="
wiring() { "$extract_py" - "$workflow" "$automerge" <<'PY'
import re
import sys
import yaml

guard_path, am_path = sys.argv[1:3]
guard, am = yaml.safe_load(open(guard_path)), yaml.safe_load(open(am_path))
on = lambda wf: wf.get("on", wf.get(True))  # YAML 1.1 reads a bare `on` as True
errs = []
def need(cond, msg):
    if not cond:
        errs.append(msg)

gsteps = {s.get("id"): s for s in guard["jobs"]["integrity"]["steps"]}
need("LOCKFILE_CHECK\" detect" in gsteps["detect"]["run"], "guard detect step does not call the shared script")
need("LOCKFILE_CHECK\" strict" in gsteps["strict"]["run"], "guard strict step does not call the shared script")
for sid in ("pnpm-install", "pnpm-check", "npm-check", "uv-check"):
    need("!inputs.strict-only" in gsteps[sid]["if"], f"guard step {sid} is not skipped by strict-only")
need(on(guard)["workflow_call"]["inputs"]["strict-only"]["default"] is False, "strict-only must default to false")

merge = am["jobs"]["merge"]
conc = merge.get("concurrency", {})
need("github.repository" in str(conc.get("group", "")), "merge job concurrency group must include github.repository")
need(conc.get("cancel-in-progress") is False, "merge job must queue (cancel-in-progress: false)")
ids = [s.get("id") or s.get("name") for s in merge["steps"]]
need("premerge" in ids and "Merge" in ids and ids.index("premerge") < ids.index("Merge"), "re-check must run before the merge")
msteps = {s.get("id") or s.get("name"): s for s in merge["steps"]}
need("LOCKFILE_CHECK\" premerge" in msteps["premerge"]["run"], "premerge step does not call the shared script")
need("--match-head-commit" in msteps["Merge"]["run"], "merge must pin --match-head-commit")
need("--auto" not in msteps["Merge"]["run"], "re-checked merge must not hand off to GitHub auto-merge")
need("failure()" in msteps["Explain the refusal on the PR"]["if"], "refusal comment must run on failure")
inputs = on(am)["workflow_call"]["inputs"]
for old in ("merge-method", "merge-majors", "require-token"):
    need(old in inputs, f"input {old} was removed (breaks callers)")
need(inputs["recheck-before-merge"]["default"] is True, "recheck-before-merge must default to true")

# The tooling step is shared text; keep the two copies identical.
def block(path):
    t = open(path).read()
    m = re.search(r"      # BEGIN shared tooling step.*?      # END shared tooling step\n", t, re.S)
    # The auto-merge copy carries an extra `if:`; everything else must match.
    return re.sub(r"(?m)^        if: .*\n", "", m.group(0)) if m else None
a, b = block(guard_path), block(am_path)
need(a is not None and a == b, "shared tooling step differs between lockfile-guard.yml and dependabot-auto-merge.yml")
for e in errs:
    print(e)
sys.exit(1 if errs else 0)
PY
}
ok_if "workflows call the shared script, lock per repo, re-check before merge" wiring

echo "== PyYAML bootstrap =="
if python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "skip  system python3 already has PyYAML; venv bootstrap not exercised"; skip=$((skip + 1))
else
  d="$(fresh pnpm-dup)"
  ok_if "strict builds its own PyYAML venv and still fails the duplicate" \
    bash -c "cd '$d' && RUNNER_TEMP='$work/fresh-temp' && export RUNNER_TEMP && mkdir -p \"\$RUNNER_TEMP\" && ! '$check' check && test -x \"\$RUNNER_TEMP/lockfile-check-venv/bin/python\""
fi

echo
echo "passed: $pass  failed: $fail  skipped: $skip"
[ "$fail" -eq 0 ]
