# Operations

## Prerequisites

Tool versions are pinned in `mise.toml`. With [mise](https://mise.jdx.dev/)
installed:

```sh
mise install
```

This provides `kubectl`, `kind`, `helm`, `flux`, `clusterctl`, `clusterawsadm`,
`aws-cli`, `go`, `sops`, and `age`.

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
mise run bootstrap   # or: ./bootstrap.sh
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

The local-host profile performs the cluster, Flux Operator, and FluxInstance steps in
the `mgmt` management cluster, but does not create GitHub or SOPS secrets,
configure Git sync, or start GitOps reconciliation. Instead, it bootstraps a
local Docker Registry container (`registry:2`) running on the host machine
(accessible at `localhost:5001` by default) for managing OCI artifacts.

**OCI Registry (local-host profile only):**
- Provides a local container registry for development workflows
- Enables developers to build and push OCI artifacts from git checkouts
- Flux can sync and deploy OCI artifacts from the registry without external dependencies
- Configurable via `REGISTRY_PORT` env var (defaults to 5001)
- Idempotent: restarts if stopped, no action needed if already running

**Workflow:**
```bash
# 1. Build OCI artifact from local checkout
docker build -t localhost:5001/myapp:v1.0 .

# 2. Push to local registry
docker push localhost:5001/myapp:v1.0

# 3. Configure Flux to pull from registry via mgmt/local-host kustomization
# bootstrap.sh configures kind's containerd to mirror localhost:5001 to the
# registry's in-cluster endpoint, knr-registry:5000.
# Flux syncs and deploys from the local registry into the cluster
```

The AWS profile adds the GitHub/SOPS secrets and configures the FluxInstance to sync `mgmt/aws/`.

Watch reconciliation:

```sh
flux get kustomizations --watch
```

EKS clusters typically take 15–25 minutes to come up; node groups and the
downstream app chain follow a few minutes after.

### Verifying the full chain

```sh
# Management cluster
kubectl get kustomizations -n flux-system            # all Ready
kubectl get clusters.cluster.x-k8s.io -A             # Provisioned
kubectl get roles.iam.services.k8s.aws -n ack-system
kubectl get podidentityassociations.eks.services.k8s.aws -n ack-system

# Workload clusters — export kubeconfigs first:
#   mise run kubeconfigs && export KUBECONFIG=~/.kube/knr-ops-workloads.yaml
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
CAPA deprovisions all AWS resources), removes providers, uninstalls Flux, and
deletes the kind cluster. The `clusterawsadm` IAM stack is intentionally left
in place.

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
