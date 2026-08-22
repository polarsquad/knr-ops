#!/usr/bin/env bash
# offline-run.sh — autonomous Wi-Fi-off validation of the knr-ops airgap bundle.
#
# This script is designed to run with NO operator and NO LLM/agent attached:
# it waits until the internet is unreachable, runs the full deploy, verifies,
# and writes a PASS/FAIL summary. Everything is logged to $LOG.
#
# Usage (operator):
#   1. an agent (or you) starts this script in the background while online:
#        nohup airgap/scripts/offline-run.sh >/dev/null 2>&1 &
#   2. toggle Wi-Fi OFF within 6 minutes.
#   3. watch:  tail -f /tmp/airgap-offline-run.log
#   4. when the log shows "OFFLINE RUN COMPLETE", toggle Wi-Fi back ON and
#      tell the agent to collect the results.
set -uo pipefail

LOG=/tmp/airgap-offline-run.log
SUMMARY=/tmp/airgap-offline-summary.txt
AIRGAP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARCHIVES="$AIRGAP_DIR/archives"
PACKAGE_INPUT="${1:-$ARCHIVES/zarf-package-knr-ops-airgap-arm64-0.1.0.tar.zst}"
PACKAGE_DIR=$(cd "$(dirname "$PACKAGE_INPUT")" && pwd)
PACKAGE="$PACKAGE_DIR/$(basename "$PACKAGE_INPUT")"

# Resolve the already-installed tools before going offline. This supports both
# the macOS operator workflow and Linux CI without invoking mise in the gap.
ZARF=$(command -v zarf)
FLUX=$(command -v flux)
HELM=$(command -v helm)
KIND=$(command -v kind)
KUBECTL=$(command -v kubectl)
DOCKER=$(command -v docker)
export KUBECONFIG="$HOME/.kube/config"

export CLUSTER_NAME=airgap-mgmt
export REGISTRY_NAME=knr-registry-airgap
export REGISTRY_PORT=5002
MGMT_CTX="kind-airgap-mgmt"
WL_KCFG=/tmp/airgap-wl.kubeconfig

step() { echo ""; echo "===== [$(date +%H:%M:%S)] $* ====="; }
pass() { echo "PASS: $*" | tee -a "$SUMMARY"; }
fail() { echo "FAIL: $*" | tee -a "$SUMMARY"; }

