#!/usr/bin/env bash
# teardown.sh – Destroy all infrastructure created by bootstrap.sh, in reverse order.
#
# Destruction order:
#   1. Suspend Flux reconciliation (prevent re-creation of deleted resources)
#   2. Delete CAPI workload clusters (CAPA tears down all AWS resources per cluster)
#   3. Wait for AWS resources to be fully deprovisioned
#   4. Delete CAPI providers (operator deprovisions controllers)
#   5. Uninstall the FluxInstance Helm release
#   6. Uninstall the Flux Operator Helm release
#   7. Delete the GitHub App, SOPS age, and AWS credentials secrets
#   8. Delete the kind management cluster
set -euo pipefail

# ── Ensure kind cluster is always deleted, even if the script exits early ─────
# Registered here so it fires on any exit (clean, error, or signal).
# kind delete cluster is idempotent and safe to run multiple times.
_teardown_kind() {
  echo ""
  info "Deleting kind management cluster 'capi-mgmt' (exit trap)..."
  kind delete cluster --name capi-mgmt 2>&1 \
    && success "kind cluster 'capi-mgmt' deleted" \
    || warn "kind cluster 'capi-mgmt' could not be deleted – it may already be gone"
}
trap _teardown_kind EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo ">>> $*"; }
success() { echo "✓   $*"; }
warn()    { echo "!   $*" >&2; }

# How long (seconds) to wait for CAPI clusters to be fully deleted before giving up.
CLUSTER_DELETE_TIMEOUT="${CLUSTER_DELETE_TIMEOUT:-1200}"
# How long (seconds) to wait for CAPI providers to be removed.
PROVIDER_DELETE_TIMEOUT="${PROVIDER_DELETE_TIMEOUT:-300}"

# ── Prerequisites check ───────────────────────────────────────────────────────
for cmd in kind helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found in PATH"; exit 1; }
done

# Verify the management cluster is reachable before proceeding.
if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  warn "Cannot reach the management cluster. It may already be gone."
  warn "If the kind cluster still exists, run: kind delete cluster --name capi-mgmt"
  exit 1
fi

# ── Step 1: Suspend Flux reconciliation ───────────────────────────────────────
# Prevents Flux from re-applying manifests while we tear resources down.
info "Suspending Flux Kustomizations to prevent re-reconciliation..."
if kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system >/dev/null 2>&1; then
  kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system \
    -o name 2>/dev/null \
    | xargs --no-run-if-empty kubectl patch \
        -n flux-system --type=merge \
        -p '{"spec":{"suspend":true}}' \
    || warn "Could not suspend some Kustomizations – continuing anyway"
  success "Flux Kustomizations suspended"
else
  warn "No Flux Kustomizations found – skipping suspension"
fi

