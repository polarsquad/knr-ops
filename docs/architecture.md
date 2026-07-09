# Architecture

GitOps-driven [Cluster API](https://cluster-api.sigs.k8s.io/) (CAPI) management
platform. A local [kind](https://kind.sigs.k8s.io/) cluster bootstraps
[Flux](https://fluxcd.io/), which then reconciles everything else from this
repository — AWS EKS workload clusters provisioned via
[CAPA](https://cluster-api-aws.sigs.k8s.io/), per-cluster Flux instances
delivered through CAPI addons, and application workloads (the
[ACK](https://aws-controllers-k8s.github.io/docs/) S3, RDS, and IAM operators
managing secure S3 buckets, PostgreSQL instances, and read-only IAM roles)
running on each workload cluster.

```mermaid
flowchart TD
    subgraph bootstrap["Bootstrap (one-time, bootstrap.sh)"]
        KIND[kind cluster: capi-mgmt]
        HELM[Helm: flux-operator + FluxInstance]
        SEC[Secrets: flux-github-pat + sops-age]
        KIND --> HELM
        KIND --> SEC
    end

    subgraph git["Git: github.com/polarsquad/knr-ops"]
        REPO[(main branch)]
    end

    HELM -->|"sync: capi-mgmt/"| REPO

    subgraph mgmt["Management cluster - Flux Kustomizations (dependsOn order)"]
        FS[flux-system root]
        CM[cert-manager]
        CO[capi-operator]
        CI[capa-identity]
        AMC[aws-managed-clusters]
        CAPIS[capi-system]
        CAPAS["capa-system (SOPS creds)"]
        CAAPH[caaph-system]
        ACKC["ack-controllers (SOPS creds)<br/>ACK IAM + EKS controllers"]
        ACKPI["ack-pod-identity<br/>IAM Role + PodIdentityAssociations"]
        AWSIAM["aws-iam<br/>knr-ops-reader console user"]
        KONF["konflate (SOPS token)<br/>rendered Flux PR review"]
        EUN[eu-north-1 cluster def]
        EUW[eu-west-1 cluster def]
        FA["flux-apps (SOPS pull secret)<br/>HelmChartProxy + ClusterResourceSets"]

        FS --> CM --> CO
        CO --> CI --> AMC
        CO --> CAPIS --> CAPAS --> CAAPH --> FA
        CAPAS --> EUN
        CAPAS --> EUW
        FS --> ACKC --> ACKPI
        ACKC --> AWSIAM
        FS --> KONF
    end

    REPO --> FS

    subgraph aws["AWS"]
        EKS1[EKS: eu-north-1-workload<br/>ARM + GPU node pools<br/>pod-identity agent addon]
        EKS2[EKS: eu-west-1-workload<br/>ARM + GPU node pools<br/>pod-identity agent addon]
        ROLE[IAM Role: knr-ops-ack-s3-controller<br/>trust: pods.eks.amazonaws.com]
        RDSROLE[IAM Role: knr-ops-ack-rds-controller<br/>trust: pods.eks.amazonaws.com]
        IAMROLE[IAM Role: knr-ops-ack-iam-controller<br/>trust: pods.eks.amazonaws.com]
        B1[(S3: knr-ops-...-eu-north-1-workload-data)]
        B2[(S3: knr-ops-...-eu-west-1-workload-data)]
        DB1[(RDS: knr-ops-eu-north-1-workload-db)]
        DB2[(RDS: knr-ops-eu-west-1-workload-db)]
        RD1[IAM Role: knr-ops-eu-north-1-workload-reader<br/>trust: account root]
        RD2[IAM Role: knr-ops-eu-west-1-workload-reader<br/>trust: account root]
        RUSER[IAM User: knr-ops-reader<br/>console login, assumes reader roles]
    end

    EUN -->|CAPA provisions| EKS1
    EUW -->|CAPA provisions| EKS2
    ACKPI -->|creates| ROLE
    ACKPI -->|creates| RDSROLE
    ACKPI -->|creates| IAMROLE
    AWSIAM -->|creates| RUSER
    RUSER -.->|sts:AssumeRole| RD1
    RUSER -.->|sts:AssumeRole| RD2
    ACKPI -->|binds SAs to roles| EKS1
    ACKPI -->|binds SAs to roles| EKS2

    FA -->|"HelmChartProxy: flux-operator<br/>CRS: FluxInstance + cluster-vars + pull secret"| WF1
    FA -->|same, per region label| WF2

    subgraph wl1["Workload cluster eu-north-1"]
        WF1["Flux (sync: apps/eu-north-01)"]
        AO1["aws-operators Ks<br/>ACK S3 + RDS + IAM controllers (Pod Identity)"]
        SB1["s3-buckets Ks<br/>dependsOn: aws-operators"]
        RI1["rds-instances Ks<br/>dependsOn: aws-operators"]
        IR1["iam-roles Ks<br/>dependsOn: aws-operators"]
        WF1 --> AO1 --> SB1
        AO1 --> RI1
        AO1 --> IR1
    end

    subgraph wl2["Workload cluster eu-west-1"]
        WF2["Flux (sync: apps/eu-west-01)"]
        AO2["aws-operators Ks<br/>ACK S3 + RDS + IAM controllers (Pod Identity)"]
        SB2["s3-buckets Ks<br/>dependsOn: aws-operators"]
        RI2["rds-instances Ks<br/>dependsOn: aws-operators"]
        IR2["iam-roles Ks<br/>dependsOn: aws-operators"]
        WF2 --> AO2 --> SB2
        AO2 --> RI2
        AO2 --> IR2
    end

    WF1 --> REPO
    WF2 --> REPO
    ROLE -.->|credentials via pod identity| AO1
    ROLE -.->|credentials via pod identity| AO2
    RDSROLE -.->|credentials via pod identity| AO1
    RDSROLE -.->|credentials via pod identity| AO2
    IAMROLE -.->|credentials via pod identity| AO1
    IAMROLE -.->|credentials via pod identity| AO2
    SB1 -->|Bucket CR reconciled| B1
    SB2 -->|Bucket CR reconciled| B2
    RI1 -->|DBInstance CR reconciled| DB1
    RI2 -->|DBInstance CR reconciled| DB2
    IR1 -->|Role CR reconciled| RD1
    IR2 -->|Role CR reconciled| RD2
```

## Reconciliation order (management cluster)

Enforced with Flux `dependsOn`:

```
cert-manager ▶ capi-operator ▶ capi-system ▶ capa-system ▶ clusters (eu-north-1, eu-west-1)
                            │                            └▶ caaph-system ▶ flux-apps
                            └▶ capa-identity ▶ aws-managed-clusters
ack-controllers ▶ ack-pod-identity
ack-controllers ▶ aws-iam
konflate (no dependencies)
```

## PR review: konflate

The management cluster also runs a single
[konflate](https://github.com/home-operations/konflate) instance
(`capi-mgmt/infrastructure/konflate/`), pointed at this repo
(`github://polarsquad/knr-ops`, rendering from the repo root). It renders each
open PR at its merge-base and head and shows the diff of the *rendered* Flux
output — blast radius, image changes, render failures, and danger lint —
instead of the raw file diff. The `konflate` GitHub Actions workflow
(`.github/workflows/konflate.yml`) triggers an immediate re-render on each PR
push, posts the rendered summary as a PR comment, and fails the check when the
render fails. The UI is not exposed outside the cluster; reach it with
`kubectl port-forward -n konflate svc/konflate 8080:8080`.

## Reconciliation order (each workload cluster)

```
aws-operators (ACK S3 + RDS + IAM controllers) ▶ s3-buckets (Bucket CRs)
                                               ├▶ rds-instances (DBInstance CRs)
                                               └▶ iam-roles (Role CRs)
```

## How workload apps are delivered

1. Each `Cluster` in `capi-mgmt/clusters/` carries labels `fluxcd: enabled`
   and `region: <region>`.
2. `flux-apps` matches those labels: a **HelmChartProxy** installs the Flux
   Operator on every workload cluster, and per-region **ClusterResourceSets**
   apply a `FluxInstance` (syncing `apps/<region>-01/`), a `cluster-vars`
   ConfigMap (`AWS_REGION`, `CLUSTER_NAME`, `AWS_ACCOUNT_ID` — used by Flux
   `postBuild` substitution), and the Git pull secret.
3. The workload cluster's Flux reconciles `apps/`: first `aws-operators`
   (ACK S3 + RDS + IAM controllers, `wait: true`), then `s3-buckets`,
   `rds-instances`, and `iam-roles` (all `dependsOn: aws-operators`).

See [AWS authentication & IAM](./aws-iam.md) for how the ACK controllers
authenticate, and [Workload resources](./workload-resources.md) for what they
create.
