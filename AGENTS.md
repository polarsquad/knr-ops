# AGENTS.md: knr-ops

Guidance for AI coding agents working in this repository.

## What this repo is

A working reference implementation of a GitOps pattern for managing AWS
infrastructure through the Kubernetes API: no Terraform, no state files, no
second toolchain. A local kind cluster bootstraps Flux, which reconciles
everything else: CAPA-managed EKS workload clusters, per-cluster Flux
instances (CAPI addons), and ACK operators (S3, RDS, IAM) managing cloud
resources. There is no app source code here, only declarative infrastructure.

- `mgmt/`: synced by the MANAGEMENT cluster's Flux.
  - `infrastructure/`: cert-manager, CAPI operator, CAPA identity, ACK
    controllers, pod-identity roles, account-global IAM, konflate.
  - `capi-providers/`: capi-system, capa-system, caaph-system.
  - `addons/flux-apps/`: installs Flux on each workload cluster
    (HelmChartProxy + ClusterResourceSets).
  - `clusters/`: EKS cluster definitions per region (`eu-north-1`,
    `eu-west-1`).
- `workload/`: synced by each WORKLOAD cluster's Flux.
  - `base/`: ACK controllers and S3/RDS/IAM custom resources.
  - `<region>-01/`: per-cluster overlays pointing at `../base`.
- `bootstrap.sh` / `teardown.sh`: the only imperative steps (one-time
  kind + Flux bootstrap, full teardown).
- `docs/`: detailed documentation (see the table in README.md).
- `mise.toml`: pinned tool versions and all task entrypoints.

## The golden rules (read before changing anything)

1. Edit YAML in Git; never mutate the clusters. Use kubectl to inspect live
   state, but make every persistent change here and let Flux converge.
2. Flux tracks `main`. Nothing reconciles until merged to `main`. Do not
   promise a fix is "live" until then.
3. Secrets via SOPS + age. Encrypted manifests are named `*.sops.yaml` and
   only `data`/`stringData` fields are encrypted (per `.sops.yaml`). Never
   commit plaintext secrets; `age.agekey` and `.env` are gitignored and must
   stay that way. Encrypt with `mise run sops-encrypt <file>`.
4. Run `mise run validate` before pushing. PRs are reviewed as rendered Flux
   diffs by the in-cluster konflate instance, so what you push is what gets
   reviewed.

## App layout convention

Each component pairs a plain kustomize root with a Flux `Kustomization`:

```
<scope>/<component>/
  kustomization.yaml   # kustomize.config.k8s.io: lists the manifests (+ flux-ks.yaml)
  flux-ks.yaml         # Flux Kustomization(s): path, dependsOn, wait
  ...                  # raw manifests (HelmRelease, CRs, ...)
```

- Register new components in the parent `kustomization.yaml` (the
  `flux-ks.yaml` entry) and use `dependsOn` / `wait: true` for ordering.
- Per-cluster values come from `postBuild.substituteFrom: cluster-vars`
  (`${AWS_REGION}`, `${CLUSTER_NAME}`), not from hardcoding.
- Adding a workload cluster or app is a documented multi-step procedure:
  follow `docs/extending.md` exactly rather than improvising.

## Common tasks (mise)

```sh
mise install            # install pinned tools (kubectl, kind, flux, sops, age, ...)
mise run validate       # build every kustomize overlay; mirrors CI
mise run bootstrap      # one-time kind cluster + Flux handoff
mise run kubeconfigs    # export workload-cluster kubeconfigs
mise run teardown       # full teardown (EKS, AWS resources, kind)
```

## Where to look next

Load these only when the task touches their domain:

- `docs/architecture.md`: reconciliation order, how workload apps are delivered.
- `docs/extending.md`: adding a workload cluster, adding apps, adding other providers (Azure, Talos, k0smotron).
- `docs/secrets.md`: SOPS + age setup, credential rotation.
- `docs/konflate.md`: rendered PR review, tokens, write-back.
- `docs/aws-iam.md`: EKS Pod Identity, ACK controller roles, reader user.
- `docs/operations.md`: quotas, configuration, bootstrap, verification.
- `docs/workload-resources.md`: S3/RDS posture, known limitations.
