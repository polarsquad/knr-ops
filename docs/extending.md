# Adding clusters and apps

## Adding a workload cluster

1. Create `capi-mgmt/clusters/<region>/<env>/` with a `cluster.yaml`,
   `kustomization.yaml` (set `namePrefix`), and `capi-nameref.yaml` (so CAPI
   cross-references get the prefix applied — see the existing regions).
2. Label the `Cluster` with `fluxcd: enabled` **and** `region: <region>`, and
   include the `eks-pod-identity-agent` addon in the `AWSManagedControlPlane`.
3. Register it in `capi-mgmt/clusters/<region>/kustomization.yaml` and add a
   `Kustomization` entry in `capi-mgmt/clusters/flux-ks.yaml` with
   `dependsOn: [capa-system]`.
4. In `capi-mgmt/addons/flux-apps/flux-instance.yaml`, add a per-region
   FluxInstance ConfigMap (sync path `apps/<region>-01`, plus `cluster-vars`)
   and a matching `ClusterResourceSet`.
5. Add a `PodIdentityAssociation` for the new cluster in
   `capi-mgmt/infrastructure/ack-pod-identity/pod-identity-associations.yaml`
   (use the `services.k8s.aws/region` annotation for non-default regions).
6. Create `apps/<region>-01/kustomization.yaml` pointing at `../base`.
7. Run `mise run validate`, commit, and push.

## Adding apps to the workload clusters

Follow the `aws-operators` / `s3-buckets` pattern in `apps/base/`:

1. Create `apps/base/<app>/` with a `kustomization.yaml` listing the app's
   manifests, and a `flux-ks.yaml` defining the Flux `Kustomization`
   (path `./apps/base/<app>`; add `dependsOn` and `wait: true` as needed;
   use `postBuild.substituteFrom: cluster-vars` for per-cluster values like
   `${AWS_REGION}` and `${CLUSTER_NAME}`).
2. Register the `flux-ks.yaml` in `apps/base/kustomization.yaml`.
3. Run `mise run validate`, commit, and push — every workload cluster picks it
   up on its next sync.

## Using other providers

The management cluster is not AWS-only. Providers are declared as CAPI
operator CRs (`operator.cluster.x-k8s.io/v1alpha2`) under
`capi-mgmt/capi-providers/`, one directory per provider namespace, and
registered in `capi-mgmt/capi-providers/flux-ks.yaml`. The operator resolves
the well-known provider names (`aws`, `azure`, `talos`,
`k0sproject-k0smotron`) from the same built-in registry `clusterctl` uses, so
a provider is just a typed CR with a pinned version:

```
capi-mgmt/capi-providers/<name>-system/
  namespace.yaml
  kustomization.yaml        # lists namespace.yaml + providers.yaml (+ secrets)
  providers.yaml            # the typed provider CR(s)
  <credentials>.sops.yaml   # optional cloud credentials, SOPS-encrypted
```

The Flux registration in `flux-ks.yaml` follows the existing entries:
`dependsOn: [capi-system]`, `decryption.provider: sops` when credentials ship
in Git, and a `healthChecks` entry naming one CRD the provider installs so
Flux waits for it.

Contract note: this repo pins CAPI core v1.14.0, which speaks the v1beta2
contract and still accepts v1beta1-contract providers until the v1beta1
removal (tentatively CAPI v1.16, April 2027). Prefer providers that already
speak v1beta2.

### AWS (CAPA): the reference wiring

CAPA is the provider this repo already runs; use it as the template:

- `capi-mgmt/capi-providers/capa-system/providers.yaml` declares
  `InfrastructureProvider aws` v2.13.0 with `configSecret: aws-credentials`
  and the EKS feature gates
  (`EKS=true,EKSEnableIAM=true,EKSAllowAddRoles=true,MachinePool=true`).
- `aws-credentials.sops.yaml` carries `AWS_B64ENCODED_CREDENTIALS`, produced
  by `mise run aws-credentials` (rotation: [docs/secrets.md](./secrets.md)).
- Cluster definitions in `capi-mgmt/clusters/<region>/<env>/` use
  `AWSManagedControlPlane` + `AWSManagedMachinePool` (EKS). Per-cluster IAM
  for the ACK controllers is wired through
  `capi-mgmt/infrastructure/ack-pod-identity/` (see
  [docs/aws-iam.md](./aws-iam.md)).

### Azure (CAPZ)

CAPZ v1.26.0 speaks v1beta2 and bundles Azure Service Operator (ASO) v2.18.0,
which backs the managed-AKS path.

1. Create a service principal (`az ad sp create-for-rbac`) and store two
   SOPS secrets in `capi-mgmt/capi-providers/capz-system/`:
   - the SP client secret, referenced by an `AzureClusterIdentity` CR
     (environment-variable auth is deprecated upstream; see the CAPZ
     multitenancy docs);
   - `aso-credentials.sops.yaml` with `AZURE_SUBSCRIPTION_ID`,
     `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` for the
     bundled ASO controller.
