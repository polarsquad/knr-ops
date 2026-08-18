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
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

echo "==> 1/4 validate"
mise run validate

echo "==> 2/4 config artifact"
"$SCRIPT_DIR/build-config-artifact.sh"

echo "==> 3/4 workload-node pod images"
WORKLOAD_IMAGES=(
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

echo "==> 4/4 zarf package create"
cd airgap
mise x -- zarf package create . --confirm

echo "==> Built:"
ls -lh zarf-package-knr-ops-airgap-*.tar.zst
