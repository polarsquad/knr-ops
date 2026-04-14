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

# ── Step 4: Install the FluxInstance via Helm to start GitOps reconciliation ──
echo ">>> Installing FluxInstance via Helm..."
helm upgrade --install flux \
  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance \
  --namespace flux-system \
  --wait \
  --set instance.cluster.type=kubernetes \
  --set instance.cluster.size=small \
  --set instance.cluster.multitenant=false \
  --set instance.cluster.networkPolicy=true \
  --set instance.cluster.domain=cluster.local \
  --set instance.sync.kind=GitRepository \
  --set instance.sync.url="${GIT_REPO_URL}" \
  --set instance.sync.ref=refs/heads/main \
  --set instance.sync.path=capi-mgmt \
  --set instance.sync.pullSecret=flux-github-app \
  --set instance.sync.provider=github

# ── Step 5: Apply the clusters Kustomization CR ───────────────────────────────
# Applied imperatively so it never enters the GitRepository sync path.
# This prevents Flux from dry-running Cluster resources before the CAPI CRDs
# exist. The clusters Kustomization depends on addons (after caaph so CAAPH
# CRDs exist), which depends on infrastructure via dependsOn.
# echo ">>> Waiting for Flux Kustomization CRD to be established..."
# kubectl wait --for=condition=Established \
#   crd/kustomizations.kustomize.toolkit.fluxcd.io \
#   --timeout=300s

# echo ">>> Applying clusters Kustomization CR..."
# kubectl apply -f - <<'EOF'
# ---
# apiVersion: kustomize.toolkit.fluxcd.io/v1
# kind: Kustomization
# metadata:
#   name: clusters
#   namespace: flux-system
# spec:
#   interval: 1h
#   retryInterval: 2m
#   timeout: 5m
#   prune: true
#   sourceRef:
#     kind: GitRepository
#     name: flux-system
#   path: ./capi-mgmt/clusters
#   dependsOn:
#     - name: capi-providers
#     - name: addons
# EOF

echo ""
echo ">>> Bootstrap complete! Flux is now reconciling"
