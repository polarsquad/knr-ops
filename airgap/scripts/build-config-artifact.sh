#!/usr/bin/env bash
# build-config-artifact.sh — build the airgap-trimmed knr-ops config tree and
# push it to the connected-side local registry, ready to be baked into the
# Zarf package (zarf.yaml lists it under the knr-ops-config component images).
#
# Connected-side only. Requires: flux CLI, local registry on localhost:5001
# (the knr-registry container from `mise -E local-host run bootstrap`).
#
# Why a trimmed tree: in the gap the substrate (cert-manager, CAPI, CAAPH,
# flux-operator) is deployed by Zarf, and the capi-operator HelmRelease /
# provider fetches cannot reach the internet. The airgap artifact therefore
# contains only the workload-facing kustomizations (clusters/, addons/) and a
# root kustomization + dependsOn chain that never references the substrate
# Kustomizations.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

REGISTRY_PORT="${REGISTRY_PORT:-5001}"
OCI_REPOSITORY="${OCI_REPOSITORY:-knr-ops-airgap}"
OCI_TAG="${OCI_TAG:-latest}"
OCI_URL="oci://localhost:${REGISTRY_PORT}/${OCI_REPOSITORY}:${OCI_TAG}"

ARTIFACT_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/knr-ops-airgap-oci.XXXXXX")
cleanup() { rm -rf "$ARTIFACT_ROOT"; }
trap cleanup EXIT

LH="$ARTIFACT_ROOT/mgmt/local-host"
mkdir -p "$LH/clusters" "$LH/addons/cni" "$LH/addons/flux-apps" "$ARTIFACT_ROOT/workload"

# Verbatim copies: the cluster definition and the addon payloads.
cp -R mgmt/local-host/clusters/docker "$LH/clusters/docker"
cp mgmt/local-host/addons/cni/kindnet.yaml "$LH/addons/cni/kindnet.yaml"
cp mgmt/local-host/addons/cni/kustomization.yaml "$LH/addons/cni/kustomization.yaml"
cp mgmt/local-host/addons/cni/flux-ks.yaml "$LH/addons/cni/flux-ks.yaml"
cp mgmt/local-host/addons/flux-apps/flux-instance.yaml "$LH/addons/flux-apps/flux-instance.yaml"
cp mgmt/local-host/addons/flux-apps/flux-operator.yaml "$LH/addons/flux-apps/flux-operator.yaml"
cp mgmt/local-host/addons/flux-apps/kustomization.yaml "$LH/addons/flux-apps/kustomization.yaml"

# Workload tree ships verbatim (consumed by the per-cluster Flux in Phase 5).
cp -R workload/local-host "$ARTIFACT_ROOT/workload/local-host"

# Trimmed root kustomization: no infrastructure/ or capi-providers/ entries.
cat > "$LH/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Airgap root of the local-host OCI artifact. The substrate (cert-manager,
# CAPI core/providers, CAAPH, flux-operator) is deployed by Zarf, so this root
# only wires the workload-facing Kustomizations. DependsOn chains never
# reference substrate Kustomizations (they do not exist in the gap).
resources:
  - clusters/flux-ks.yaml
  - addons/cni/flux-ks.yaml
  - addons/flux-apps/flux-ks.yaml
EOF

# clusters/flux-ks.yaml: drop the dependsOn on capd-system (Zarf-managed).
cat > "$LH/clusters/flux-ks.yaml" <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: docker-workload-cluster
  namespace: flux-system
spec:
  interval: 5m
  retryInterval: 2m
  timeout: 5m
  prune: true
  wait: false
  sourceRef:
    kind: OCIRepository
    name: flux-system
  path: ./mgmt/local-host/clusters/docker
  healthChecks:
    - apiVersion: cluster.x-k8s.io/v1beta2
      kind: Cluster
      name: local-workload
      namespace: default
EOF

# addons/flux-apps/flux-ks.yaml: dependsOn local-workload-cni only
# (caaph-system is Zarf-managed in the gap).
cat > "$LH/addons/flux-apps/flux-ks.yaml" <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-apps
  namespace: flux-system
spec:
  interval: 5m
  retryInterval: 2m
  timeout: 10m
  prune: true
  wait: true
  sourceRef:
    kind: OCIRepository
    name: flux-system
  path: ./mgmt/local-host/addons/flux-apps
  dependsOn:
    - name: local-workload-cni
EOF

# Optional rehearsal rename: AIRGAP_CLUSTER_NAME=airgap-wl rewrites every
# local-workload reference inside the assembled mgmt tree (copied files AND
# the generated flux-ks files above, so dependsOn references stay consistent).
# Use when rehearsing on a host whose Docker daemon already runs a live
# local-workload baseline: CAPD matches containers by the
# cluster.x-k8s.io/cluster-name label, so two clusters with the same name on
# one daemon would collide/adopt.
if [ -n "${AIRGAP_CLUSTER_NAME:-}" ]; then
  echo "==> Renaming workload cluster to '${AIRGAP_CLUSTER_NAME}' in the artifact copy"
  grep -rl "local-workload" "$LH" | while IFS= read -r f; do
    sed -i '' "s/local-workload/${AIRGAP_CLUSTER_NAME}/g" "$f"
  done
fi

GIT_SHA=$(git rev-parse HEAD)
GIT_REF=$(git branch --show-current)
GIT_REF="${GIT_REF:-detached}"
SOURCE_URL=$(git config --get remote.origin.url || true)
SOURCE_URL="${SOURCE_URL:-file://${REPO_ROOT}}"

echo "==> Pushing airgap config artifact ${OCI_URL}"
flux push artifact "$OCI_URL" \
  --path="$ARTIFACT_ROOT" \
  --source="$SOURCE_URL" \
  --revision="${GIT_REF}@sha1:${GIT_SHA}" \
  --insecure-registry \
  --reproducible

echo "==> Done. zarf.yaml's knr-ops-config component references localhost:${REGISTRY_PORT}/${OCI_REPOSITORY}:${OCI_TAG}"
