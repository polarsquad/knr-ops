#!/usr/bin/env bash
# bootstrap.sh – One-time imperative bootstrap for the management cluster.
# Everything after this script runs is driven by GitOps (Flux).
set -euo pipefail

PROFILE="${KNR_OPS_PROFILE:-${1:-aws}}"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/polarsquad/knr-ops}"
GIT_BRANCH="${GIT_BRANCH:-main}"

preflight_checks() {
  case "$PROFILE" in
    local-host|aws) ;;
    *)
      echo "ERROR: unsupported profile '$PROFILE' (expected 'local-host' or 'aws')" >&2
      exit 1
      ;;
  esac

  if [ -z "$GIT_BRANCH" ]; then
    echo "ERROR: GIT_BRANCH must not be empty" >&2
    exit 1
  fi

  for cmd in curl kind helm kubectl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found in PATH"; exit 1; }
  done

  # CONTAINER_ENGINE may be set to "docker" or "podman" to skip auto-detection.
  if [ -z "${CONTAINER_ENGINE:-}" ]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      # The podman-docker shim makes `docker` an alias for podman — detect that.
      if docker --version 2>/dev/null | grep -qi podman; then
        CONTAINER_ENGINE=podman
      else
        CONTAINER_ENGINE=docker
      fi
    elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
      CONTAINER_ENGINE=podman
    else
      echo "ERROR: No running container engine found (tried docker and podman)" >&2
      exit 1
    fi
  fi

  case "$CONTAINER_ENGINE" in
    docker)
      docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon not running" >&2; exit 1; }
      ENGINE_SOCK="/var/run/docker.sock"
      ;;
    podman)
      podman info >/dev/null 2>&1 || { echo "ERROR: Podman is not running (is 'podman machine' started?)" >&2; exit 1; }
      export KIND_EXPERIMENTAL_PROVIDER=podman
      ENGINE_SOCK="$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)"
      ENGINE_SOCK="${ENGINE_SOCK#unix://}"
      if [ -z "$ENGINE_SOCK" ]; then
        ENGINE_SOCK="/run/podman/podman.sock"
        echo ">>> WARNING: Could not detect the podman API socket path; assuming ${ENGINE_SOCK}" >&2
      fi
      ;;
    *)
      echo "ERROR: Unsupported CONTAINER_ENGINE '${CONTAINER_ENGINE}' (expected 'docker' or 'podman')" >&2
      exit 1
      ;;
  esac

  case "$GIT_REPO_URL" in
    https://github.com/*/*) ;;
    *)
      echo "ERROR: GIT_REPO_URL must be an HTTPS GitHub repository URL" >&2
      exit 1
      ;;
  esac

  GITHUB_REPO="${GIT_REPO_URL#https://github.com/}"
  GITHUB_REPO="${GITHUB_REPO%/}"
  GITHUB_REPO="${GITHUB_REPO%.git}"

  local github_api_response github_api_status github_api_body github_branch_status github_branch_path

  # A public repository is visible without credentials. GitHub returns 404 for
  # a private repository without credentials.
  github_api_response="$(curl -sS -H 'Accept: application/vnd.github+json' \
    -w $'\n%{http_code}' "https://api.github.com/repos/${GITHUB_REPO}" || true)"
  github_api_status="${github_api_response##*$'\n'}"
  github_api_body="${github_api_response%$'\n'*}"
  case "$github_api_status" in
    200)
      if printf '%s' "$github_api_body" | grep -q '"private"[[:space:]]*:[[:space:]]*true'; then
        GIT_REPO_PRIVATE=true
      else
        GIT_REPO_PRIVATE=false
      fi
      ;;
    404)
      : "${GITHUB_TOKEN:?GITHUB_TOKEN must be set for the private GitHub repository (a PAT with read access)}"
      GITHUB_AUTH="Authorization: Bearer ${GITHUB_TOKEN}"
      GIT_REPO_PRIVATE=true
      ;;
    *)
      echo "ERROR: could not inspect GitHub repository '${GIT_REPO_URL}' (HTTP ${github_api_status})" >&2
      exit 1
      ;;
  esac

  if [ "$GIT_REPO_PRIVATE" = true ]; then
    # Basic-auth secret consumed by Flux's source-controller.
    GITHUB_USER="${GITHUB_USER:-git}"
  fi

  github_branch_path="${GIT_BRANCH//\//%2F}"
  if [ "$GIT_REPO_PRIVATE" = true ]; then
    github_branch_status="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "${GITHUB_AUTH}" \
      "https://api.github.com/repos/${GITHUB_REPO}/branches/${github_branch_path}" || true)"
  else
    github_branch_status="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/${GITHUB_REPO}/branches/${github_branch_path}" || true)"
  fi
  if [ "$github_branch_status" != 200 ]; then
    if [ "$GIT_REPO_PRIVATE" = true ]; then
      echo "ERROR: GITHUB_TOKEN cannot access branch '${GIT_BRANCH}' in repository '${GIT_REPO_URL}' (HTTP ${github_branch_status})" >&2
    else
      echo "ERROR: GitHub branch '${GIT_BRANCH}' was not found in repository '${GIT_REPO_URL}' (HTTP ${github_branch_status})" >&2
    fi
    exit 1
  fi

  if [ "$PROFILE" = aws ]; then
    AGE_KEY_FILE="${AGE_KEY_FILE:-age.agekey}"
    if [ ! -f "$AGE_KEY_FILE" ]; then
      echo "ERROR: age key file not found at '$AGE_KEY_FILE'." >&2
      echo "       Generate one with:  mise run sops-keygen" >&2
      echo "       and add its PUBLIC key to .sops.yaml. See docs/secrets.md." >&2
      exit 1
    fi
    AGE_PUBKEY="${AGE_PUBLIC_KEY:-$(grep '^# public key:' "${AGE_KEY_FILE}" 2>/dev/null | sed 's/^# public key: //')}"
    if [ -z "$AGE_PUBKEY" ]; then
      echo "ERROR: Cannot determine age public key from '${AGE_KEY_FILE}' or from AGE_PUBLIC_KEY env var." >&2
      echo "       Set AGE_PUBLIC_KEY in .env, or regenerate the key with: mise run sops-keygen" >&2
      exit 1
    fi
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
  fi
}

