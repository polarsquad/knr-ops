#!/usr/bin/env bash
# stage-and-create-cluster.sh — gap-side staging. Runs BEFORE zarf init.
#
# 1. docker-loads every image archive from airgap/archives/ into the host
#    Docker daemon:
#      - kindest/node v1.36.1 (mgmt kind node) and v1.35.0 (CAPD workload
#        nodes) — kind and CAPD `docker run` these directly from the host
#        daemon, outside kubelet, so the Zarf agent cannot rewrite them.
#      - kindest/haproxy (CAPD load balancer) and registry:2 (knr-registry,
#        recreated in Phase 5 for the workload cluster's Flux).
#      - workload-pod-images.tar: flux-operator, flux controllers, podinfo —
#        consumed via preLoadImages by CAPD DevMachineTemplates (Phase 5).
# 2. Creates the kind management cluster (same shape as bootstrap.sh:
#    control-plane node with the Docker socket mounted; NO registry mirror
#    patch — in the gap, pod images reach the node through the Zarf agent's
#    rewrite to the nodeport registry).
#
# Everything here must work with Wi-Fi off.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AIRGAP_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ARCHIVES="$AIRGAP_DIR/archives"

CLUSTER_NAME="${CLUSTER_NAME:-mgmt}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.36.1}"

echo ">>> Loading image archives into the host Docker daemon..."
for tar in "$ARCHIVES"/*.tar; do
  echo "    docker load -i $(basename "$tar")"
  docker load -i "$tar" >/dev/null
done

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo ">>> kind cluster '${CLUSTER_NAME}' already exists; leaving it in place"
else
  echo ">>> Creating kind cluster '${CLUSTER_NAME}' (image ${KIND_NODE_IMAGE})..."
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
EOF
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s

echo ">>> Staged. Next:"
echo "      zarf init archives/zarf-init-arm64-v0.83.0.tar.zst --registry-mode=nodeport --components=\"\" --confirm"
echo "      zarf package deploy zarf-package-knr-ops-airgap-arm64-0.1.0.tar.zst --confirm"
