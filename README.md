# krm-ops

GitOps-driven [Cluster API](https://cluster-api.sigs.k8s.io/) (CAPI) management
platform. A local [kind](https://kind.sigs.k8s.io/) cluster bootstraps
[Flux](https://fluxcd.io/), which then reconciles everything else from this
repository — including AWS EKS workload clusters provisioned via the
[CAPA](https://cluster-api-aws.sigs.k8s.io/) (AWS) provider.

## Architecture

```
kind management cluster (capi-mgmt)
└── flux-system (Flux Operator + FluxInstance)
    ├── infrastructure   cert-manager ──▶ capi-operator
    ├── capi-providers   capi-system (core/kubeadm)
    │                    ├── capa-system  (AWS + EKS providers)
    │                    └── caaph-system (Helm addon provider)
    ├── addons           flux-apps (installs Flux on each workload cluster)
    └── clusters         eu-north-1/staging, eu-west-1/staging  (EKS)
```

Reconciliation order is enforced with Flux `dependsOn`:

```
cert-manager ▶ capi-operator ▶ capi-system ▶ capa-system ▶ clusters
                                          └▶ caaph-system ▶ flux-apps
```

## Prerequisites

Tool versions are pinned in `mise.toml`. With [mise](https://mise.jdx.dev/)
installed:

```sh
mise install
```

This provides `kubectl`, `kind`, `helm`, `flux`, `clusterctl`, `clusterawsadm`,
`aws-cli`, `go`, `sops`, and `age`.

You also need:

- A running Docker daemon (for kind).
- A GitHub App with read access to this repository (App ID, Installation ID,
  and a private key `.pem`).
- AWS credentials with permission to create EKS clusters, VPCs, and IAM roles.
- The `clusterawsadm` IAM CloudFormation stack provisioned once per account:

  ```sh
  clusterawsadm bootstrap iam create-cloudformation-stack --region eu-north-1
  ```

## Configuration

Copy the env template and fill it in. `mise` loads `.env` automatically and it
is gitignored:

```sh
cp .env.example .env
$EDITOR .env
```

## Bootstrap

```sh
mise run bootstrap   # or: ./bootstrap.sh
```

> Before the first bootstrap, generate an age key for SOPS (see
> [Secret management](#secret-management)): `mise run sops-keygen`.

This is the only imperative step. It:

1. Creates the `capi-mgmt` kind cluster.
2. Installs the Flux Operator (Helm).
3. Creates the `flux-github-app` secret (for Git access) and the `sops-age`
   secret (the age private key Flux uses to decrypt SOPS-encrypted secrets).
4. Installs a `FluxInstance` that syncs `capi-mgmt/` and hands off to GitOps.

The `aws-credentials` secret for CAPA is **not** created imperatively — it lives
SOPS-encrypted in Git and is decrypted in-cluster by Flux during reconciliation.

Watch reconciliation:

```sh
flux get kustomizations --watch
```

EKS clusters typically take 15–25 minutes to come up.

## Teardown

```sh
mise run teardown    # or: ./teardown.sh
```

Tears down in reverse order: suspends Flux, deletes CAPI workload clusters (so
CAPA deprovisions all AWS resources), removes providers, uninstalls Flux, and
deletes the kind cluster. The `clusterawsadm` IAM stack is intentionally left in
place.

## Validation

Build every kustomize overlay locally before pushing (mirrors CI):

```sh
mise run validate
```

CI runs the same kustomize build plus yamllint on every push and PR
(`.github/workflows/validate.yml`).

## Secret management

In-cluster secrets are managed with [SOPS](https://github.com/getsops/sops) +
[age](https://github.com/FiloSottile/age), so encrypted manifests can live
safely in Git and Flux decrypts them at reconcile time.

- **`.sops.yaml`** declares the age *public* key (safe to commit) and a rule
  that encrypts only `data`/`stringData` fields of any `*.sops.yaml` file under
  `capi-mgmt/`.
- The age *private* key lives in `age.agekey` (gitignored). `bootstrap.sh`
  loads it into the cluster as the `sops-age` secret in `flux-system`.
- The `capa-system` Flux `Kustomization` has `spec.decryption.provider: sops`
  referencing that secret, so it decrypts `aws-credentials.sops.yaml`.

### First-time setup

```sh
mise run sops-keygen        # creates ./age.agekey and prints the public key
```

Put the printed public key into the `age:` field of `.sops.yaml`, then
re-encrypt existing secrets so they target your key:

```sh
mise run sops-updatekeys
```

### Setting / rotating AWS credentials

```sh
# Generate the base64 profile (requires AWS creds in your shell env):
clusterawsadm bootstrap credentials encode-as-profile

# Put the value into stringData.AWS_B64ENCODED_CREDENTIALS, then encrypt:
$EDITOR capi-mgmt/capi-providers/capa-system/aws-credentials.sops.yaml
mise run sops-encrypt capi-mgmt/capi-providers/capa-system/aws-credentials.sops.yaml
```

View a decrypted secret without changing it:

```sh
mise run sops-decrypt capi-mgmt/capi-providers/capa-system/aws-credentials.sops.yaml
```

The GitHub App secret (`flux-github-app`) is created imperatively by
`bootstrap.sh` and is **not** in Git — Flux needs it to clone the repo before it
could ever decrypt anything (a chicken-and-egg constraint).

> ⚠️ **Credential rotation:** earlier revisions of this repo committed real
> AWS credentials in `capi-mgmt/capi-providers/capa-system/aws-credentials.yaml`.
> Those credentials remain in Git history and **must be rotated/revoked in AWS
> IAM**. Consider scrubbing history with `git filter-repo` if the repository is
> or was public. The committed `aws-credentials.sops.yaml` ships with a
> placeholder value — replace it with your real (rotated) credentials as above.

## Adding a workload cluster

1. Create `capi-mgmt/clusters/<region>/<env>/` with a `cluster.yaml`,
   `kustomization.yaml` (set `namePrefix`), and `capi-nameref.yaml` (so CAPI
   cross-references get the prefix applied — see the existing regions).
2. Register it in `capi-mgmt/clusters/<region>/kustomization.yaml` and add a
   `Kustomization` entry in `capi-mgmt/clusters/flux-ks.yaml` with
   `dependsOn: [capa-system]`.
3. Label the `Cluster` `fluxcd: enabled` to have Flux auto-installed on it.
4. Run `mise run validate`, commit, and push.
