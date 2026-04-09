#!/usr/bin/env bash
# bootstrap.sh – One-time imperative bootstrap for the management cluster.
# Everything after this script runs is driven by GitOps (Flux).
set -euo pipefail

# ── Prerequisites check ───────────────────────────────────────────────────────
for cmd in kind helm kubectl flux; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found in PATH"; exit 1; }
done

: "${GITHUB_APP_ID:?GITHUB_APP_ID must be set}"
: "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID must be set}"
: "${GITHUB_APP_PRIVATE_KEY:?GITHUB_APP_PRIVATE_KEY must be set (path to .pem file)}"
: "${GIT_REPO_URL:?GIT_REPO_URL must be set}"

# ── Step 1: Create the kind management cluster ────────────────────────────────
echo ">>> Creating kind cluster 'capi-mgmt'..."
kind create cluster --name capi-mgmt --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            system-reserved: memory=8Gi
            eviction-hard: memory.available<500Mi
            eviction-soft: memory.available<1Gi
            eviction-soft-grace-period: memory.available=1m30s
EOF

echo ">>> Waiting for cluster node to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s

# ── Step 2: Install the Flux Operator via Helm ────────────────────────────────
echo ">>> Installing Flux Operator..."
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace \
  --wait

# ── Step 3: Create GitHub App credentials secret ─────────────────────────────
echo ">>> Creating GitHub App credentials secret in flux-system..."
kubectl create secret generic flux-github-app \
  --namespace flux-system \
  --from-literal=githubAppID="${GITHUB_APP_ID}" \
  --from-literal=githubAppInstallationID="${GITHUB_APP_INSTALLATION_ID}" \
  --from-file=githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY}"

# # ── Step 4: Apply the FluxInstance to start GitOps reconciliation ─────────────
# echo ">>> Applying FluxInstance..."
# kubectl apply -f - <<EOF
# apiVersion: fluxcd.controlplane.io/v1
# kind: FluxInstance
# metadata:
#   name: flux
#   namespace: flux-system
#   annotations:
#     fluxcd.controlplane.io/reconcileEvery: "1h"
#     fluxcd.controlplane.io/reconcileTimeout: "5m"
# spec:
#   distribution:
#     version: "2.x"
#     registry: "ghcr.io/fluxcd"
#     artifact: "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests"
#   components:
#     - source-controller
#     - kustomize-controller
#     - helm-controller
#     - notification-controller
#   cluster:
#     type: kubernetes
#     size: small
#     multitenant: false
#     networkPolicy: true
#     domain: "cluster.local"
#   sync:
#     kind: GitRepository
#     url: "https://github.com/polarsquad/krm-ops"
#     ref: "refs/heads/main"
#     path: "capi-mgmt"
#     pullSecret: "flux-github-app"
# EOF

# echo ""
# echo ">>> Bootstrap complete! Flux is now reconciling"
