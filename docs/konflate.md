# PR review: konflate

[Konflate](https://github.com/home-operations/konflate) reviews this repo's
open PRs as **rendered** Flux diffs instead of raw file diffs. For each PR it
renders the full Flux output at the merge-base and at the head, then diffs the
two, so a review shows:

- **Blast radius** — which clusters/Kustomizations a change actually touches
  (a one-line kustomize edit can fan out to many rendered resources).
- **Image changes** — container image bumps extracted from the rendered
  output.
- **Render failures** — a PR that breaks the Flux render is caught before
  merge, not at reconcile time.
- **Danger lint** — cautions on risky changes.

Reporting uses konflate's **write-back** mode: konflate itself posts the
results to GitHub from inside the cluster. Write-back is outbound-only — the
local kind management cluster needs no inbound reachability from GitHub, so
there is no CI job and nothing to expose publicly.

## Deployment

A single instance runs on the **management cluster**, deployed from
`capi-mgmt/infrastructure/konflate/` by the `konflate` Flux Kustomization
(`capi-mgmt/infrastructure/flux-ks.yaml` — SOPS decryption enabled, no
`dependsOn`, so it comes up independently of the CAPI/ACK chains).

| Piece | Detail |
|---|---|
| Chart | OCI artifact `oci://ghcr.io/home-operations/charts/konflate`, pinned tag (see `helm.yaml`) |
| Namespace | `konflate` |
| `config.repo` | `github://polarsquad/knr-ops` |
| `config.clusterPath` | `""` — render from the repo root, matching this repo's root-relative Flux Kustomization paths (`./capi-mgmt/...`, `./apps/...`) |
| `config.prComments` | `true` — post the rendered summary as a PR comment |
| `config.statusChecks` | `true` — post the `Konflate` commit status with the render verdict |
| Secret | `konflate-token` (SOPS-encrypted, `konflate-token.sops.yaml`) |
| Persistence | Enabled (kind's default local-path StorageClass) so source caches and rendered diffs survive pod restarts |

## Authentication

The `konflate-token` secret carries two values (rotation:
[Secret management](./secrets.md#setting--rotating-the-konflate-tokens)):

- **`KONFLATE_TOKEN`** — a read-only GitHub PAT. The repo is private, so
  konflate needs it to list PRs and clone.
- **`KONFLATE_WRITE_TOKEN`** — the write-back credential, kept separate from
  the read token so that one carries no write scope. A fine-grained PAT with
  **Pull requests** and **Commit statuses** (R/W) on this repo, or a classic
  PAT with `repo` scope.

## Write-back

On every render konflate:

1. **Posts / edits the PR comment** — the rendered summary (blast radius,
   image changes, cautions, render failures) as a single comment, found by a
   hidden marker and edited in place on each subsequent render — it never
   piles up duplicates.
2. **Posts the `Konflate` commit status** on the PR head — `success` when the
   diff rendered, `failure` when it didn't. To gate merges on the render, mark
   `Konflate` as a required status check in branch protection.

Notes:

- PRs re-render automatically on konflate's refresh interval (default 30m)
  and whenever it observes the head advance; there is no push/webhook trigger
  configured, so a fresh push can take up to one interval to be reviewed.
- The posted comment and status carry no "view review" link because
  `KONFLATE_PUBLIC_URL` is unset (the UI isn't reachable from outside).
- Fork PRs are never rendered (`KONFLATE_RENDER_FORK_PRS` is off by default).

## UI

The UI is not exposed outside the cluster:

```sh
kubectl port-forward -n konflate svc/konflate 8080:8080
# then open http://localhost:8080
```
