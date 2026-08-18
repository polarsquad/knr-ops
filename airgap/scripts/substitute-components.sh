#!/usr/bin/env bash
# substitute-components.sh — resolve clusterctl-style variables in the captured
# CAPI provider component manifests.
#
# The captured components (airgap/manifests/*.components.yaml) are raw
# clusterctl templates: the capi-operator would normally substitute
# ${VAR:=default} placeholders and apply the provider-spec arg overrides at
# install time. In the gap the operator is absent, so this script performs the
# same two steps up front:
#
#   1. ${VAR:=default}  ->  default
#   2. --feature-gates=<all defaults>  ->  --feature-gates=ClusterTopology=true
#      (mirrors the args override in mgmt/local-host/capi-providers/*/
#      provider(s).yaml: core, bootstrap, control-plane, CAPD; CAAPH has no
#      override in the repo and keeps its defaults)
#
# Idempotent. Run after (re)capturing component manifests, before packaging.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFESTS="$SCRIPT_DIR/../manifests"

python3 - "$MANIFESTS" <<'PY'
import re, sys, pathlib

manifests = pathlib.Path(sys.argv[1])
# Files whose manager gets the repo's feature-gates override (see provider configs)
override_files = {
    "core-cluster-api.components.yaml",
    "bootstrap-kubeadm.components.yaml",
    "control-plane-kubeadm.components.yaml",
    "infrastructure-docker.components.yaml",
}

var_re = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*:=([^}]*)\}")
fg_re = re.compile(r"--feature-gates=[^\n\"']*")

for path in sorted(manifests.glob("*.components.yaml")):
    txt = path.read_text()
    n_before = len(var_re.findall(txt))
    txt = var_re.sub(lambda m: m.group(1), txt)
    fg = False
    if path.name in override_files:
        txt, count = fg_re.subn("--feature-gates=ClusterTopology=true", txt)
        fg = count > 0
    leftover = var_re.findall(txt)
    path.write_text(txt)
    print(f"{path.name}: substituted {n_before} placeholders, "
          f"feature-gates override={'yes' if fg else 'no'}, leftover={len(leftover)}")
    if leftover:
        sys.exit(f"ERROR: unsubstituted placeholders remain in {path.name}: {leftover[:3]}")
PY

echo "==> substitution complete"
