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

# ── SOPS age key ──────────────────────────────────────────────────────────────
# Flux decrypts SOPS-encrypted secrets in Git (e.g. the CAPA AWS credentials)
# using an age private key loaded into the cluster as the `sops-age` secret.
# AGE_KEY_FILE defaults to ./age.agekey (gitignored).
AGE_KEY_FILE="${AGE_KEY_FILE:-age.agekey}"
if [ ! -f "$AGE_KEY_FILE" ]; then
  echo "ERROR: age key file not found at '$AGE_KEY_FILE'." >&2
  echo "       Generate one with:  mise run sops-keygen" >&2
  echo "       and add its PUBLIC key to .sops.yaml. See README.md." >&2
  exit 1
fi

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

# ── Step 3b: Create SOPS age decryption key secret ────────────────────────────
# Flux's kustomize-controller uses this key to decrypt *.sops.yaml manifests
# (such as the CAPA AWS credentials) during reconciliation. The data key must
# end in `.agekey` for Flux to recognise it.
echo ">>> Creating sops-age decryption secret in flux-system..."
kubectl create secret generic sops-age \
  --namespace flux-system \
  --from-file=age.agekey="${AGE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

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

# ── Done ──────────────────────────────────────────────────────────────────────
# Everything else is driven by GitOps. The FluxInstance above syncs the
# capi-mgmt/ directory, whose top-level kustomization.yaml wires in the
# infrastructure, capi-providers, addons, and clusters Kustomizations with
# the correct dependsOn ordering. No further imperative steps are required.
echo ""
echo ">>> Bootstrap complete! Flux is now reconciling from ${GIT_REPO_URL}"
echo ">>> Watch progress with: flux get kustomizations --watch"
