"""Strict parse of lockfiles: syntax errors, DUPLICATE KEYS, conflict markers.

Part of the shared lockfile check (see lockfile-check.sh, which is the entry
point and decides which lockfiles to check via GUARD_PNPM / GUARD_NPM /
GUARD_UV). Run from the directory that holds the lockfile(s). Needs PyYAML.
"""

import json
import os
import re
import sys

import yaml

failed = False


def fail(path, msg):
    global failed
    failed = True
    print(f"::error file={path}::{msg}")


def conflict_markers(path, text):
    for n, line in enumerate(text.splitlines(), 1):
        if re.match(r"^(<{7}|>{7})( |$)", line) or line == "=" * 7:
            fail(path, f"git conflict marker at line {n}")
            return True
    return False


def key_id(node):
    if isinstance(node, yaml.ScalarNode):
        return (node.tag, node.value)
    return ("complex", yaml.serialize(node))


def yaml_duplicates(node, trail, seen, out):
    if id(node) in seen:
        return
    seen.add(id(node))
    if isinstance(node, yaml.MappingNode):
        keys = {}
        for k, v in node.value:
            if k.tag == "tag:yaml.org,2002:merge":
                yaml_duplicates(v, trail, seen, out)
                continue
            kid = key_id(k)
            label = k.value if isinstance(k, yaml.ScalarNode) else "<complex key>"
            if kid in keys:
                out.append(
                    f"duplicate mapping key {label!r} at line {k.start_mark.line + 1} "
                    f"(first at line {keys[kid] + 1}) under {'/'.join(trail) or '<root>'}"
                )
            else:
                keys[kid] = k.start_mark.line
            yaml_duplicates(v, trail + [str(label)], seen, out)
    elif isinstance(node, yaml.SequenceNode):
        for i, item in enumerate(node.value):
            yaml_duplicates(item, trail + [str(i)], seen, out)


def check_pnpm(path):
    text = open(path, encoding="utf-8").read()
    if not text.strip():
        return fail(path, "lockfile is empty")
    if conflict_markers(path, text):
        return
    try:
        # pnpm 11+ writes its own packageManager pin as a separate YAML document
        # ahead of the lockfile proper, so parse and check every document.
        roots = [r for r in yaml.compose_all(text, Loader=yaml.SafeLoader) if r is not None]
        for _ in yaml.safe_load_all(text):
            pass
    except yaml.YAMLError as e:
        return fail(path, f"YAML parse error: {' '.join(str(e).split())}")
    if not roots:
        return fail(path, "lockfile has no content")
    dups = []
    for root in roots:
        yaml_duplicates(root, [], set(), dups)
    for d in dups:
        fail(path, d)
    if not dups:
        print(f"{path}: parses cleanly, no duplicate keys")


def check_json(path):
    text = open(path, encoding="utf-8").read()
    if conflict_markers(path, text):
        return
    dups = []

    def hook(pairs):
        seen = set()
        for k, _ in pairs:
            if k in seen:
                dups.append(k)
            seen.add(k)
        return dict(pairs)

    try:
        json.loads(text, object_pairs_hook=hook)
    except ValueError as e:
        return fail(path, f"JSON parse error: {e}")
    for k in dups:
        fail(path, f"duplicate object key {k!r}")
    if not dups:
        print(f"{path}: parses cleanly, no duplicate keys")


def check_toml(path):
    text = open(path, encoding="utf-8").read()
    if conflict_markers(path, text):
        return
    try:
        import tomllib
    except ImportError:
        print(f"::warning file={path}::Python < 3.11 has no tomllib; relying on `uv lock --check` to parse")
        return
    try:
        # tomllib rejects duplicate keys and tables outright.
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        return fail(path, f"TOML parse error (includes duplicate keys): {e}")
    print(f"{path}: parses cleanly, no duplicate keys")


if os.environ.get("GUARD_PNPM") == "true":
    check_pnpm("pnpm-lock.yaml")
if os.environ.get("GUARD_NPM") == "true":
    for name in ("package-lock.json", "npm-shrinkwrap.json"):
        if os.path.isfile(name):
            check_json(name)
if os.environ.get("GUARD_UV") == "true":
    check_toml("uv.lock")

sys.exit(1 if failed else 0)
