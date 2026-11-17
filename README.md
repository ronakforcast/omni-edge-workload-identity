# GCP Workload Identity for Omni edge workloads (step-by-step)

This directory is a **client-ready walkthrough** for letting pods offloaded to an Omni
edge location authenticate to Google Cloud *as a GCP service account* — with no service
account keys, no exported credentials. The edge cluster's own Kubernetes API server acts
as the OIDC provider for a GCP Workload Identity Federation (WIF) pool; a helper script
(`omni-wif.sh`) does the plumbing and a Kyverno policy on the edge cluster injects a
short-lived token + STS configuration into offloaded pods.

Proven end-to-end (demo job reads and writes a GCS bucket from a pod running on an edge node).

## What you need

- `kubectl` access to the **main** (Omni) cluster, able to read `edgeclusters` and the
  `<edge-cluster>-kubeconfig` secrets in the `castai-omni` namespace.
- `gcloud` authenticated with rights in the target GCP project:
  `roles/iam.workloadIdentityPoolAdmin` (pool/provider) and the ability to grant
  `roles/iam.workloadIdentityUser` on the target service account
  (e.g. `roles/iam.serviceAccountAdmin` or project IAM admin).
- The **edge location id** and **edge location name** of your Omni edge location
  (Omni console / CAST AI AI Enabler API).

## Steps

### 1. Resolve the edge cluster name

WIF is configured per *edge cluster*. Resolve it from your edge location id:

```bash
export EDGE_LOCATION_ID=<edge-location-uuid>
./identify-edge-cluster.sh        # prints export EDGE_CLUSTER_NAME=<edge-cluster-name>
export EDGE_CLUSTER_NAME=<edge-cluster-name>
```

(Or by hand: `kubectl get edgeclusters -n castai-omni` and match `.spec.edgeLocation.id`.)

### 2. Enable Workload Identity Federation for the edge location

```bash
export PROJECT_ID=<your-gcp-project>
./omni-wif.sh apply "$EDGE_CLUSTER_NAME"
```

This is one-time per edge cluster. It creates the WIF pool + OIDC provider in your
project (issuer = the edge cluster's API server), stores the state in a ConfigMap on the
main cluster, and installs Kyverno on the edge cluster (an existing Kyverno is detected
and reused). No workload objects are created yet.

Note: GCP soft-deletes identity pools for 30 days — re-enabling after a `destroy`
un-deletes the pool; nothing manual needed.

### 3. Prepare the namespace and service account

```bash
./setup-ksa.sh                    # NS/KSA/GSA names overridable via env
```

This does, on the main cluster: create the namespace, label it
`omni.cast.ai/enable-scheduling=true` (required for offloading), create the KSA with the
`iam.gke.io/gcp-service-account=<gsa-email>` annotation, and run
`omni-wif.sh authorize -e $EDGE_CLUSTER_NAME <ns>/<ksa>`.

`authorize` is what grants the edge impersonation: it creates the IAM
`workloadIdentityUser` binding for the WIF principal
(`principal://iam.googleapis.com/projects/<num>/locations/global/workloadIdentityPools/<pool>/subject/system:serviceaccount:<ns>:<ksa>`)
on the GSA, and on the edge cluster it creates the KSA, an `sts-creds` ConfigMap and a
Kyverno policy that mutates offloaded pods using this KSA (injects a projected service
account token, mounts the STS config, sets `GOOGLE_APPLICATION_CREDENTIALS`).

### 4. Give your workload something to access

For the demo we use a bucket + a GSA. Skip this step if your GSA and resources exist.

```bash
./setup-bucket-and-gsa.sh         # creates GSA, bucket, hello.txt, IAM bindings
```

Grant the GSA whatever **data-plane** roles your real workload needs (here:
`roles/storage.objectAdmin` on the bucket).

### 5. Run the proof (a pod on the edge using the identity)

```bash
export EDGE_LOCATION_NAME=<edge-location-name>
./setup-workload.sh               # applies a demo Job pinned to the edge location
kubectl logs -n wif-demo -l job-name=wif-demo -f
```

Expected: the pod lists the bucket, prints `hello from GCS`, writes a
`from-omni-<pod>.txt` object back and ends with `OK` — authenticated purely via WIF.
In your own workloads the only requirement is `serviceAccountName: <the-authorized-ksa>`;
GCP client libraries pick up `GOOGLE_APPLICATION_CREDENTIALS` automatically.

## Constraints and gotchas

- **Per-KSA opt-in:** each Kubernetes service account must be explicitly `authorize`d —
  there is no blanket enable. Repeat step 3 for every KSA that needs a GCP identity.
- **The annotation is mandatory:** the KSA on the main cluster must carry
  `iam.gke.io/gcp-service-account: <gsa-email>` *before* running `authorize` (the script
  reads the GSA email from it).
- **Roles belong on the GSA, not the KSA** — roles assigned directly to a K8s SA are
  not honored.
- **Recreate running pods:** the mutation is applied at admission; already-running
  offloaded pods must be deleted and recreated to receive credentials.
- **IAM propagation:** the first token acquisition right after `authorize` may fail
  transiently; bindings take up to ~2 minutes to propagate (the demo job retries).
- Offloaded pods get `GOOGLE_APPLICATION_CREDENTIALS` pointing at
  `/etc/gcp-auth/sts-creds.json`; the federated token lives at
  `/var/run/secrets/tokens/gcp-ksa/token` (paths overridable via env in `omni-wif.sh`).

## Tearing down

```bash
./omni-wif.sh deauthorize -e "$EDGE_CLUSTER_NAME" <ns>/<ksa>   # revoke one KSA
./omni-wif.sh destroy "$EDGE_CLUSTER_NAME"                     # full teardown: all KSAs,
                                                               # Kyverno (if we installed it),
                                                               # provider + pool
```

`gcloud iam workload-identity-pools delete` is *not* needed — `destroy` handles GCP side
(and the 30-day soft-delete is handled on the next `apply`).

## Files

| file | purpose |
|---|---|
| `omni-wif.sh` | the mechanism: `apply` / `authorize` / `deauthorize` / `destroy` (idempotent, env-overridable — run with no args for full docs) |
| `identify-edge-cluster.sh` | edge location ID → edge cluster name |
| `setup-ksa.sh` | namespace + offloading label + annotated KSA + `authorize` (step 3) |
| `setup-bucket-and-gsa.sh` | demo GSA + bucket + IAM (step 4; optional) |
| `setup-workload.sh` | demo Job that proves the identity end-to-end (step 5) |
