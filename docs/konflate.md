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

Konflate is **read-only toward GitHub**: it never writes to the forge. The CI
workflow (below) pulls the rendered summary from konflate's API and posts the
PR comment itself.

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
| Secret | `konflate-token` (SOPS-encrypted, `konflate-token.sops.yaml`) |
| Persistence | Enabled (kind's default local-path StorageClass) so source caches and rendered diffs survive pod restarts |

## Authentication

The `konflate-token` secret carries two values (rotation:
[Secret management](./secrets.md#setting--rotating-the-konflate-tokens)):

- **`KONFLATE_TOKEN`** — a read-only GitHub PAT. The repo is private, so
  konflate needs it to list PRs and clone.
- **`KONFLATE_PUSH_TOKEN`** — any random string. Gates
  `POST /api/prs/{n}/refresh`, which lets CI trigger an immediate re-render
  instead of waiting for konflate's periodic refresh. Mirror the same value
  as the `KONFLATE_PUSH_TOKEN` GitHub Actions repo secret.

## CI workflow

`.github/workflows/konflate.yml` runs on every PR:

1. **Trigger a re-render** — `POST /api/prs/{n}/refresh` with the push token
   (skipped without the token; konflate then picks the push up on its own
   refresh interval).
2. **Fetch the summary** — `GET /api/prs/{n}/summary` (markdown). The
   endpoint answers `503` + `Retry-After` while the render is in flight, so
   the request retries until it's done. The render verdict rides in the
   `X-Konflate-Render-Status` response header.
3. **Comment and gate** — posts the summary as a single PR comment (edited
   in place on every push) and fails the job when the render failed, so a PR
   that breaks the Flux render can't merge unnoticed.

Fork PRs are skipped: they get no secrets and a read-only `GITHUB_TOKEN`, and
konflate doesn't render forks by default (`KONFLATE_RENDER_FORK_PRS`).

### GitHub-side configuration

Both are optional — when absent the workflow skips gracefully:

| Setting | Kind | Value |
|---|---|---|
| `KONFLATE_URL` | Actions **variable** | Externally reachable base URL of the konflate instance |
| `KONFLATE_PUSH_TOKEN` | Actions **secret** | Same value as `KONFLATE_PUSH_TOKEN` in `konflate-token.sops.yaml` |

## UI

The UI is not exposed outside the cluster:

```sh
kubectl port-forward -n konflate svc/konflate 8080:8080
# then open http://localhost:8080
```
