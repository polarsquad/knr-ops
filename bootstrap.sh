#!/usr/bin/env bash
# bootstrap.sh – One-time imperative bootstrap for the management cluster.
# Everything after this script runs is driven by GitOps (Flux).
set -euo pipefail

# ── Prerequisites check ───────────────────────────────────────────────────────
for cmd in kind helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found in PATH"; exit 1; }
done

: "${GITHUB_APP_ID:?GITHUB_APP_ID must be set}"
: "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID must be set}"
: "${GITHUB_APP_PRIVATE_KEY:?GITHUB_APP_PRIVATE_KEY must be set (path to .pem file)}"
: "${GIT_REPO_URL:?GIT_REPO_URL must be set}"

# Validate GitHub App private key exists before doing anything
if [ ! -f "${GITHUB_APP_PRIVATE_KEY}" ]; then
  echo "ERROR: GitHub App private key file not found at '${GITHUB_APP_PRIVATE_KEY}'." >&2
  exit 1
fi

# ── SOPS age key ──────────────────────────────────────────────────────────────
# Flux decrypts SOPS-encrypted secrets in Git (e.g. the CAPA AWS credentials)
# using an age private key loaded into the cluster as the `sops-age` secret.
# AGE_KEY_FILE defaults to ./age.agekey (gitignored).
AGE_KEY_FILE="${AGE_KEY_FILE:-age.agekey}"
if [ ! -f "$AGE_KEY_FILE" ]; then
  echo "ERROR: age key file not found at '$AGE_KEY_FILE'." >&2
  echo "       Generate one with:  mise run sops-keygen" >&2
  echo "       and add its PUBLIC key to .sops.yaml. See docs/secrets.md." >&2
  exit 1
fi

# ── Prerequisite: Docker daemon ───────────────────────────────────────────────
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon not running"; exit 1; }

# ── Step 1: Create the kind management cluster ────────────────────────────────
echo ">>> Creating kind cluster 'capi-mgmt'..."
# Check if cluster already exists and delete it (idempotent)
if kind get clusters 2>/dev/null | grep -q "^capi-mgmt$"; then
  echo ">>> Cluster 'capi-mgmt' already exists – recreating..."
  kind delete cluster --name capi-mgmt
fi
kind create cluster --name capi-mgmt --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
EOF

echo ">>> Waiting for cluster node to be ready..."
# Explicitly switch kubectl to use the kind cluster context
kubectl config use-context kind-capi-mgmt
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
# (such as the CAPA AWS credentials) during reconciliation. Flux scans the
# Secret for keys matching the pattern `keys.<public-key>.agekey` — each
# matching key is passed to the age library for decryption.
# AGE_PUBLIC_KEY can be overridden via .env to match a specific .sops.yaml.
echo ">>> Creating sops-age decryption secret in flux-system..."
# Remove any existing sops-age secret to avoid stale keys from previous bootstrap runs
kubectl delete secret sops-age -n flux-system --ignore-not-found
AGE_PUBKEY="${AGE_PUBLIC_KEY:-$(grep '^# public key:' "${AGE_KEY_FILE}" 2>/dev/null | sed 's/^# public key: //')}"
if [ -z "$AGE_PUBKEY" ]; then
  echo "ERROR: Cannot determine age public key from '${AGE_KEY_FILE}' or from AGE_PUBLIC_KEY env var." >&2
  echo "       Set AGE_PUBLIC_KEY in .env, or regenerate the key with: mise run sops-keygen" >&2
  exit 1
fi
# Validate that the file contains an age private key (must have comment header + key data)
AGE_CONTENT=$(cat "${AGE_KEY_FILE}")
if ! echo "$AGE_CONTENT" | grep -q '^# created:' 2>/dev/null; then
  echo "ERROR: '${AGE_KEY_FILE}' does not appear to be a valid age key file."
  echo "       Expected a file with '# created:' comment header" >&2
  exit 1
fi
if ! echo "$AGE_CONTENT" | grep -q '^AGE-SECRET-KEY-' 2>/dev/null; then
  echo "ERROR: '${AGE_KEY_FILE}' does not appear to contain an age private key."
  echo "       Expected a line starting with 'AGE-SECRET-KEY-'" >&2
  exit 1
fi
kubectl create secret generic sops-age \
  --namespace flux-system \
  --from-file="keys.${AGE_PUBKEY}.agekey=${AGE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Step 4: Install the FluxInstance via Helm to start GitOps reconciliation ──
echo ">>> Installing FluxInstance via Helm..."
helm upgrade --install flux \
  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance \
  --namespace flux-system \
  --wait \
  --timeout 10m \
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

# ── Post-bootstrap health check ───────────────────────────────────────────────
# Verify the Flux controllers are running before declaring success.
echo ">>> Waiting for Flux controllers to be ready..."
kubectl wait --namespace flux-system --for=condition=ready pod \
  --selector='app.kubernetes.io/part-of=flux' \
  --timeout=90s || true

# ── Done ──────────────────────────────────────────────────────────────────────
# Everything else is driven by GitOps. The FluxInstance above syncs the
# capi-mgmt/ directory, whose top-level kustomization.yaml wires in the
# infrastructure, capi-providers, addons, and clusters Kustomizations with
# the correct dependsOn ordering. No further imperative steps are required.
echo ""
echo ">>> Bootstrap complete! Flux is now reconciling from ${GIT_REPO_URL}"
echo ">>> Watch progress with: flux get kustomizations --watch"