2. Declare the provider in `capz-system/providers.yaml`:

   ```yaml
   apiVersion: operator.cluster.x-k8s.io/v1alpha2
   kind: InfrastructureProvider
   metadata:
     name: azure
     namespace: capz-system
   spec:
     version: "v1.26.0"
   ```

   No feature gates are needed for the ASO managed-cluster path.
3. Register a `capz-system` Kustomization in `flux-ks.yaml` with SOPS
   decryption and a healthCheck on
   `azureclusters.infrastructure.cluster.x-k8s.io` (add the
   `azureasomanagedclusters...` CRD when using the AKS path).
4. Define AKS clusters in `capi-mgmt/clusters/<location>/<env>/` with the
   `AzureASOManagedCluster` / `AzureASOManagedControlPlane` /
   `AzureASOManagedMachinePool` types, keeping the repo conventions:
   `namePrefix` kustomization, `capi-nameref.yaml`, the `fluxcd: enabled` and
   region labels, and `cluster-vars` substitutions for the Azure location in
   place of `${AWS_REGION}`. The AWS-only steps (Pod Identity associations,
   ACK controllers) have no Azure equivalent; skip them.

### Talos (CABPT + CACPT)

Talos supplies the bootstrap and control plane providers only; pair it with
any infrastructure provider (CAPA, CAPZ, k0smotron RemoteMachine, ...) that
supplies the machines.

1. Two directories, matching the upstream namespace conventions:

   ```yaml
   # capi-mgmt/capi-providers/cabpt-system/providers.yaml
   apiVersion: operator.cluster.x-k8s.io/v1alpha2
   kind: BootstrapProvider
   metadata:
     name: talos
     namespace: cabpt-system
   spec:
     version: "v0.6.11"
   ---
   # capi-mgmt/capi-providers/cacppt-system/providers.yaml
   apiVersion: operator.cluster.x-k8s.io/v1alpha2
   kind: ControlPlaneProvider
   metadata:
     name: talos
     namespace: cacppt-system
   spec:
     version: "v0.5.13"
   ```

2. No cloud credentials: Talos machine secrets are generated per cluster by
   `TalosControlPlane` / `TalosConfig`. Always set `talosVersion` explicitly
   (e.g. `v1.12`) so a provider upgrade does not silently change the
   generated machine config.
3. Contract caveat: the stable Talos providers still implement the v1beta1
   contract, which CAPI serves only until ~April 2027. The v1beta2 line is
   CABPT v0.7.0 (in alpha at time of writing); adopt it once it goes stable.
4. In cluster definitions, swap `KubeadmControlPlane` for `TalosControlPlane`
   and `KubeadmConfigTemplate` for `TalosConfigTemplate`; the infrastructure
   templates stay whatever the paired infra provider supplies.

### k0smotron

k0smotron v2.1.0 is v1beta2-native and ships bootstrap, control plane, and
infrastructure providers under one name:

```yaml
# capi-mgmt/capi-providers/k0smotron-system/providers.yaml
apiVersion: operator.cluster.x-k8s.io/v1alpha2
kind: BootstrapProvider
metadata:
  name: k0sproject-k0smotron
  namespace: k0smotron-system
spec:
  version: "v2.1.0"
---
apiVersion: operator.cluster.x-k8s.io/v1alpha2
kind: ControlPlaneProvider
metadata:
  name: k0sproject-k0smotron
  namespace: k0smotron-system
spec:
  version: "v2.1.0"
---
apiVersion: operator.cluster.x-k8s.io/v1alpha2
kind: InfrastructureProvider
metadata:
  name: k0sproject-k0smotron
  namespace: k0smotron-system
spec:
  version: "v2.1.0"
```

- No cloud credentials are needed, and the cert-manager the repo already
  installs covers its webhooks.
- Hosted control planes: `K0smotronControlPlane` runs the child cluster's
  control plane as pods on the management cluster; workers come from any
  infra provider.
- Remote machines: `RemoteMachine` provisions k0s onto existing machines over
  SSH (bare metal, arbitrary VMs, anywhere with no CAPI cloud provider).
- Drop the `InfrastructureProvider` CR if you only want hosted control
  planes.

### After adding a provider

1. `mise run validate` builds every overlay, including the new directory.
2. Open the PR; konflate renders the blast radius (new CRDs, provider
   deployments) into the PR comment and the `konflate / Rendered Flux diff`
   check.
3. After merge, confirm the provider came up:
   `kubectl get pods -n <name>-system` and
   `kubectl get <kind>providers.operator.cluster.x-k8s.io -A` (e.g.
   `infrastructureproviders`).
