#!/usr/bin/env python3
"""Verify Renovate detects the imperative chart pins in bootstrap-rs.

The binary installs charts before Flux exists, so their versions are Rust
constants in bootstrap-rs/src/main.rs that the manifest managers cannot
read. customManagers in renovate.json5 must detect them; this test proves
the regex, file pattern, and datasource wiring against the real main.rs so
a bump cannot silently stop being proposed (issue #95 acceptance).
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

EXPECTED_FILE = "bootstrap-rs/src/main.rs"
EXPECTED_DEPS = {"ghcr.io/controlplaneio-fluxcd/charts/flux-operator"}
REPO_ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    env = os.environ.copy()
    env.update(
        {
            "LOG_FORMAT": "json",
            "LOG_LEVEL": "debug",
            "RENOVATE_ENABLED_MANAGERS": "custom.regex",
            "RENOVATE_INCLUDE_PATHS": json.dumps([EXPECTED_FILE]),
        }
    )

    # The fixture copies the real renovate.json5 and the real main.rs so the
    # test exercises the exact patterns and the exact constant shapes that
    # ship. platform=local + dry-run=lookup performs no writes, no PRs.
    with tempfile.TemporaryDirectory(prefix="renovate-bootstrap-rs-test-") as temp:
        fixture_root = Path(temp)
        shutil.copy2(REPO_ROOT / "renovate.json5", fixture_root / "renovate.json5")
        target = fixture_root / EXPECTED_FILE
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO_ROOT / EXPECTED_FILE, target)

        result = subprocess.run(
            ["renovate", "--platform=local", "--dry-run=lookup"],
            check=False,
            cwd=fixture_root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

    detected: set[str] = set()
    diagnostics = []
    for line in result.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        if event.get("level", 0) >= 40:
            diagnostics.append(event.get("msg", line))
        if event.get("msg") != "packageFiles with updates":
            continue

        # Renovate records the looked-up package files under `config` in this
        # debug event. The manager name (currently `regex`) is intentionally
        # not hard-coded so a future custom-manager migration remains visible.
        for manager_files in event.get("config", {}).values():
            for package in manager_files:
                if package.get("packageFile") != EXPECTED_FILE:
                    continue
                for dependency in package.get("deps", []):
                    dep_name = dependency.get("depName")
                    if dep_name:
                        detected.add(dep_name)

    missing = EXPECTED_DEPS - detected
    if result.returncode or missing:
        print("Renovate chart-pin detection check failed", file=sys.stderr)
        print(f"exit code: {result.returncode}", file=sys.stderr)
        print(f"expected deps: {sorted(EXPECTED_DEPS)}", file=sys.stderr)
        print(f"detected deps: {sorted(detected)}", file=sys.stderr)
        if diagnostics:
            print("Renovate diagnostics:", file=sys.stderr)
            for diagnostic in diagnostics[-20:]:
                print(f"  - {diagnostic}", file=sys.stderr)
        return 1

    print(f"{EXPECTED_FILE}: chart pin(s) detected: {sorted(detected)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
