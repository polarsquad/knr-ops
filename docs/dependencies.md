# Dependencies

Dependency versions live in the native files that consume them: mise configs,
Kubernetes/Flux manifests, HelmRelease charts, GitHub Actions workflows, the
airgap image inventory, and zarf.yaml. There is no central catalog. Renovate
discovers every pinned version in those files and opens update PRs, configured
in [`renovate.json5`](../renovate.json5) and running weekly via the
`renovate` GitHub Actions workflow. Pending and proposed updates are tracked
in the Renovate dependency dashboard issue.

## Managed surfaces

Renovate discovers and updates versions in:

- `mise.toml`, `mise.aws.toml`, `mise.local-host.toml`: tool pins and the
  zarf CLI pin.
- `mgmt/**` and `workload/**` YAML: Flux (HelmRelease/HelmRepository),
  Kubernetes manifests, Helm values, and clusterctl provider manifests
  under `capi-providers/`.
- `kindest/node` image tags wherever referenced (mgmt, workload, airgap).
- `airgap/images.txt` and `airgap/zarf.yaml`: container image refs.
- `.github/workflows/`: GitHub Actions versions.

Grouping rules (flux controllers together, ACK controllers together, node
versions kept separate) and pinning behavior are defined in
[`renovate.json5`](../renovate.json5).

## Update procedure

1. Wait for a Renovate PR, or trigger the `renovate` workflow manually with
   `workflow_dispatch` (dry-run by default).
2. Review the rendered diff; CI (`validate` workflow) builds every kustomize
   overlay and checks the airgap image inventory on each update PR.
3. Merge manually; nothing automerges.

If an image appears in both a manifest and `airgap/images.txt`, bump them in
the same PR: the airgap inventory check fails CI if the manifest references
an image missing from the inventory.

## Intentional differences

- The kind management node image, CAPD workload node images, and EKS cluster
  versions are separate pins on purpose and upgrade independently.
- `flux2`, `sops`, `age`, and the AWS CLI are floating `latest` pins; Renovate
  pins their digests so rebuilds still raise PRs.
- `*.sops.yaml` `version:` fields, `apiVersion` strings, chart
  `appVersion` values, and the Zarf package `metadata.version` are not
  dependencies and are not managed.
