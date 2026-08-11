# knr-ops

A GitOps pattern for managing cloud infrastructure through the Kubernetes API —
no Terraform, no state files, no second toolchain. This repository is a working
reference implementation of that pattern on AWS. **It is not a product**: fork
it, strip it down, and adapt the layout to your own cloud and clusters.

A local [kind](https://kind.sigs.k8s.io/) cluster bootstraps
[Flux](https://fluxcd.io/); from then on, **everything is declared in Git** and
reconciled continuously — EKS workload clusters via
[CAPA](https://cluster-api-aws.sigs.k8s.io/), per-cluster Flux instances as
[Cluster API](https://cluster-api.sigs.k8s.io/) addons, and application
workloads (the [ACK](https://aws-controllers-k8s.github.io/docs/) S3, RDS, and
IAM operators) running on each workload cluster.

## Who this is for

Platform engineers who already run Kubernetes and want to manage their own
cloud infrastructure with the same API, RBAC, audit trail, and GitOps workflow
they use for workloads. If you're reaching for Terraform/OpenTofu, Pulumi, or
Crossplane to stand up cloud resources for Kubernetes, this pattern is the
alternative: the cluster you already operate becomes the control plane. It is
not a developer self-service portal — you are the consumer.

## Problems the pattern solves

- **State files** — drift, locking, corruption. Controllers reconcile actual
  state continuously instead of diffing a snapshot.
- **The plan/apply gap** — you review code but apply output. Here the reviewed
  manifests are what reconciles; CI builds every kustomize overlay on each PR.
- **Two toolchains** — HCL for infra, YAML for workloads. One control plane
  means RBAC, policy, and audit cover both.
- **Lifecycle split** — Terraform builds the cluster but can't manage what's
  in it. CAPI + Flux is one dependency graph from cluster to workload.

## What the reference implementation deploys

From one management cluster: 2 EKS clusters (eu-north-1, eu-west-1) with ARM
and GPU node pools, per-cluster Flux delivered via HelmChartProxy +
ClusterResourceSets, secure S3 buckets, RDS PostgreSQL instances, and a
read-only IAM console user spanning it all. 0 HCL.

## Quickstart

```sh
mise install                # tools pinned in mise.toml (kubectl, kind, flux, ...)
cp .env.example .env        # fill in GitHub App + AWS settings; gitignored
mise run sops-keygen        # first time only — age key for SOPS
mise run bootstrap          # kind cluster + Flux; everything else is GitOps
flux get kustomizations --watch
mise run validate           # build every kustomize overlay (mirrors CI)
mise run teardown           # full teardown (EKS, AWS resources, kind)
```

Prerequisites (Docker, a GitHub App, AWS credentials and quotas, the
`clusterawsadm` CloudFormation stack) and the full bootstrap/verify/teardown
walkthrough are in [docs/operations.md](docs/operations.md).

## Documentation

| Page | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Architecture diagram, reconciliation order, how workload apps are delivered |
| [docs/aws-iam.md](docs/aws-iam.md) | EKS Pod Identity, ACK controller IAM roles, per-cluster reader roles, the `knr-ops-reader` console user |
| [docs/workload-resources.md](docs/workload-resources.md) | S3 bucket security posture, RDS instances, known limitations |
| [docs/secrets.md](docs/secrets.md) | SOPS + age secret management, key setup, credential rotation |
| [docs/operations.md](docs/operations.md) | Prerequisites, AWS service quotas, configuration, bootstrap, verification, teardown, validation |
| [docs/extending.md](docs/extending.md) | Adding a workload cluster, adding apps to the workload clusters |

## Repository layout

```
├── bootstrap.sh / teardown.sh     One-time imperative bootstrap / full teardown
├── docs/                          Detailed documentation (see table above)
├── capi-mgmt/                     Synced by the MANAGEMENT cluster's Flux
│   ├── infrastructure/            cert-manager, CAPI operator, CAPA identity,
│   │                              ACK controllers, pod-identity roles,
│   │                              account-global IAM (reader console user)
│   ├── capi-providers/            capi-system, capa-system (SOPS creds),
│   │                              caaph-system
│   ├── addons/flux-apps/          Installs Flux on each workload cluster
│   │                              (HelmChartProxy + ClusterResourceSets)
│   └── clusters/                  EKS cluster defs (eu-north-1, eu-west-1;
│                                  ARM + GPU MachinePools)
└── apps/                          Synced by each WORKLOAD cluster's Flux
    ├── base/                      ACK S3/RDS/IAM controllers, Bucket CRs,
    │                              DBInstance CRs, reader Role CRs
    ├── eu-north-01/               Per-cluster overlay (sync target)
    └── eu-west-01/                Per-cluster overlay (sync target)
```