preflight_checks
echo ">>> Using container engine: ${CONTAINER_ENGINE} (socket: ${ENGINE_SOCK})"

# ── Step 1: Create the kind management cluster ────────────────────────────────
echo ">>> Creating kind cluster 'mgmt'..."
# Check if cluster already exists and delete it (idempotent)
if kind get clusters 2>/dev/null | grep -q "^mgmt$"; then
  echo ">>> Cluster 'mgmt' already exists – recreating..."
  kind delete cluster --name mgmt
fi
# The engine socket is mounted at the Docker socket path inside the node, so
# consumers always find a Docker-compatible API at /var/run/docker.sock
# (podman serves the Docker-compatible API on its own socket).
kind create cluster --name mgmt --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${ENGINE_SOCK}
        containerPath: /var/run/docker.sock
EOF

echo ">>> Waiting for cluster node to be ready..."
# Explicitly switch kubectl to use the kind cluster context
kubectl config use-context kind-mgmt
kubectl wait --for=condition=Ready node --all --timeout=120s

# ── Step 2: Install the Flux Operator ────────────────────────────────────────
echo ">>> Installing Flux Operator..."
ANONYMOUS_REGISTRY_CONFIG="$(mktemp)"
printf '{}\n' > "$ANONYMOUS_REGISTRY_CONFIG"
cleanup_registry_config() {
  rm -f "$ANONYMOUS_REGISTRY_CONFIG"
}
trap cleanup_registry_config EXIT
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace \
  --wait \
  --registry-config "$ANONYMOUS_REGISTRY_CONFIG"

