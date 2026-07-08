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
