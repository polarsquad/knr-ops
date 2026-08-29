#!/usr/bin/env python3
"""Dependency version catalog drift check.

Validates that every literal occurrence of a catalog version in the repo
matches deps/versions.toml. stdlib only, Python 3.11+.

Modes:
  default      validate every [[slot]] pattern/count against its file
  --forbid     additionally fail if a phase-1 key's literal appears outside
               the allowed files (catalog itself, slotted files, docs/)
  --markdown   print the dependency inventory table for docs/dependencies.md
"""

import argparse
import pathlib
import re
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "deps" / "versions.toml"

FORBID_KEYS = [
    "go",
    "kind",
    "kubectl",
    "helm",
    "clusterctl",
    "zarf",
    "clusterawsadm",
    "mise",
]

# Never scanned by --forbid.
FORBID_EXCLUDE_DIRS = [
    ".git",
    ".hermes",
    "airgap/archives",
    "airgap/rendered",
    "airgap/sbom",
    "airgap/config-artifact",
    # Rust build artifacts; cargo metadata embeds toolchain and dependency
    # version strings that collide with catalog literals (e.g. helm 4.2
    # inside libtokio rlib names).
    "bootstrap-rs/target",
]

# Never scanned by --forbid: files whose version literals are either
# non-pins or consumers covered by later PRs' slots and forbid phases.
FORBID_EXCLUDE_PATHS = [
    "README.md",
    "airgap/images.txt",
    "airgap/manifests",
    "airgap/scripts",
    "airgap/zarf.yaml",
    ".github/workflows/air-gapped.yml",  # mise-action version; slotted in PR 4
    # capa/clusterctl manifest consumers; slotted in PRs 5-6
    "mgmt/aws/capi-providers/capa-system/providers.yaml",
    "mgmt/aws/capi-providers/capi-system/providers.yaml",
    "mgmt/local-host/capi-providers/capd-system/provider.yaml",
    "mgmt/local-host/capi-providers/capi-system/providers.yaml",
]

ALLOWED_DIRS = ["deps", "docs"]


def load_catalog():
    with open(CATALOG, "rb") as fh:
        return tomllib.load(fh)


def slot_regex(pattern, value):
    """Escape the pattern, substituting the resolved version for {version}."""
    parts = pattern.split("{version}")
    body = re.escape(value).join(parts)
    return re.compile(body)


def run_slots(catalog):
    failures = 0
    for slot in catalog.get("slot", []):
        path = ROOT / slot["file"]
        pattern = slot["pattern"]
        expected = slot["count"]
        key = slot["key"]
        value = catalog["versions"][key]
        if not path.is_file():
            print(f"FAIL slot: file={slot['file']} key={key} (file not found)")
            failures += 1
            continue
        rx = slot_regex(pattern, str(value))
        actual = len(rx.findall(path.read_text()))
        if actual != expected:
            print(
                f"FAIL slot: file={slot['file']} key={key} "
                f"value={value} expected={expected} actual={actual} "
                f"(pattern: {pattern})",
            )
            failures += 1
    return failures


def iter_repo_files():
    for path in sorted(ROOT.rglob("*")):
        rel = path.relative_to(ROOT).as_posix()
        if not path.is_file():
            continue
        if any(rel == d or rel.startswith(d + "/") for d in FORBID_EXCLUDE_DIRS):
            continue
        if rel.endswith(".sops.yaml"):
            continue
        yield rel, path


def matches_forbid(value, text):
    """True if the catalog literal occurs as a standalone version.

    Uses a boundary-aware match so partial collisions are avoided:
    '4.2' must not match inside '1.14.0' (segment) but bare values such
    as 'v20260528-9350166c' are matched literally when they contain a
    letter prefix.
    """
    pattern = re.compile(
        r"(?<![\w.])v?" + re.escape(value) + r"(?![\w.])",
    )
    return bool(pattern.search(text))


def run_forbid(catalog):
    slotted = {}
    for slot in catalog.get("slot", []):
        slotted.setdefault(slot["key"], set()).add(slot["file"])

    failures = 0
    for rel, path in iter_repo_files():
        if any(
            rel == p or rel.startswith(p + "/") for p in FORBID_EXCLUDE_PATHS
        ):
            continue
        text = path.read_text(errors="ignore")
        for key in FORBID_KEYS:
            value = str(catalog["versions"][key])
            if not matches_forbid(value, text):
                continue
            if rel == CATALOG.relative_to(ROOT).as_posix():
                continue
            if rel in slotted.get(key, set()):
                continue
            if any(rel.startswith(d + "/") or rel == d for d in ALLOWED_DIRS):
                continue
            print(f"FAIL forbid: literal '{value}' (key={key}) found in {rel}")
            failures += 1
    return failures


def run_markdown(catalog):
    print("| Key | Version |")
    print("|---|---|")
    slots = {}
    for s in catalog.get("slot", []):
        slots.setdefault(s["key"], []).append(s["file"])
    for key in sorted(catalog["versions"]):
        value = catalog["versions"][key]
        note = ""
        if key in slots:
            note = f" (validated in {', '.join(sorted(set(slots[key])))})"
        print(f"| `{key}` | `{value}`{note} |")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--forbid", action="store_true", help="enable forbid pass")
    parser.add_argument("--markdown", action="store_true", help="print inventory table")
    args = parser.parse_args()

    catalog = load_catalog()

    if args.markdown:
        sys.exit(run_markdown(catalog))

    failures = run_slots(catalog)
    if args.forbid:
        failures += run_forbid(catalog)

    if failures:
        print(f"deps-check: {failures} failure(s)")
        sys.exit(1)
    print("deps-check: all slots match the catalog")


if __name__ == "__main__":
    main()