# ── Step 3: Create GitHub PAT credentials secret ─────────────────────────────
# Basic-auth secret consumed by Flux's source-controller to clone a private repo.
if [ "$GIT_REPO_PRIVATE" = true ]; then
  echo ">>> Creating GitHub PAT credentials secret in flux-system..."
  kubectl create secret generic flux-github-pat \
    --namespace flux-system \
    --from-literal=username="${GITHUB_USER}" \
    --from-literal=password="${GITHUB_TOKEN}"
fi

# ── Step 3b: Create SOPS age decryption key secret ────────────────────────────
# Flux's kustomize-controller uses this key to decrypt *.sops.yaml manifests
# (such as the CAPA AWS credentials) during reconciliation. Flux scans the
# Secret for keys matching the pattern `keys.<public-key>.agekey` — each
# matching key is passed to the age library for decryption.
# AGE_PUBLIC_KEY can be overridden via .env to match a specific .sops.yaml.
if [ "$PROFILE" = aws ]; then
  echo ">>> Creating sops-age decryption secret in flux-system..."
  # Remove any existing sops-age secret to avoid stale keys from previous bootstrap runs
  kubectl delete secret sops-age -n flux-system --ignore-not-found
  kubectl create secret generic sops-age \
    --namespace flux-system \
    --from-file="keys.${AGE_PUBKEY}.agekey=${AGE_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ── Step 4: Install the FluxInstance via Helm ────────────────────────────────
echo ">>> Installing FluxInstance via Helm..."
FLUX_INSTANCE_ARGS=(
  --set instance.cluster.type=kubernetes
  --set instance.cluster.size=small
  --set instance.cluster.multitenant=false
  --set instance.cluster.networkPolicy=true
  --set instance.cluster.domain=cluster.local
  --registry-config "$ANONYMOUS_REGISTRY_CONFIG"
)
if [ "$PROFILE" = aws ]; then
  FLUX_INSTANCE_ARGS+=(
    --set instance.sync.kind=GitRepository
    --set instance.sync.url="${GIT_REPO_URL}"
    --set instance.sync.ref="refs/heads/${GIT_BRANCH}"
    --set instance.sync.path=mgmt/aws
  )
  if [ "$GIT_REPO_PRIVATE" = true ]; then
    FLUX_INSTANCE_ARGS+=(--set instance.sync.pullSecret=flux-github-pat)
  fi
elif [ "$PROFILE" = local-host ]; then
  FLUX_INSTANCE_ARGS+=(
    --set instance.sync.kind=GitRepository
    --set instance.sync.url="${GIT_REPO_URL}"
    --set instance.sync.ref="refs/heads/${GIT_BRANCH}"
    --set instance.sync.path=mgmt/docker
  )
  if [ "$GIT_REPO_PRIVATE" = true ]; then
    FLUX_INSTANCE_ARGS+=(--set instance.sync.pullSecret=flux-github-pat)
  fi
fi
helm upgrade --install flux \
  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance \
  --namespace flux-system \
  --wait \
  --timeout 10m \
  "${FLUX_INSTANCE_ARGS[@]}"

# ── Post-bootstrap health check ───────────────────────────────────────────────
# Verify the Flux controllers are running before declaring success.
echo ">>> Waiting for Flux controllers to be ready..."
kubectl wait --namespace flux-system --for=condition=ready pod \
  --selector='app.kubernetes.io/part-of=flux' \
  --timeout=90s || true

# ── Done ──────────────────────────────────────────────────────────────────────
# Everything else is driven by GitOps. The FluxInstance above syncs the
# profile-specific directory, whose top-level kustomization.yaml wires in the
# provider and cluster resources. No further imperative steps are required.
echo ""
if [ "$PROFILE" = aws ]; then
  echo ">>> Bootstrap complete! Flux is now reconciling from ${GIT_REPO_URL}"
  echo ">>> Watch progress with: flux get kustomizations --watch"
else
  echo ">>> Local-host profile complete: Flux is reconciling ${GIT_REPO_URL}@${GIT_BRANCH}/mgmt/docker"
fi
