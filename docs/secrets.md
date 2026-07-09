# Secret management

In-cluster secrets are managed with [SOPS](https://github.com/getsops/sops) +
[age](https://github.com/FiloSottile/age), so encrypted manifests can live
safely in Git and Flux decrypts them at reconcile time.

- **`.sops.yaml`** declares the age *public* key (safe to commit) and a rule
  that encrypts only `data`/`stringData` fields of any `*.sops.yaml` file under
  `capi-mgmt/`.
- The age *private* key lives in `age.agekey` (gitignored). `bootstrap.sh`
  loads it into the cluster as the `sops-age` secret in `flux-system`.

SOPS-encrypted secrets in this repo (each referenced by a Flux `Kustomization`
with `spec.decryption.provider: sops`):

| File | Consumed by | Purpose |
|---|---|---|
| `capi-mgmt/capi-providers/capa-system/aws-credentials.sops.yaml` | `capa-system` | CAPA controller AWS credentials |
| `capi-mgmt/infrastructure/ack-controllers/aws-credentials.sops.yaml` | `ack-controllers` | ACK IAM/EKS controller AWS credentials (shared-credentials-file format) |
| `capi-mgmt/addons/flux-apps/flux-pull-secret.sops.yaml` | `flux-apps` | GitHub PAT pull secret (basic auth), delivered to each workload cluster via ClusterResourceSet so its Flux can clone this (private) repo |

## First-time setup

```sh
mise run sops-keygen        # creates ./age.agekey and prints the public key
```

Put the printed public key into the `age:` field of `.sops.yaml`, then
re-encrypt existing secrets so they target your key:

```sh
mise run sops-updatekeys
```

## Setting / rotating AWS credentials

```sh
# CAPA — generate the base64 profile (requires AWS creds in your shell env):
clusterawsadm bootstrap credentials encode-as-profile
# Put the value into stringData.AWS_B64ENCODED_CREDENTIALS, then encrypt:
$EDITOR capi-mgmt/capi-providers/capa-system/aws-credentials.sops.yaml
mise run sops-encrypt capi-mgmt/capi-providers/capa-system/aws-credentials.sops.yaml

# ACK — standard AWS shared-credentials-file format under stringData.credentials:
$EDITOR capi-mgmt/infrastructure/ack-controllers/aws-credentials.sops.yaml
mise run sops-encrypt capi-mgmt/infrastructure/ack-controllers/aws-credentials.sops.yaml
```

View a decrypted secret without changing it:

```sh
mise run sops-decrypt <file>.sops.yaml
```

## Setting / rotating the GitHub PAT

The management cluster's own `flux-github-pat` secret is created imperatively
by `bootstrap.sh` (from `GITHUB_TOKEN` in `.env`) and is **not** in Git — Flux
needs it to clone the repo before it could ever decrypt anything (a
chicken-and-egg constraint). The workload clusters' copy *is* in Git
(`flux-pull-secret.sops.yaml`) because the management cluster's Flux decrypts
it before shipping it out via ClusterResourceSet.

To set or rotate the PAT in the workload clusters' pull secret:

```sh
# Decrypt in place, put the PAT into the nested stringData.password field,
# then re-encrypt:
mise x -- sops --decrypt --in-place --input-type yaml --output-type yaml \
  capi-mgmt/addons/flux-apps/flux-pull-secret.sops.yaml
$EDITOR capi-mgmt/addons/flux-apps/flux-pull-secret.sops.yaml
mise run sops-encrypt capi-mgmt/addons/flux-apps/flux-pull-secret.sops.yaml
```

Remember to also update `GITHUB_TOKEN` in `.env` so the next bootstrap uses
the new token.
