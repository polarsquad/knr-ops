# Operations

## Prerequisites

Tool versions are pinned in `mise.toml`, which requires mise 2026.8.10 or
newer. With [mise](https://mise.jdx.dev/) installed:

```sh
mise install
```

This provides `kubectl`, `kind`, `helm`, `flux`, `clusterctl`, `go`, `sops`,
`age`, and the `zarf` CLI. The `aws` profile layers on `aws-cli` and
`clusterawsadm` (`mise -E aws install`); the `local-host` profile needs no
extra tools.

You also need:

- A running container engine for kind: Docker, or Podman 5.5+ (auto-detected
  by `bootstrap.sh`; set `CONTAINER_ENGINE=docker|podman` to override).
  For local-host profile: the same engine is used to host the local container
  registry for OCI artifacts.

**AWS profile only:**
- A GitHub personal access token (PAT) with read access to this repository
  (fine-grained with read-only Contents permission, or classic with `repo`
  scope). The Flux Operator chart is pulled anonymously.
- AWS credentials with permission to create EKS clusters, VPCs, and IAM roles.
  For the ACK controllers the same principal additionally needs
  `iam:CreateRole`/`PutRolePolicy`/`GetRole`/`TagRole`,
  `iam:CreateUser`/`PutUserPolicy`/`GetUser`/`GetUserPolicy`/`TagUser`
  (for the `knr-ops-reader` console user), and
  `eks:CreatePodIdentityAssociation`/`DescribePodIdentityAssociation`/
  `DeletePodIdentityAssociation`. The `rds:*` management and
  `secretsmanager:CreateSecret`/`TagResource`/`RotateSecret` permissions
  (managed master passwords) used by the workload clusters' ACK RDS
  controllers are granted through the Git-declared
  `knr-ops-ack-rds-controller` pod-identity role — no extra static
  credentials are required for them.
- The `clusterawsadm` IAM CloudFormation stack provisioned once per account:

  ```sh
  clusterawsadm bootstrap iam create-cloudformation-stack --region eu-north-1
  ```

### AWS service quotas (common first-run blockers)

| Quota | Code | Needed | Why |
|---|---|---|---|
| EC2-VPC Elastic IPs (per region) | `L-0263D0A3` | ≥ 3 free | One EIP per NAT gateway (3 AZs) |
| Running On-Demand G and VT instances | `L-DB2E81BA` | ≥ 4 vCPUs | GPU node pool (g4dn.xlarge); some regions default to **0** |

Request increases with
`aws service-quotas request-service-quota-increase --service-code ec2 --quota-code <code> --desired-value <n> --region <region>`.

## Configuration

Copy the env template and fill it in. `mise` loads `.env` automatically and it
is gitignored:

```sh
cp .env.example .env
$EDITOR .env
```

The Flux Operator chart is pulled anonymously for both profiles. The GitHub PAT,
AWS credentials, and `AWS_REGION` are only needed with the AWS profile.

## Bootstrap

```sh
mise run bootstrap                 # AWS profile
mise -E local-host run bootstrap   # local-host profile
```

> Before the first bootstrap, generate an age key for SOPS (see
> [Secret management](./secrets.md)): `mise run sops-keygen`.

This is the only imperative step. It:

1. Creates the `mgmt` kind cluster.
2. Installs the Flux Operator (Helm).
3. Creates the `flux-github-pat` secret (for Git access) and the `sops-age`
   secret (the age private key Flux uses to decrypt SOPS-encrypted secrets).
4. Installs a `FluxInstance` that syncs `mgmt/aws/` and hands off to GitOps.

Everything downstream — providers, EKS clusters, workload Flux instances, the
ACK operator, IAM role, pod identity bindings, and S3 buckets — reconciles
from Git with no further manual steps.

The local-host profile performs the cluster, Flux Operator, and FluxInstance
steps in the `mgmt` management cluster, but does not create GitHub or SOPS
secrets. Instead, it bootstraps a local Docker Registry container (`registry:2`)
running on the host machine (accessible at `localhost:5001` by default),
publishes the `mgmt/local-host/` and `workload/local-host/` folders as the
initial `knr-ops:latest` OCI
artifact, and configures Flux to reconcile that path from the artifact. Flux
then installs the CAPI core, kubeadm, and Docker infrastructure providers and
creates `local-workload`, a one-control-plane/one-worker Kubernetes cluster in
containers. The management cluster then installs a Flux Operator and
FluxInstance on `local-workload`; that instance reconciles
`workload/local-host/` from the same OCI artifact. CAPD is intended for local
development and testing, not production.

Together, these stages make `local-host` an end-to-end profile: one command
bootstraps the management control plane, publishes and reconciles the OCI
configuration, provisions a workload cluster through CAPI, installs a distinct
Flux control plane on that cluster, and reconciles a reachable Podinfo workload.
It exercises the complete cluster-to-workload GitOps lifecycle locally; only
the AWS-specific infrastructure and ACK resources are outside its scope.

**OCI Registry (local-host profile only):**
- Provides a local container registry for development workflows
- Enables developers to build and push OCI artifacts from git checkouts
- Flux syncs and deploys the OCI artifact without external dependencies
- Configurable via `REGISTRY_PORT` env var (defaults to 5001)
- Idempotent: restarts if stopped, no action needed if already running

**Workflow:**
```bash
# Republish the local management and workload folders after making changes
mise -E local-host run oci-push

# Optional overrides
OCI_REPOSITORY=my-config OCI_TAG=v1 \
  mise -E local-host run oci-push

# FluxInstance pulls and reconciles the artifact's mgmt/local-host kustomization.
# bootstrap.sh configures kind's containerd to mirror localhost:5001 to the
# registry's in-cluster endpoint, knr-registry:5000.
```

The artifact contains only `mgmt/local-host/` and `workload/local-host/`,
preserving those directory paths when the artifact is pulled. Keeping the
source scope narrow also prevents local credentials and age private keys
elsewhere in the repository from being packaged.

The AWS profile adds the GitHub/SOPS secrets and configures the FluxInstance to sync `mgmt/aws/`.

Watch reconciliation:

```sh
flux get kustomizations --watch
```

For the local-host profile, export and verify the CAPD workload kubeconfig after
`docker-workload-cluster` reports Ready:

```sh
mise -E local-host run kubeconfigs
KUBECONFIG=local-workload.kubeconfig kubectl get nodes
```

The local workload Flux instance installs Podinfo from its OCI Helm chart. Open
it in a host browser by running the port-forward task in a separate terminal:

```sh
mise -E local-host run podinfo-port-forward
```

Then browse to <http://localhost:9898>. Press Ctrl-C to stop forwarding.

The workload uses Kubernetes v1.35.0. A CAPI ClusterResourceSet installs a
pinned Kindnet daemon as its CNI before the Flux addons are delivered.
The management cluster needs access to the container-engine socket, which
`bootstrap.sh` mounts automatically.

Local-host bootstrap first waits for the management `flux-apps` Kustomization
without printing transient `Unknown` status rows. After `flux-apps` becomes
Ready, it connects to `local-workload`, streams the workload Flux controller
error logs, and returns after the workload root Kustomization becomes Ready.
Filtering the workload stream to errors avoids showing normal startup retries
and advisory messages as apparent failures. Each readiness wait defaults to 15
minutes and can be changed with `LOCAL_RECONCILE_TIMEOUT`.

EKS clusters typically take 15–25 minutes to come up; node groups and the
downstream app chain follow a few minutes after.

### Verifying the full chain

For the local-host end-to-end chain:

```sh
mise -E local-host run bootstrap
mise -E local-host run kubeconfigs
KUBECONFIG=local-workload.kubeconfig flux get all --all-namespaces
mise -E local-host run podinfo-port-forward  # browse to http://localhost:9898
```

Bootstrap does not return until the management and workload root
Kustomizations are Ready. The final port-forward verifies that the workload
Flux instance successfully delivered the application.

For the AWS chain:

```sh
# Management cluster
kubectl get kustomizations -n flux-system            # all Ready
kubectl get clusters.cluster.x-k8s.io -A             # Provisioned
kubectl get roles.iam.services.k8s.aws -n ack-system
kubectl get podidentityassociations.eks.services.k8s.aws -n ack-system

# Workload clusters — export kubeconfigs first:
#   mise -E aws run kubeconfigs && export KUBECONFIG=~/.kube/knr-ops-workloads.yaml
#   kubectl config use-context eu-north-1-workload   (or eu-west-1-workload)
kubectl get kustomizations -n flux-system            # aws-operators, s3-buckets, rds-instances, iam-roles

# AWS
aws s3api get-bucket-encryption    --bucket knr-ops-<account>-eu-north-1-workload-data
aws s3api get-public-access-block  --bucket knr-ops-<account>-eu-north-1-workload-data
```

## Teardown

```sh
mise run teardown    # or: ./teardown.sh
```

Tears down in reverse order: suspends Flux, deletes CAPI workload clusters (so
CAPA or CAPD deprovisions their infrastructure), removes providers, uninstalls
Flux, and deletes the kind cluster. The local-host profile waits for CAPD to
remove the workload containers before deleting `mgmt`. The `clusterawsadm` IAM
stack is intentionally left in place.

> Note: S3 buckets, RDS instances, and IAM reader roles created by ACK on the
> workload clusters are deleted when their `Bucket`/`DBInstance`/`Role` CRs
> are pruned — but if the workload clusters are destroyed before the CRs are
> removed, they survive as orphans. The teardown script's AWS cleanup step
> runs in **both regions** (`eu-north-1`, `eu-west-1`) and deletes the
> orphaned RDS instances (`knr-ops-*-workload-db`, skipping the final
> snapshot), the orphaned S3 data buckets
> (`knr-ops-<account>-*-workload-data`, purging all object versions), the
> orphaned `knr-ops-*-workload-reader` roles, the CAPA-created per-cluster
> IAM roles (`*-workload-*` prefix sweep), the `knr-ops-ack-s3-controller` /
> `knr-ops-ack-rds-controller` / `knr-ops-ack-iam-controller` IAM roles, and
> the `knr-ops-reader` IAM user (including its login profile and inline
> policy). Slow deletions (nodegroups, EKS control planes) are awaited so
> VPC cleanup succeeds within the same run.

## Validation

Build every kustomize overlay locally before pushing (mirrors CI). This covers
both `mgmt/aws/` and `workload/`:

```sh
mise run validate
```

CI runs the same kustomize build plus yamllint on every push and PR
(`.github/workflows/validate.yml`).
