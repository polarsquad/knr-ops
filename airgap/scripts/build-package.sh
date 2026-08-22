#!/usr/bin/env bash
# build-package.sh — connected-side package build.
#
#   1. mise run validate (all overlays still build)
#   2. build-config-artifact.sh (trimmed airgap tree -> configured OCI registry)
#   3. stage the Zarf init package, host-daemon images, workload-node pod
#      images, and OCI charts into archives/
#   4. zarf package create
#
# Output: zarf-package-knr-ops-airgap-arm64-0.1.0.tar.zst next to airgap/.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

echo "==> 1/4 validate"
mise run validate

echo "==> 2/4 config artifact"
"$SCRIPT_DIR/build-config-artifact.sh"

# The package must pull the same config artifact that the preceding step
# published. Builds retain zarf.yaml's localhost:5001 default unless an
# alternate OCI_REGISTRY is explicitly supplied, so rewrite only the working
# tree for package creation when an override is present.
if [ -n "${OCI_REGISTRY:-}" ]; then
  OCI_REPOSITORY="${OCI_REPOSITORY:-knr-ops-airgap}"
  OCI_TAG="${OCI_TAG:-latest}"
  python3 - airgap/zarf.yaml "${OCI_REGISTRY}/${OCI_REPOSITORY}:${OCI_TAG}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
replacement = sys.argv[2]
text = path.read_text()
expected = "localhost:5001/knr-ops-airgap:latest"
if expected not in text:
    raise SystemExit(f"ERROR: expected config artifact reference {expected!r}")
path.write_text(text.replace(expected, replacement, 1))
print(f"    zarf config artifact: {replacement}")
PY
fi

echo "==> 3/4 offline host assets, workload-node images, and OCI charts"
mkdir -p airgap/archives

mise x -- zarf tools download-init \
  --architecture arm64 \
  --output-directory airgap/archives

HOST_IMAGES=(
  kindest/node:v1.36.1
  kindest/node:v1.35.0
  kindest/haproxy:v20230606-42a2262b
  docker.io/library/registry:2
)
for img in "${HOST_IMAGES[@]}"; do
  docker pull --platform linux/arm64 "$img" >/dev/null
done
docker save -o airgap/archives/kindest_node_v1.36.1_mgmt.tar kindest/node:v1.36.1
docker save -o airgap/archives/kindest_node_v1.35.0.tar kindest/node:v1.35.0
docker save -o airgap/archives/kindest_haproxy_v20230606-42a2262b.tar kindest/haproxy:v20230606-42a2262b
docker save -o airgap/archives/docker.io_library_registry_2.tar docker.io/library/registry:2
echo "    saved Zarf init package and host-daemon image archives"

WORKLOAD_IMAGES=(
  registry.k8s.io/pause:3.10.1
  docker.io/kindest/kindnetd:v20260528-9350166c
  ghcr.io/controlplaneio-fluxcd/flux-operator:v0.58.0
  ghcr.io/fluxcd/source-controller:v1.9.4
  ghcr.io/fluxcd/kustomize-controller:v1.9.4
  ghcr.io/fluxcd/helm-controller:v1.6.3
  ghcr.io/fluxcd/notification-controller:v1.9.3
  ghcr.io/stefanprodan/podinfo:6.14.0
)
for img in "${WORKLOAD_IMAGES[@]}"; do
  docker pull --platform linux/arm64 "$img" >/dev/null
done
docker save -o airgap/archives/workload-pod-images.tar "${WORKLOAD_IMAGES[@]}"
echo "    saved airgap/archives/workload-pod-images.tar"

# OCI charts the workload cluster needs in the gap (seeded into knr-registry
# by the stage script): the per-cluster flux-operator chart (HelmChartProxy)
# and the podinfo chart (workload HelmRelease).
mkdir -p airgap/archives/charts
helm pull oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator --version 0.58.0 -d airgap/archives/charts
helm pull oci://ghcr.io/stefanprodan/charts/podinfo --version 6.14.0 -d airgap/archives/charts
echo "    staged charts: $(ls airgap/archives/charts/)"

echo "==> 4/4 zarf package create"
cd airgap
mise x -- zarf package create . --confirm

echo "==> Built:"
ls -lh zarf-package-knr-ops-airgap-*.tar.zst
