#!/usr/bin/env bash
# bootstrap.sh – One-time imperative bootstrap for the management cluster.
# Everything after this script runs is driven by GitOps (Flux).
set -euo pipefail

PROFILE="${KNR_OPS_PROFILE:-${1:-aws}}"
GIT_BRANCH="main"
REGISTRY_NAME="knr-registry"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_READY_RETRIES="${REGISTRY_READY_RETRIES:-120}"
LOCAL_RECONCILE_TIMEOUT="${LOCAL_RECONCILE_TIMEOUT:-15m}"

preflight_checks() {
  case "$PROFILE" in
    local-host|aws) ;;
    *)
      echo "ERROR: unsupported profile '$PROFILE' (expected 'local-host' or 'aws')" >&2
      exit 1
      ;;
  esac

  for cmd in curl kind helm kubectl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found in PATH"; exit 1; }
  done

  if [ "$PROFILE" = local-host ]; then
    command -v mise >/dev/null 2>&1 \
      || { echo "ERROR: mise not found in PATH (required to publish the initial OCI artifact)"; exit 1; }
  fi

  if [ "$PROFILE" = aws ]; then
    : "${GITHUB_TOKEN:?GITHUB_TOKEN must be set (a PAT with read access to the repo)}"
    : "${GIT_REPO_URL:?GIT_REPO_URL must be set}"
    # GITHUB_USER is used in the Flux GitHub secret for repo clone authentication
    GITHUB_USER="${GITHUB_USER:-git}"

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
    GITHUB_AUTH="Authorization: Bearer ${GITHUB_TOKEN}"
    github_branch_path="${GIT_BRANCH//\//%2F}"
    github_branch_status="$(curl -sS -o /dev/null -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "${GITHUB_AUTH}" \
      "https://api.github.com/repos/${GITHUB_REPO}/branches/${github_branch_path}" || true)"
    if [ "$github_branch_status" != 200 ]; then
      echo "ERROR: GitHub repository or branch '${GIT_BRANCH}' is unavailable at '${GIT_REPO_URL}' (HTTP ${github_branch_status})" >&2
      exit 1
    fi

    AGE_KEY_FILE="${AGE_KEY_FILE:-age.agekey}"
    if [ ! -f "$AGE_KEY_FILE" ]; then
      echo "ERROR: age key file not found at '$AGE_KEY_FILE'." >&2
      echo "       Generate one with:  mise run sops-keygen" >&2
      echo "       and add its PUBLIC key to .sops.yaml. See docs/secrets.md." >&2
      exit 1
    fi
    # Validate age key file format first (before attempting to extract the public key).
    # This avoids silent grep failure if the file is malformed.
    AGE_CONTENT=$(cat "${AGE_KEY_FILE}")
    missing_fields=""
    echo "$AGE_CONTENT" | grep -q '^# created:' 2>/dev/null || missing_fields="${missing_fields}# created: header, "
    echo "$AGE_CONTENT" | grep -q '^# public key:' 2>/dev/null || missing_fields="${missing_fields}# public key: comment, "
    echo "$AGE_CONTENT" | grep -q '^AGE-SECRET-KEY-' 2>/dev/null || missing_fields="${missing_fields}AGE-SECRET-KEY- line, "

    if [ -n "$missing_fields" ]; then
      echo "ERROR: '${AGE_KEY_FILE}' is not a valid age key file." >&2
      echo "       Missing: ${missing_fields%, }" >&2
      exit 1
    fi
    # Now safely extract the public key (validation already passed).
    AGE_PUBKEY="${AGE_PUBLIC_KEY:-$(echo "$AGE_CONTENT" | grep '^# public key:' | sed 's/^# public key: //')}"
    if [ -z "$AGE_PUBKEY" ]; then
      echo "ERROR: Cannot determine age public key from '${AGE_KEY_FILE}' or from AGE_PUBLIC_KEY env var." >&2
      echo "       Set AGE_PUBLIC_KEY in .env, or regenerate the key with: mise run sops-keygen" >&2
      exit 1
    fi
  fi

  # Detect and select a running container engine. Note: when using podman via the docker CLI
  # shim (e.g., on macOS), `docker --version` reports podman; we check for that case first.
  if [ -z "${CONTAINER_ENGINE:-}" ]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
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
# Mount the host's container engine socket into the kind node at the standard Docker
# socket path. This ensures all in-cluster components can access a Docker-compatible API
# at /var/run/docker.sock, whether the backend is Docker or Podman (which exposes a
# Docker-compatible socket). This is essential for building and loading container images.
KIND_REGISTRY_PATCH=""
if [ "$PROFILE" = local-host ]; then
  KIND_REGISTRY_PATCH="containerdConfigPatches:
  - |-
    [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"localhost:${REGISTRY_PORT}\"]
      endpoint = [\"http://${REGISTRY_NAME}:5000\"]"
fi
kind create cluster --name mgmt --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
${KIND_REGISTRY_PATCH}
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

# ── Step 1.5: Bootstrap local container registry (local-host profile only) ────
if [ "$PROFILE" = local-host ]; then
  echo ">>> Bootstrapping local container registry..."

  # Check if registry already exists
  if ! $CONTAINER_ENGINE ps -a --filter "name=^${REGISTRY_NAME}$" | grep -q "${REGISTRY_NAME}"; then
    # Create registry container
    echo "    Creating registry container '${REGISTRY_NAME}'..."
    $CONTAINER_ENGINE run -d \
      --name "$REGISTRY_NAME" \
      --network kind \
      -p "127.0.0.1:${REGISTRY_PORT}:5000" \
      registry:2 >/dev/null
    echo "    Registry created and running: localhost:${REGISTRY_PORT}"
  else
    # Check if registry is running, restart if needed
    if ! $CONTAINER_ENGINE ps --filter "name=^${REGISTRY_NAME}$" | grep -q "${REGISTRY_NAME}"; then
      echo "    Restarting stopped registry..."
      $CONTAINER_ENGINE start "$REGISTRY_NAME" >/dev/null
      echo "    Registry restarted: localhost:${REGISTRY_PORT}"
    else
      echo "    Registry already running: localhost:${REGISTRY_PORT}"
    fi
  fi

  echo ">>> Waiting for local registry API at localhost:${REGISTRY_PORT}..."
  if ! curl --fail --silent --show-error \
    --retry "$REGISTRY_READY_RETRIES" \
    --retry-connrefused \
    --retry-delay 1 \
    "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null; then
    echo "ERROR: local registry did not become ready at localhost:${REGISTRY_PORT}" >&2
    exit 1
  fi

  # Configure kind nodes to access the registry via the hostname
  # Add a configmap to tell the cluster about the local registry
  kubectl create configmap local-registry-config \
    --from-literal=registry-url="${REGISTRY_NAME}:5000" \
    --namespace kube-system

  echo ">>> Publishing initial OCI artifact from the local Git checkout..."
  mise -E local-host run oci-push
  echo ">>> Initial OCI artifact is available at oci://localhost:${REGISTRY_PORT}/${OCI_REPOSITORY:-knr-ops}:${OCI_TAG:-latest}"
fi

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
# Basic-auth secret consumed by Flux's source-controller to clone the repo.
if [ "$PROFILE" = aws ]; then
  echo ">>> Creating GitHub PAT credentials secret in flux-system..."
  kubectl create secret generic flux-github-pat \
    --namespace flux-system \
    --from-literal=username="${GITHUB_USER}" \
    --from-literal=password="${GITHUB_TOKEN}"

# ── Step 3b: Create SOPS age decryption key secret ────────────────────────────
# Flux's kustomize-controller uses this key to decrypt *.sops.yaml manifests
# (such as the CAPA AWS credentials) during reconciliation. Flux scans the
# Secret for keys matching the pattern `keys.<public-key>.agekey` — each
# matching key is passed to the age library for decryption.
# Note: the age key file and public key are already validated in preflight_checks.
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
    --set instance.sync.ref=refs/heads/main
    --set instance.sync.path=mgmt/aws
    --set instance.sync.pullSecret=flux-github-pat
  )
else
  FLUX_INSTANCE_ARGS+=(
    --set instance.sync.kind=OCIRepository
    --set instance.sync.url="oci://${REGISTRY_NAME}:5000/${OCI_REPOSITORY:-knr-ops}"
    --set instance.sync.ref="${OCI_TAG:-latest}"
    --set instance.sync.path=mgmt/local-host
    --set-json 'instance.kustomize.patches=[{"patch":"- op: add\n  path: /spec/insecure\n  value: true","target":{"kind":"OCIRepository"}}]'
  )
fi
# Helm 4's watcher strategy treats the FluxInstance's transient InProgress
# condition as a terminal failure. Use the legacy chart-resource wait here,
# then wait explicitly for the operator-owned Ready condition below.
helm upgrade --install flux \
  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance \
  --namespace flux-system \
  --wait=legacy \
  --timeout 10m \
  "${FLUX_INSTANCE_ARGS[@]}"

echo ">>> Waiting for FluxInstance reconciliation to complete..."
kubectl wait fluxinstance/flux \
  --namespace flux-system \
  --for=condition=Ready \
  --timeout=10m

# ── Post-bootstrap health check ───────────────────────────────────────────────
# Verify the Flux controllers are running before declaring success.
echo ">>> Waiting for Flux controllers to be ready..."
kubectl wait --namespace flux-system --for=condition=ready pod \
  --selector='app.kubernetes.io/part-of=flux' \
  --timeout=90s || true

# ── Step 5: Watch local-host reconciliation ──────────────────────────────────
# Stream the GitOps handoff in the bootstrap terminal for the local profile.
# The final Kustomization is created by the OCI root, so wait for it to appear
# before starting the progress watcher or asking kubectl to wait for readiness.
# Matching the watch timeout to the authoritative readiness timeout prevents
# the progress display from reporting a misleading early timeout.
if [ "$PROFILE" = local-host ]; then
  echo ""
  echo ">>> Step 5: Flux reconciliation progress"
  reconcile_discovery_attempts=0
  until kubectl get kustomization flux-apps \
      --namespace flux-system >/dev/null 2>&1; do
    reconcile_discovery_attempts=$((reconcile_discovery_attempts + 1))
    if [ "$reconcile_discovery_attempts" -ge 60 ]; then
      echo "ERROR: flux-apps Kustomization was not created within 2 minutes" >&2
      flux get kustomizations
      exit 1
    fi
    sleep 2
  done

  echo ">>> Watching until the local workload cluster and Flux addons are ready..."
  flux get kustomizations --watch --timeout="$LOCAL_RECONCILE_TIMEOUT" &
  flux_watch_pid=$!
  cleanup_flux_watch() {
    kill "$flux_watch_pid" >/dev/null 2>&1 || true
    wait "$flux_watch_pid" >/dev/null 2>&1 || true
  }
  trap 'cleanup_flux_watch; cleanup_registry_config' EXIT

  if ! kubectl wait kustomization/flux-apps \
      --namespace flux-system \
      --for=condition=Ready \
      --timeout="$LOCAL_RECONCILE_TIMEOUT"; then
    echo "ERROR: local-host reconciliation did not complete within ${LOCAL_RECONCILE_TIMEOUT}" >&2
    flux get kustomizations
    exit 1
  fi
  cleanup_flux_watch
  trap cleanup_registry_config EXIT

  echo ""
  echo ">>> Workload cluster Flux reconciliation errors"
  workload_kubeconfig="$(mktemp)"
  workload_flux_log_pid=""
  cleanup_workload_reconciliation() {
    if [ -n "$workload_flux_log_pid" ]; then
      kill "$workload_flux_log_pid" >/dev/null 2>&1 || true
      wait "$workload_flux_log_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$workload_kubeconfig"
  }
  trap 'cleanup_workload_reconciliation; cleanup_registry_config' EXIT

  clusterctl get kubeconfig local-workload > "$workload_kubeconfig"
  workload_endpoint="$($CONTAINER_ENGINE port local-workload-lb 6443/tcp | head -1)"
  workload_port="${workload_endpoint##*:}"
  case "$workload_port" in
    ''|*[!0-9]*)
      echo "ERROR: cannot determine the local-workload API server port" >&2
      exit 1
      ;;
  esac
  kubectl config set-cluster local-workload \
    --server="https://127.0.0.1:${workload_port}" \
    --kubeconfig="$workload_kubeconfig" >/dev/null

  workload_flux_discovery_attempts=0
  until kubectl --kubeconfig "$workload_kubeconfig" get kustomization flux-system \
      --namespace flux-system >/dev/null 2>&1; do
    workload_flux_discovery_attempts=$((workload_flux_discovery_attempts + 1))
    if [ "$workload_flux_discovery_attempts" -ge 60 ]; then
      echo "ERROR: workload Flux Kustomization was not created within 2 minutes" >&2
      kubectl --kubeconfig "$workload_kubeconfig" get pods \
        --namespace flux-system || true
      exit 1
    fi
    sleep 2
  done

  flux logs \
    --kubeconfig "$workload_kubeconfig" \
    --all-namespaces \
    --follow \
    --level=error \
    --since=10m &
  workload_flux_log_pid=$!

  if ! kubectl --kubeconfig "$workload_kubeconfig" wait kustomization/flux-system \
      --namespace flux-system \
      --for=condition=Ready \
      --timeout="$LOCAL_RECONCILE_TIMEOUT"; then
    echo "ERROR: workload reconciliation did not complete within ${LOCAL_RECONCILE_TIMEOUT}" >&2
    flux get kustomizations \
      --kubeconfig "$workload_kubeconfig" \
      --all-namespaces
    exit 1
  fi
  cleanup_workload_reconciliation
  trap cleanup_registry_config EXIT
fi

# ── Done ──────────────────────────────────────────────────────────────────────
# Everything else is driven by GitOps. The FluxInstance above syncs the
# mgmt/aws/ directory, whose top-level kustomization.yaml wires in the
# infrastructure, capi-providers, addons, and clusters Kustomizations with
# the correct dependsOn ordering. No further imperative steps are required.
echo ""
if [ "$PROFILE" = aws ]; then
  echo ">>> Bootstrap complete! Flux is now reconciling from ${GIT_REPO_URL}"
  echo ">>> Watch progress with: flux get kustomizations --watch"
else
  echo ">>> Local-host profile complete: Flux is reconciling from the local OCI artifact"
  echo ">>> Local registry: localhost:${REGISTRY_PORT} (cluster endpoint: ${REGISTRY_NAME}:5000)"
  echo ">>> OCI source: oci://${REGISTRY_NAME}:5000/${OCI_REPOSITORY:-knr-ops}:${OCI_TAG:-latest} (path: mgmt/local-host)"
  echo ">>> Watch progress with: flux get sources oci --watch"
  echo ">>> No AWS resources were provisioned"
fi
