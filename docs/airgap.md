# Air-gapped knr-ops with Zarf (local-host / CAPD profile)

This document describes how knr-ops is packaged with [Zarf](https://zarf.dev)
on a connected machine and deployed end-to-end with **no internet access**:
the management cluster, Flux, CAPI, and a CAPD workload cluster, all from one
package plus a small set of image archives.

Status: **validated with the radio off** (2026-08-18). Rehearsed connected on
an isolated `airgap-mgmt` cluster + a renamed `airgap-wl` workload cluster
(coexisting with the live baseline), then deployed and verified end-to-end by
the autonomous script `scripts/offline-run.sh` with Wi-Fi disabled for the
full deploy + reconcile window. Re-run that script the same way to
re-verify.

## Prerequisites

The kit is single-architecture (arm64), including the pinned Zarf CLI. The
mise pin in `mise.toml` selects the matching Linux or macOS arm64 release
asset. Docker and kind are also required on the deploy host (the prototype
keeps kind as the management-cluster substrate; see Known limitations).

## Architecture

Two registries, two image layers, one package.

```
connected side (build)                        gap (deploy)
----------------------                        --------------
airgap/scripts/build-package.sh               airgap/scripts/stage-and-create-cluster.sh
  validate + render                            1. docker load archives/*.tar  (node + workload images)
  build-config-artifact.sh -> OCI artifact     2. kind create cluster (mgmt)
  zarf package create                          3. recreate + seed knr-registry (config + charts)
        |                                      zarf init --registry-mode=nodeport
        v                                      zarf package deploy
zarf-package-knr-ops-airgap-*.tar.zst               |
archives/ (node images, workload images,           v
  charts, zarf-init tarball)                 Zarf internal registry (127.0.0.1:31999)
                                                    + agent (mutating webhook)
                                             substrate: cert-manager, flux-operator,
                                               CAPI core+providers, CAPD, CAAPH
                                             FluxInstance -> sync from Zarf registry
                                             Flux -> clusters/docker (CAPD) -> workload
                                             workload Flux <- knr-registry (config+charts)
```

**Ownership split.** Zarf owns the *substrate* (internal registry, agent,
cert-manager, the flux-operator chart, CAPI core + kubeadm bootstrap /
control-plane + CAPD + CAAPH component manifests, and the knr-ops config
artifact). Flux owns the *workload definitions* (the CAPD cluster, the kindnet
CNI addon, the per-cluster Flux addon), reconciled from the config artifact.
The `mgmt/` and `workload/` trees in git are **not** modified; the airgap
variant is generated at build time by `build-config-artifact.sh`.

**Why OCI, not Gitea.** The local-host profile moved from a GitHub
`GitRepository` to an OCI-artifact sync (`oci://knr-registry:5000/knr-ops`)
in PRs #30/#31/#33. There is no `GitRepository` left to rewrite, so the Zarf
git-server is unused; the config crosses the gap as an OCI artifact inside the
Zarf package and is published into Zarf's internal registry at deploy time.
The verification linchpin is the agent's **image rewrite** plus a Ready
`OCIRepository` pointing at the internal registry, with the radio off.

## What crosses the gap (the kit)

| Item | Purpose |
|---|---|
| `zarf` CLI binary | runs the deploy |
| `archives/zarf-init-arm64-v0.83.0.tar.zst` | `zarf init` (registry + agent) |
| `archives/zarf-package-knr-ops-airgap-arm64-0.1.0.tar.zst` | the package |
| `archives/kindest_node_v1.36.1_mgmt.tar` | mgmt kind node (host daemon) |
| `archives/kindest_node_v1.35.0.tar` | CAPD workload nodes (host daemon) |
| `archives/kindest_haproxy_*.tar` | CAPD load balancer |
| `archives/docker.io_library_registry_2.tar` | knr-registry container |
| `archives/workload-pod-images.tar` | flux controllers + podinfo for `preLoadImages` |
| `archives/charts/{flux-operator,podinfo}-*.tgz` | OCI charts seeded into knr-registry |
| `config-artifact/` | trimmed GitOps tree, re-pushed as `knr-ops:latest` |

## Sequence

Connected (build):

```sh
airgap/scripts/build-package.sh   # validate, artifact, images, charts, zarf package create
```

Gap (deploy) — from `airgap/`:

```sh
scripts/stage-and-create-cluster.sh                       # docker load, kind create, seed knr-registry
zarf init archives/zarf-init-arm64-v0.83.0.tar.zst \
  --registry-mode=nodeport --components="" --confirm
zarf package deploy archives/zarf-package-knr-ops-airgap-arm64-0.1.0.tar.zst --confirm
```

Rehearsal isolation knobs (never touch a live baseline on the same Docker
daemon): `CLUSTER_NAME`, `AIRGAP_CLUSTER_NAME`, `WORKLOAD_REGISTRY_HOST`,
`REGISTRY_NAME`, `REGISTRY_PORT`.

## Verification checklist

- `kubectl get pods -A -o jsonpath=...`: every non-kind-baked image is
  prefixed `127.0.0.1:31999/` (the Zarf internal registry).
- `kubectl -n flux-system get ocirepository`: `url` is
  `oci://zarf-docker-registry.zarf.svc.cluster.local:5000/knr-ops-airgap`,
  Ready with a stored digest equal to the connected-side push.
- `flux get kustomizations`: all Ready, from the artifact.
- `kubectl get clusters.cluster.x-k8s.io -A`: workload cluster `Provisioned` /
  `Available=True`; `clusterctl describe cluster` machines Running.
- Workload cluster: `kubectl get nodes` Ready; flux + podinfo pods Running.

## Empirical findings (why the package looks the way it does)

1. **Captured CAPI provider components are clusterctl templates.** The
   capi-operator substitutes `${VAR:=default}` placeholders and applies the
   provider-spec `--feature-gates=ClusterTopology=true` arg override at
   install. In the gap we are the operator, so
   `scripts/substitute-components.sh` performs both steps up front.
2. **`spec.distribution.artifact` must be omitted** from the FluxInstance.
   The operator fetches it at every reconcile and its fetcher has no
   insecure-registry option (verified: "http: server gave HTTP response to
   HTTPS client" against the plain-HTTP internal registry). Omitting it makes
   the operator use its embedded distribution manifests, the documented
   airgap default. The `flux-instance` Helm chart is unusable offline because
   it renders `artifact` unconditionally.
3. **The embedded distribution digest-pins controller images to multi-arch
   manifest-list digests** that Zarf's single-arch image pipeline cannot
   resolve. The FluxInstance kustomize patches pin the four controllers back
   to tags; the agent rewrites tags to the `<tag>-zarf-<hash>` tags that do
   exist in the registry.
4. **Zarf v0.83 wraps `manifests:` in a generated Helm chart that fails to
   adopt CRs** ("exists and cannot be imported into the current release").
   The FluxInstance is deployed via `files:` + a `kubectl apply` action.
5. **In-cluster fetchers cannot use the nodeport address.** `127.0.0.1:31999`
   resolves only from a node's loopback. The FluxInstance `sync.url` therefore
   uses the internal service DNS name (`###ZARF_CONST_REGISTRY_INTERNAL###` =
   `zarf-docker-registry.zarf.svc.cluster.local:5000`), which the Zarf
   `private-registry` pull secret already covers. Tree-defined OCIRepositories
   additionally need `spec.insecure: true`.
6. **Workload-node k8s images are pre-baked** into `kindest/node` (verified:
   136 content blobs), so CAPD nodes come up offline with no pulls. Only the
   workload Flux controllers and podinfo need `preLoadImages`.

## Known limitations / follow-ups

- **capi-operator is omitted** in the gap. Provider upgrades ride package
  rebuilds. Acceptable for the prototype.
- **kind stays** (macOS host). On Linux targets `zarf init --components=k3s`
  replaces kind; not prototyped here.
- **Single architecture** (arm64). Multi-arch is a `--architecture` follow-up.
- The **flux-operator chart for the HelmChartProxy** and the podinfo chart are
  seeded into knr-registry as OCI charts; CAAPH fetches them over plain HTTP
  (verified). The workload-cluster FluxInstance omits `distribution.artifact`
  the same way as the mgmt one.
- **AWS flavor is out of scope** here but shapes the design: in a disconnected
  AWS region the same package pattern covers CAPA/ACK/EKS via in-region
  endpoints; on-prem it maps to the provider-swap path in `docs/extending.md`.

## Update drill

A config-only change (edit the tree, re-run `build-config-artifact.sh`,
re-push `knr-ops:latest` to knr-registry) moves the workload Flux to a new
digest without rebuilding the package. A substrate change (images/components)
requires `build-package.sh` and a fresh `zarf package deploy`.