# ── Step 2: Delete CAPI workload clusters ─────────────────────────────────────
# Deleting a CAPI Cluster resource triggers CAPA to destroy all associated AWS
# resources (VPC, subnets, NAT gateways, EKS cluster, managed node groups).
info "Discovering CAPI Cluster resources..."
if kubectl api-resources --api-group=cluster.x-k8s.io >/dev/null 2>&1; then
  CLUSTERS=$(kubectl get clusters.cluster.x-k8s.io -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  if [ -n "$CLUSTERS" ]; then
    info "Deleting CAPI workload clusters (AWS teardown will begin in each region)..."
    echo "$CLUSTERS" | while IFS='/' read -r ns name; do
      info "  Deleting cluster: $name (namespace: $ns)"
      kubectl delete cluster.cluster.x-k8s.io "$name" -n "$ns" --ignore-not-found
    done

    # ── Step 3: Wait for AWS resources to be deprovisioned ────────────────────
    # CAPA must finish deleting VPCs, EKS clusters, node groups, etc. before we
    # destroy the management cluster — otherwise the CAPA controller is gone and
    # AWS resources are orphaned.
    info "Waiting up to ${CLUSTER_DELETE_TIMEOUT}s for all CAPI clusters to be deleted..."
    info "(This typically takes 15–25 minutes while CAPA tears down AWS resources)"
    ELAPSED=0
    INTERVAL=30
    while true; do
      REMAINING=$(kubectl get clusters.cluster.x-k8s.io -A \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
      if [ "$REMAINING" -eq 0 ]; then
        success "All CAPI clusters deleted"
        break
      fi
      if [ "$ELAPSED" -ge "$CLUSTER_DELETE_TIMEOUT" ]; then
        warn "Timed out waiting for CAPI clusters to be deleted after ${ELAPSED}s"
        warn "The following clusters still exist:"
        kubectl get clusters.cluster.x-k8s.io -A --no-headers 2>/dev/null || true
        warn "AWS resources may be orphaned. Check the AWS console and delete manually."
        warn "Continuing teardown of the management cluster..."
        break
      fi
      info "  ${REMAINING} cluster(s) still deleting... (${ELAPSED}s elapsed, checking again in ${INTERVAL}s)"
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
    done
  else
    info "No CAPI clusters found – skipping cluster deletion"
  fi
else
  warn "CAPI CRDs not present – skipping cluster deletion"
fi

# ── Step 4: Delete CAPI providers ─────────────────────────────────────────────
# Removing the provider CRs causes the CAPI Operator to uninstall the provider
# controllers and their associated namespaces.
info "Deleting CAPI providers..."
if kubectl api-resources --api-group=operator.cluster.x-k8s.io >/dev/null 2>&1; then
  for kind in addonproviders controlplaneproviders bootstrapproviders infrastructureproviders coreproviders; do
    ITEMS=$(kubectl get "$kind.operator.cluster.x-k8s.io" -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    if [ -n "$ITEMS" ]; then
      echo "$ITEMS" | while IFS='/' read -r ns name; do
        info "  Deleting $kind: $name (namespace: $ns)"
        kubectl delete "$kind.operator.cluster.x-k8s.io" "$name" -n "$ns" --ignore-not-found
      done
    fi
  done

  info "Waiting up to ${PROVIDER_DELETE_TIMEOUT}s for CAPI providers to be removed..."
  ELAPSED=0
  INTERVAL=15
  while true; do
    REMAINING=0
    for kind in addonproviders controlplaneproviders bootstrapproviders infrastructureproviders coreproviders; do
      COUNT=$(kubectl get "$kind.operator.cluster.x-k8s.io" -A \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
      REMAINING=$((REMAINING + COUNT))
    done
    if [ "$REMAINING" -eq 0 ]; then
      success "All CAPI providers removed"
      break
    fi
    if [ "$ELAPSED" -ge "$PROVIDER_DELETE_TIMEOUT" ]; then
      warn "Timed out waiting for CAPI providers to be removed – continuing anyway"
      break
    fi
    info "  ${REMAINING} provider(s) still removing... (${ELAPSED}s elapsed)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
  done
else
  warn "CAPI Operator CRDs not present – skipping provider deletion"
fi

# ── Step 5: Uninstall FluxInstance Helm release ───────────────────────────────
info "Uninstalling FluxInstance Helm release..."
if helm status flux -n flux-system >/dev/null 2>&1; then
  helm uninstall flux --namespace flux-system --wait --timeout 5m0s
  success "FluxInstance Helm release uninstalled"
else
  warn "FluxInstance Helm release 'flux' not found – skipping"
fi

# ── Step 6: Uninstall Flux Operator Helm release ──────────────────────────────
info "Uninstalling Flux Operator Helm release..."
if helm status flux-operator -n flux-system >/dev/null 2>&1; then
  helm uninstall flux-operator --namespace flux-system --wait --timeout 5m0s
  success "Flux Operator Helm release uninstalled"
else
  warn "Flux Operator Helm release 'flux-operator' not found – skipping"
fi

# ── Step 7: Delete the GitHub App credentials secret ─────────────────────────
info "Deleting GitHub App and SOPS age secrets..."
kubectl delete secret flux-github-app -n flux-system --ignore-not-found
kubectl delete secret sops-age -n flux-system --ignore-not-found
# The aws-credentials secret is GitOps-managed (decrypted by Flux), but remove
# it explicitly in case Flux was uninstalled before it could be pruned.
kubectl delete secret aws-credentials -n capa-system --ignore-not-found
success "Secrets deleted (or were already absent)"

# ── Step 8: Delete the kind management cluster ────────────────────────────────
# Handled by the EXIT trap registered at the top of the script, so it always
# runs regardless of whether earlier steps fail or the script exits early.
# Disarm the trap here for the normal-exit path so it doesn't double-fire.
trap - EXIT
info "Deleting kind management cluster 'capi-mgmt'..."
kind delete cluster --name capi-mgmt 2>&1 \
  && success "kind cluster 'capi-mgmt' deleted" \
  || warn "kind cluster 'capi-mgmt' could not be deleted – it may already be gone"

echo ""
echo "✓ Teardown complete."
echo ""
echo "  Reminder: the clusterawsadm IAM CloudFormation stack is intentionally"
echo "  NOT deleted by this script, as it may be shared across environments."
echo "  To remove it manually:"
echo "    clusterawsadm bootstrap iam delete-cloudformation-stack --region <region>"
