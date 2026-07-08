# knr-ops
## kubernetes-native resource operations

This repository is an example of a GitOps-driven [Cluster API](https://cluster-api.sigs.k8s.io/) (CAPI) management
platform. 

After a one-time bootstrap, everything is declared in Git as yaml — no scripts, no terraform and no imperative AWS setup.

1 CAPI Cluster creates: 4 Clusters, 4 Node Pools, 2 Regions, 2 S3 buckets, 2 RDS instances, 1 User, 1 Role

Starts with a local [kind](https://kind.sigs.k8s.io/) cluster bootstraps
[Flux](https://fluxcd.io/), which then reconciles everything else from this
repository — AWS EKS workload clusters provisioned via
[CAPA](https://cluster-api-aws.sigs.k8s.io/), per-cluster Flux instances
delivered through CAPI addons, and application workloads (the
[ACK](https://aws-controllers-k8s.github.io/docs/) S3, RDS, and IAM operators
managing secure S3 buckets, PostgreSQL instances, and read-only IAM roles)
running on each workload cluster.

## Prerequisites

- Docker
- GitHub App
- AWS credentials and quotas established
- Mise

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
