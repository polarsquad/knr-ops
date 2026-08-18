#!/usr/bin/env bash
# build-package.sh — connected-side package build.
#
#   1. mise run validate (all overlays still build)
#   2. build-config-artifact.sh (trimmed airgap tree -> localhost:5001 OCI)
#   3. stage workload-node pod images into archives/ (host-daemon tarball for
#      CAPD preLoadImages; distinct from the mgmt substrate images the Zarf
#      package pushes into the internal registry)
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

echo "==> 3/4 workload-node pod images + OCI charts"
mkdir -p airgap/archives
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
