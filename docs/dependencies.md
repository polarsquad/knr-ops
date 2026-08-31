# Dependencies

Dependency versions live in the native files that consume them: mise configs,
Kubernetes/Flux manifests, HelmRelease charts, GitHub Actions workflows, the
airgap image inventory, zarf.yaml, and annotated version constants in
bootstrap-rs sources. There is no central catalog. Renovate discovers every
pinned version in those files and opens update PRs, configured in
[`renovate.json5`](../renovate.json5) and running weekly via the hosted
Renovate GitHub App (issue #90). Pending and proposed updates are tracked in
the Renovate dependency dashboard issue.

## Managed surfaces

Renovate discovers and updates versions in:

- `mise.toml`, `mise.aws.toml`, `mise.local-host.toml`: tool pins and the
  zarf CLI pin (explicit per-tool custom managers; the native mise manager
  is disabled so resolution is deterministic).
- `mgmt/**` and `workload/**` YAML: Flux (HelmRelease/HelmRepository),
  Kubernetes manifests, Helm values, and clusterctl provider manifests
  under `capi-providers/`.
- `kindest/node` image tags wherever referenced (mgmt, airgap scripts).
- `airgap/images.txt` and `airgap/zarf.yaml`: container image refs, pinned
  by digest.
- `.github/workflows/`: GitHub Actions versions, including the Renovate CLI
  pin used by the CI detection tests.
- `pivot.sh`: imperative Helm chart pins (cert-manager,
  cluster-api-operator), grouped with their GitOps HelmRelease counterparts.
- `bootstrap-rs/src/`: version constants carrying a
  `// renovate: datasource=... depName=...` annotation.

Grouping rules (flux family together, CAPI family together, imperative chart
pins with their manifest counterparts, node versions kept separate) and
pinning behavior are defined in [`renovate.json5`](../renovate.json5).

## Update procedure

1. Wait for a Renovate PR. For troubleshooting, a local dry-run command is
   documented in [AGENTS.md](../AGENTS.md) ("Editing renovate.json5").
2. Review the rendered diff; CI (`validate` workflow) builds every kustomize
   overlay on each update PR.
3. Merge manually; nothing automerges.

If an image appears in both a manifest and the airgap inventory
(`airgap/images.txt` or `zarf.yaml`), bump them in the same PR. There is no
automated completeness check between manifests and the inventory, so verify
the pairing during review.

## Intentional differences

- The kind management node image, CAPD workload node images, and EKS cluster
  versions are separate pins on purpose and upgrade independently.
- EKS addon versions (`*-eksbuild.*`) have no public registry datasource and
  are updated manually.
- Unversioned tags (e.g. the locally built `localhost:5001/knr-ops-airgap`
  registry image) have no comparable version and are untracked.
- `*.sops.yaml` `version:` fields, `apiVersion` strings, chart
  `appVersion` values, and the Zarf package `metadata.version` are not
  dependencies and are not managed.
