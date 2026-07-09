# knr-ops
## kubernetes-native resource operations

This is a method of using Kubernetes-native resources to manage cloud-infrastucture and workloads all from a monorepo using Flux CD for GitOps. The idea here is that IaC doesn't have to be complicated, use DSL, or require expensive tools.

After a one-time bootstrap, everything is declared in Git as yaml.

1 CAPI Cluster creates: 2 Clusters, 4 Node Pools, 2 Regions, 2 S3 buckets, 2 RDS instances, 1 User, 1 Role

0 HCL, 0 statefiles, just pure yaml and GitOps.

Starts with a local [kind](https://kind.sigs.k8s.io/) cluster that bootstraps
[Flux](https://fluxcd.io/), which then reconciles everything else from this
repository — AWS EKS workload clusters provisioned via
[CAPA](https://cluster-api-aws.sigs.k8s.io/), per-cluster Flux instances
delivered through CAPI addons, and application workloads (the
[ACK](https://aws-controllers-k8s.github.io/docs/) S3, RDS, and IAM operators
managing secure S3 buckets, PostgreSQL instances, and read-only IAM roles)
running on each workload cluster.

PRs are reviewed as **rendered** Flux diffs (blast radius, image changes,
render failures) by an in-cluster
[konflate](https://github.com/home-operations/konflate) instance — see
[docs/konflate.md](docs/konflate.md).

## Prerequisites

- Mise
- GitHub personal access token (PAT) with read access to this repo
- AWS credentials and quotas established

## Quickstart

```sh
mise trust                  # to enable mise in this repository
mise install                # installs tools pinned in mise.toml (kubectl, kind, flux, ...)
cp .env.example .env        # fill in GitHub PAT + AWS settings; gitignored
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
| [docs/konflate.md](docs/konflate.md) | Rendered Flux PR review: in-cluster konflate instance, CI workflow, tokens |
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
│   │                              account-global IAM (reader console user),
│   │                              konflate (rendered Flux PR review)
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