: > "$SUMMARY"
{
step "0. waiting for Wi-Fi to go OFF (internet unreachable)..."
if [ "${SKIP_OFFLINE_CHECK:-0}" = "1" ]; then
  echo "offline connectivity check skipped; external traffic is monitored by the caller"
else
  online_deadline=$(( $(date +%s) + ${OFFLINE_WAIT_SECONDS:-900} ))
  while true; do
    if ! curl -s --max-time 3 https://ghcr.io >/dev/null 2>&1 && \
       ! curl -s --max-time 3 https://registry.k8s.io >/dev/null 2>&1; then
      echo "internet unreachable -> OFFLINE confirmed"
      break
    fi
    if [ "$(date +%s)" -ge "$online_deadline" ]; then
      echo "TIMEOUT waiting for Wi-Fi off; aborting."
      fail "never went offline within ${OFFLINE_WAIT_SECONDS:-900}s"
      exit 1
    fi
    sleep 5
  done
fi

step "1. stage: docker load + kind create + seed registry"
if CLUSTER_NAME=$CLUSTER_NAME REGISTRY_NAME=$REGISTRY_NAME REGISTRY_PORT=$REGISTRY_PORT \
     "$AIRGAP_DIR/scripts/stage-and-create-cluster.sh"; then
  pass "stage (docker load, kind create, registry seed)"
else
  fail "stage-and-create-cluster.sh"
  exit 1
fi

step "2. zarf init"
if ( cd "$AIRGAP_DIR" && "$ZARF" init "$ARCHIVES/zarf-init-arm64-v0.83.0.tar.zst" \
       --registry-mode=nodeport --components="" --confirm ); then
  pass "zarf init"
else
  fail "zarf init"
  exit 1
fi

step "3. zarf package deploy"
if ( cd "$AIRGAP_DIR" && "$ZARF" package deploy "$PACKAGE" --confirm ); then
  pass "zarf package deploy"
else
  fail "zarf package deploy"
  exit 1
fi

step "4. verify mgmt substrate (all non-baked images from 127.0.0.1:31999)"
sleep 20
nonzarf=$("$KUBECTL" --context "$MGMT_CTX" get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
  | grep -v "127.0.0.1:31999" \
  | grep -vE "registry.k8s.io/(coredns|kube-|etcd|pause)|docker.io/kindest/" \
  | sort -u)
if [ -z "$nonzarf" ]; then
  pass "all mgmt workload images resolve from the Zarf internal registry"
else
  fail "mgmt images not from Zarf registry: $nonzarf"
fi

step "5. verify config artifact sync (OCIRepository Ready from Zarf registry)"
ociready=$("$KUBECTL" --context "$MGMT_CTX" -n flux-system get ocirepository flux-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
ociurl=$("$KUBECTL" --context "$MGMT_CTX" -n flux-system get ocirepository flux-system -o jsonpath='{.spec.url}' 2>/dev/null)
if [ "$ociready" = "True" ] && echo "$ociurl" | grep -q "zarf-docker-registry"; then
  pass "OCIRepository Ready from internal registry ($ociurl)"
else
  fail "OCIRepository not Ready/internal (ready=$ociready url=$ociurl)"
fi

step "6. verify mgmt Flux kustomizations"
"$KUBECTL" --context "$MGMT_CTX" -n flux-system wait kustomization/flux-system \
  --for=condition=Ready --timeout=10m >/dev/null 2>&1 \
  && pass "flux-system kustomization Ready" || fail "flux-system kustomization"

step "7. verify CAPD workload cluster provisions offline"
wl_ready=$("$KUBECTL" --context "$MGMT_CTX" get clusters.cluster.x-k8s.io airgap-wl -n default \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
# wait up to 10m for Available
for i in $(seq 1 40); do
  [ "$wl_ready" = "True" ] && break
  sleep 15
  wl_ready=$("$KUBECTL" --context "$MGMT_CTX" get clusters.cluster.x-k8s.io airgap-wl -n default \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
done
if [ "$wl_ready" = "True" ]; then
  pass "workload cluster airgap-wl Available"
else
  fail "workload cluster airgap-wl not Available"
fi

step "8. verify workload nodes Ready + per-cluster Flux + podinfo"
port=$("$DOCKER" port airgap-wl-lb 6443/tcp 2>/dev/null | head -1 | sed 's/.*://')
if [ -n "$port" ]; then
  "$KUBECTL" --context "$MGMT_CTX" get secret -n default airgap-wl-kubeconfig \
    -o jsonpath='{.data.value}' 2>/dev/null | base64 -d > "$WL_KCFG"
  "$KUBECTL" config set-cluster airgap-wl --server="https://127.0.0.1:${port}" --kubeconfig="$WL_KCFG" >/dev/null 2>&1
  nodes_ready=$("$KUBECTL" --kubeconfig="$WL_KCFG" get nodes --no-headers 2>/dev/null | grep -c " Ready ")
  [ "${nodes_ready:-0}" -ge 2 ] && pass "workload nodes Ready ($nodes_ready)" || fail "workload nodes Ready=$nodes_ready"

  wlf=$("$KUBECTL" --kubeconfig="$WL_KCFG" -n flux-system get ocirepository flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [ "$wlf" = "True" ] && pass "workload Flux sync Ready from knr-registry" || fail "workload Flux sync ready=$wlf"

  podinfo=$("$KUBECTL" --kubeconfig="$WL_KCFG" -n podinfo get pods --no-headers 2>/dev/null | grep -c " Running ")
  for i in $(seq 1 20); do
    [ "${podinfo:-0}" -ge 1 ] && break
    sleep 15
    podinfo=$("$KUBECTL" --kubeconfig="$WL_KCFG" -n podinfo get pods --no-headers 2>/dev/null | grep -c " Running ")
  done
  [ "${podinfo:-0}" -ge 1 ] && pass "podinfo Running on workload cluster" || fail "podinfo not Running"
else
  fail "could not determine airgap-wl LB port"
fi

step "OFFLINE RUN COMPLETE"
if grep -q "^FAIL" "$SUMMARY"; then
  echo "RESULT: FAIL"
  cat "$SUMMARY"
  exit 1
else
  echo "RESULT: PASS - full airgap deploy verified with no internet"
  cat "$SUMMARY"
  exit 0
fi
} 2>&1 | tee "$LOG"
