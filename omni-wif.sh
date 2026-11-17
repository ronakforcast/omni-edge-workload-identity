#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# omni-wif.sh — Workload Identity Federation for Omni edge clusters
#
#   apply       <edge-cluster-name>
#   destroy     <edge-cluster-name>
#   authorize   -e <edge-cluster-name> <sa-namespace>/<sa-name>
#   deauthorize -e <edge-cluster-name> <sa-namespace>/<sa-name>
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  omni-wif.sh apply       <edge-cluster-name>
  omni-wif.sh destroy     <edge-cluster-name>
  omni-wif.sh authorize   -e <edge-cluster-name> <sa-namespace>/<sa-name>
  omni-wif.sh deauthorize -e <edge-cluster-name> <sa-namespace>/<sa-name>

Commands:
  apply        Configure WIF for an edge cluster: create the workload identity
               pool + OIDC provider, persist WIF metadata in a ConfigMap in the
               castai-omni namespace, install Kyverno on the edge cluster, grant
               Kyverno the extra RBAC it needs, and wait for Kyverno to be Ready.
               No ServiceAccount / IAM binding / pod is created.
  destroy      Undo `apply`: deauthorize every tracked ServiceAccount, then
               remove the state ConfigMap, Kyverno (only if installed by apply)
               and the workload identity provider + pool.
  authorize    Allow an offloaded (GKE Workload Identity) KSA to impersonate its
               GSA from the edge cluster. Creates the SA + sts-creds ConfigMap +
               Kyverno policy on the edge cluster and the IAM binding on the GSA.
  deauthorize  Undo `authorize` for one KSA (IAM binding, Kyverno policy,
               sts-creds ConfigMap, edge ServiceAccount, registry entry).

Environment variables (defaults shown):
  PROJECT_ID       GCP project for the WIF pool/provider   (REQUIRED, no default)
  POOL_NAME        Workload Identity Pool name             (default: omni-wif-<sha256[:15]>)
  PROVIDER_NAME    OIDC Provider name                      (default: omni-wif-<sha256[:15]>)
  ISSUER_URI       OIDC issuer URI                         (default: https://kubernetes.default.svc)
  OMNI_NAMESPACE   Namespace holding Omni objects          (default: castai-omni)
  KYVERNO_NS       Kyverno namespace                       (default: kyverno)
  KYVERNO_VERSION  Kyverno release to install              (default: v1.16.2)
  TOKEN_PATH       Path of the projected token in the pod  (default: /var/run/secrets/tokens/gcp-ksa/token)
  CRED_MOUNT       Mount path of the sts-creds ConfigMap   (default: /etc/gcp-auth)
  CRED_FILE        Key/file name inside that ConfigMap     (default: sts-creds.json)

Main cluster = current kubectl context (GKE). Edge cluster = kubeconfig stored in
secret '<edge-cluster-name>-kubeconfig' in the castai-omni namespace.
EOF
  exit 1
}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || usage

MODE="$1"
shift

EDGE_CLUSTER=""
SA_INPUT=""
SA_NAME=""
SA_NAMESPACE=""

case "$MODE" in
  apply|destroy)
    [[ $# -eq 1 ]] || { echo "ERROR: '$MODE' takes exactly one argument: <edge-cluster-name>" >&2; usage; }
    EDGE_CLUSTER="$1"
    ;;
  authorize|deauthorize)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -e|--edge-cluster)
          [[ $# -ge 2 ]] || { echo "ERROR: -e requires a value" >&2; usage; }
          EDGE_CLUSTER="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "ERROR: unknown option '$1'" >&2; usage ;;
        *) SA_INPUT="$1"; shift ;;
      esac
    done
    [[ -n "$EDGE_CLUSTER" ]] || { echo "ERROR: -e <edge-cluster-name> is required" >&2; usage; }
    [[ -n "$SA_INPUT" ]] || { echo "ERROR: <sa-namespace>/<sa-name> is required" >&2; usage; }
    ;;
  -h|--help|help) usage ;;
  *) echo "ERROR: unknown command '$MODE'" >&2; usage ;;
esac

[[ -n "$EDGE_CLUSTER" ]] || { echo "ERROR: edge-cluster-name must not be empty" >&2; usage; }

if [[ "$MODE" == "authorize" || "$MODE" == "deauthorize" ]]; then
  slashes="$(printf '%s' "$SA_INPUT" | tr -cd '/')"
  if [[ "${#slashes}" -ne 1 ]]; then
    echo "ERROR: expected <sa-namespace>/<sa-name>, got '$SA_INPUT'" >&2
    usage
  fi
  SA_NAMESPACE="${SA_INPUT%%/*}"
  SA_NAME="${SA_INPUT##*/}"
  [[ -n "$SA_NAMESPACE" && -n "$SA_NAME" ]] || {
    echo "ERROR: <sa-namespace> and <sa-name> must both be non-empty, got '$SA_INPUT'" >&2
    usage
  }
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-15
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-15
  else
    die "no sha256 tool found (need 'sha256sum' or 'shasum')"
  fi
}

CLUSTER_SUFFIX="$(sha256_hex "$EDGE_CLUSTER")"

PROJECT_ID="${PROJECT_ID:-}"
POOL_NAME="${POOL_NAME:-omni-wif-${CLUSTER_SUFFIX}}"
PROVIDER_NAME="${PROVIDER_NAME:-omni-wif-${CLUSTER_SUFFIX}}"
ISSUER_URI="${ISSUER_URI:-https://kubernetes.default.svc}"
OMNI_NAMESPACE="${OMNI_NAMESPACE:-castai-omni}"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"
KYVERNO_VERSION="${KYVERNO_VERSION:-v1.16.2}"
TOKEN_PATH="${TOKEN_PATH:-/var/run/secrets/tokens/gcp-ksa/token}"
CRED_MOUNT="${CRED_MOUNT:-/etc/gcp-auth}"
CRED_FILE="${CRED_FILE:-sts-creds.json}"
SECRET_NAME="${SECRET_NAME:-${EDGE_CLUSTER}-kubeconfig}"

TOKEN_MOUNT_DIR="$(dirname "$TOKEN_PATH")"

STATE_CM="omni-wif-${EDGE_CLUSTER}"
EDGE_KUBECONFIG="/tmp/${EDGE_CLUSTER}-kubeconfig"
JWKS_FILE="/tmp/jwks-${EDGE_CLUSTER}.json"
KYVERNO_INSTALL_URL="https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"
KYVERNO_RBAC_NAME="kyverno-read-secrets"

# State (populated by state_load / do_apply)
PROJECT_NUMBER=""
PROVIDER_URL=""
KYVERNO_MANAGED=""
REGISTRY=""
GSA_EMAIL=""
GSA_PROJECT=""
SA_CM=""
SA_POLICY=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
require_tools() {
  local tool
  for tool in gcloud kubectl base64; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
  done
}

require_project_id() {
  [[ -n "$PROJECT_ID" ]] \
    || die "PROJECT_ID is required; export PROJECT_ID=<gcp-project-id>"
}

wait_iam() {
  log "Waiting 5 seconds for IAM propagation..."
  sleep 5
}

validate_names() {
  local len
  len="${#POOL_NAME}"
  [[ "$len" -ge 4 && "$len" -le 32 ]] || die "POOL_NAME '${POOL_NAME}' must be 4-32 chars (is ${len})"
  len="${#PROVIDER_NAME}"
  [[ "$len" -ge 4 && "$len" -le 32 ]] || die "PROVIDER_NAME '${PROVIDER_NAME}' must be 4-32 chars (is ${len})"
}

fetch_edge_kubeconfig() {
  log "Fetching edge cluster kubeconfig from secret '${SECRET_NAME}' in namespace '${OMNI_NAMESPACE}'..."
  kubectl get secret -n "$OMNI_NAMESPACE" "$SECRET_NAME" \
    -o jsonpath='{.data.value}' \
    | base64 -d > "$EDGE_KUBECONFIG" \
    || die "could not read secret '${OMNI_NAMESPACE}/${SECRET_NAME}'"
  chmod 600 "$EDGE_KUBECONFIG"
}

edge_kubectl() {
  kubectl --kubeconfig="$EDGE_KUBECONFIG" "$@"
}

# --- State ConfigMap helpers -----------------------------------------------

state_cm_exists() {
  kubectl get configmap -n "$OMNI_NAMESPACE" "$STATE_CM" >/dev/null 2>&1
}

state_get() {
  local v
  v="$(kubectl get configmap -n "$OMNI_NAMESPACE" "$STATE_CM" \
        -o go-template="{{index .data \"$1\"}}" 2>/dev/null || true)"
  [[ "$v" == "<no value>" ]] && v=""
  printf '%s' "$v"
}

state_load() {
  state_cm_exists || die "no WIF state found for edge cluster '${EDGE_CLUSTER}' (state ConfigMap '${OMNI_NAMESPACE}/${STATE_CM}' missing). Run: omni-wif.sh apply ${EDGE_CLUSTER}"
  PROJECT_ID="$(state_get project-id)"
  PROJECT_NUMBER="$(state_get project-number)"
  POOL_NAME="$(state_get pool-name)"
  PROVIDER_NAME="$(state_get provider-name)"
  PROVIDER_URL="$(state_get provider-url)"
  ISSUER_URI="$(state_get issuer)"
  KYVERNO_MANAGED="$(state_get kyverno-managed)"
  REGISTRY="$(state_get authorized)"
  [[ -n "$POOL_NAME" && -n "$PROVIDER_URL" ]] || die "state ConfigMap '${OMNI_NAMESPACE}/${STATE_CM}' is incomplete; re-run apply"
}

state_write_all() {
  kubectl create configmap "$STATE_CM" -n "$OMNI_NAMESPACE" \
    --from-literal=project-id="$PROJECT_ID" \
    --from-literal=project-number="$PROJECT_NUMBER" \
    --from-literal=pool-name="$POOL_NAME" \
    --from-literal=provider-name="$PROVIDER_NAME" \
    --from-literal=provider-url="$PROVIDER_URL" \
    --from-literal=issuer="$ISSUER_URI" \
    --from-literal=kyverno-managed="$KYVERNO_MANAGED" \
    --from-literal=authorized="$REGISTRY" \
    --dry-run=client -o yaml \
    | kubectl apply -f -
}

registry_add() { # $1=<ns>/<sa>  $2=<gsa_email>
  local entry="$1 $2" out
  if printf '%s\n' "$REGISTRY" | grep -qxF -- "$entry"; then
    return 0
  fi
  out="$(printf '%s\n%s' "$REGISTRY" "$entry")"
  REGISTRY="$(printf '%s\n' "$out" | sed '/^$/d')"
}

registry_remove() { # $1=<ns>/<sa>
  local out
  out="$(printf '%s\n' "$REGISTRY" | grep -vF -- "$1 " || true)"
  REGISTRY="$(printf '%s\n' "$out" | sed '/^$/d')"
}

registry_gsa() { # $1=<ns>/<sa> -> prints gsa or empty
  printf '%s\n' "$REGISTRY" | awk -v k="$1" '$1==k {print $2; exit}'
}

# --- Main-cluster lookups ---------------------------------------------------

read_gsa_from_main_ksa() { # $1=namespace $2=name -> prints GSA email or empty
  local v
  # Guard with `if .metadata.annotations`: a service account with no annotations
  # at all has a nil map, and `index nil <key>` makes the Go template error out
  # (kubectl prints that error to stdout, which would otherwise be captured here).
  v="$(kubectl get serviceaccount "$2" -n "$1" \
        -o go-template='{{if .metadata.annotations}}{{index .metadata.annotations "iam.gke.io/gcp-service-account"}}{{end}}' 2>/dev/null || true)"
  [[ "$v" == "<no value>" ]] && v=""
  printf '%s' "$v"
}

assert_namespace_offloaded() { # $1=namespace (main cluster)
  kubectl get namespace "$1" >/dev/null 2>&1 || die "namespace '$1' not found in the main cluster (current context)"
  local v
  v="$(kubectl get namespace "$1" -o go-template='{{if .metadata.labels}}{{index .metadata.labels "omni.cast.ai/enable-scheduling"}}{{end}}' 2>/dev/null || true)"
  [[ "$v" == "true" ]] || die "namespace '$1' is not offloaded (missing label omni.cast.ai/enable-scheduling=true)"
}

# --- Shared per-entry teardown ---------------------------------------------

deauthorize_entry() { # $1=namespace $2=sa-name $3=gsa-email (may be empty)
  local ns="$1" sa="$2" gsa="$3" gsa_project principal cm policy

  cm="wif-sts-creds-${sa}"
  policy="wif-auth-${sa}"

  if [[ -n "$gsa" ]]; then
    gsa_project="${gsa##*@}"
    gsa_project="${gsa_project%.iam.gserviceaccount.com}"
    principal="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/subject/system:serviceaccount:${ns}:${sa}"
    log "Removing IAM workloadIdentityUser binding for ${ns}/${sa} on ${gsa}..."
    gcloud iam service-accounts remove-iam-policy-binding "$gsa" \
      --project="$gsa_project" \
      --role="roles/iam.workloadIdentityUser" \
      --member="$principal" \
      --quiet >/dev/null 2>&1 || warn "could not remove IAM binding (may not exist)"
  else
    warn "no GSA known for ${ns}/${sa}; skipping IAM binding removal"
  fi

  if edge_kubectl get crd policies.kyverno.io >/dev/null 2>&1; then
    edge_kubectl delete policy "$policy" -n "$ns" --ignore-not-found=true
  else
    warn "Kyverno CRDs not found on edge cluster; skipping policy '${ns}/${policy}'"
  fi
  edge_kubectl delete configmap "$cm" -n "$ns" --ignore-not-found=true
  edge_kubectl delete serviceaccount "$sa" -n "$ns" --ignore-not-found=true
}

# ---------------------------------------------------------------------------
# APPLY
# ---------------------------------------------------------------------------
do_apply() {
  require_tools
  require_project_id
  validate_names
  fetch_edge_kubeconfig

  log "Fetching JWKS from edge cluster API server..."
  edge_kubectl get --raw /openid/v1/jwks > "$JWKS_FILE" \
    || die "could not fetch JWKS from edge cluster"
  [[ -s "$JWKS_FILE" ]] || die "empty JWKS received from edge cluster"

  log "Fetching project number for '${PROJECT_ID}'..."
  PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
  [[ -n "$PROJECT_NUMBER" ]] || die "could not resolve project number for '${PROJECT_ID}'"
  log "PROJECT_NUMBER=${PROJECT_NUMBER}"

  # GCP soft-deletes Workload Identity Pools/Providers for 30 days: `describe` still
  # resolves a DELETED resource, but creating a provider under a DELETED pool (or a
  # provider with the same name as a DELETED one) fails with NOT_FOUND. So inspect the
  # state and undelete when needed (a plain existence check is not enough).
  log "Ensuring Workload Identity Pool '${POOL_NAME}'..."
  pool_state="$(gcloud iam workload-identity-pools describe "$POOL_NAME" \
    --project="$PROJECT_ID" --location=global --format='value(state)' 2>/dev/null || true)"
  case "$pool_state" in
    ACTIVE)
      log "Pool already exists." ;;
    DELETED)
      log "Pool is soft-deleted; undeleting..."
      gcloud iam workload-identity-pools undelete "$POOL_NAME" \
        --project="$PROJECT_ID" --location=global --quiet
      wait_iam ;;
    "")
      log "Creating pool..."
      gcloud iam workload-identity-pools create "$POOL_NAME" \
        --project="$PROJECT_ID" --location=global --display-name="$POOL_NAME"
      wait_iam ;;
    *)
      warn "Pool '${POOL_NAME}' is in unexpected state '${pool_state}'." ;;
  esac

  log "Ensuring OIDC Provider '${PROVIDER_NAME}'..."
  provider_state="$(gcloud iam workload-identity-pools providers describe "$PROVIDER_NAME" \
    --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL_NAME" \
    --format='value(state)' 2>/dev/null || true)"
  case "$provider_state" in
    ACTIVE)
      log "Provider already exists." ;;
    DELETED)
      log "Provider is soft-deleted; undeleting..."
      gcloud iam workload-identity-pools providers undelete "$PROVIDER_NAME" \
        --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL_NAME" --quiet
      # An undeleted provider keeps its previously stored configuration, so force the
      # freshly fetched JWKS (signing keys may have rotated while it was deleted).
      log "Refreshing the undeleted provider's JWKS from ${JWKS_FILE}..."
      gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_NAME" \
        --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL_NAME" \
        --jwk-json-path="$JWKS_FILE"
      wait_iam ;;
    "")
      log "Creating provider..."
      gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_NAME" \
        --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL_NAME" \
        --display-name="$PROVIDER_NAME" \
        --issuer-uri="$ISSUER_URI" \
        --jwk-json-path="$JWKS_FILE" \
        --attribute-mapping="google.subject=assertion.sub,attribute.namespace=assertion['kubernetes.io/serviceaccount/namespace']"
      wait_iam ;;
    *)
      warn "Provider '${PROVIDER_NAME}' is in unexpected state '${provider_state}'." ;;
  esac

  PROVIDER_URL="$(gcloud iam workload-identity-pools providers describe "$PROVIDER_NAME" \
    --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL_NAME" \
    --format='value(name)')"
  [[ -n "$PROVIDER_URL" ]] || die "could not resolve provider resource name"
  log "PROVIDER_URL=${PROVIDER_URL}"

  # Preserve any existing authorization registry.
  REGISTRY="$(state_get authorized 2>/dev/null || true)"

  if edge_kubectl get namespace "$KYVERNO_NS" >/dev/null 2>&1; then
    KYVERNO_MANAGED="false"
    log "Kyverno already present in namespace '${KYVERNO_NS}'; skipping install (will not be uninstalled by destroy)."
  else
    log "Installing Kyverno ${KYVERNO_VERSION} on edge cluster..."
    edge_kubectl create -f "$KYVERNO_INSTALL_URL"
    KYVERNO_MANAGED="true"
  fi

  log "Waiting for Kyverno deployments to become Available..."
  edge_kubectl wait --for=condition=Available --timeout=300s deployment --all -n "$KYVERNO_NS"

  log "Applying Kyverno extra RBAC (aggregated ClusterRole '${KYVERNO_RBAC_NAME}')..."
  edge_kubectl apply -f - <<'KYVERNO_RBAC'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno-read-secrets
  labels:
    # Attach these permissions to Kyverno's service accounts via cluster role aggregation
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
KYVERNO_RBAC

  log "Persisting WIF state in ConfigMap '${OMNI_NAMESPACE}/${STATE_CM}'..."
  state_write_all

  cat <<EOF

==========================================================================
  WIF federation applied for edge cluster '${EDGE_CLUSTER}'.
    project-id:     ${PROJECT_ID}
    project-number: ${PROJECT_NUMBER}
    pool:           ${POOL_NAME}
    provider-url:   ${PROVIDER_URL}
    issuer:         ${ISSUER_URI}
    kyverno-managed: ${KYVERNO_MANAGED}

  Next: authorize a ServiceAccount, e.g.
    ./omni-wif.sh authorize -e ${EDGE_CLUSTER} <sa-namespace>/<sa-name>
==========================================================================
EOF
}

# ---------------------------------------------------------------------------
# AUTHORIZE
# ---------------------------------------------------------------------------
do_authorize() {
  require_tools
  state_load
  require_project_id

  log "Verifying provider still exists..."
  gcloud iam workload-identity-pools providers describe "$PROVIDER_NAME" \
    --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL_NAME" \
    >/dev/null 2>&1 || die "provider '${PROVIDER_NAME}' not found in pool '${POOL_NAME}'. Re-run apply."

  log "Checking namespace '${SA_NAMESPACE}' offloading in the main cluster..."
  assert_namespace_offloaded "$SA_NAMESPACE"

  log "Checking ServiceAccount '${SA_NAMESPACE}/${SA_NAME}' exists in the main cluster..."
  kubectl get serviceaccount "$SA_NAME" -n "$SA_NAMESPACE" >/dev/null 2>&1 \
    || die "ServiceAccount '${SA_NAMESPACE}/${SA_NAME}' not found in the main cluster (current context)."

  log "Resolving GSA from ServiceAccount annotation 'iam.gke.io/gcp-service-account'..."
  GSA_EMAIL="$(read_gsa_from_main_ksa "$SA_NAMESPACE" "$SA_NAME")"
  if [[ -z "$GSA_EMAIL" || "$GSA_EMAIL" != *@*.iam.gserviceaccount.com ]]; then
    die "ServiceAccount '${SA_NAMESPACE}/${SA_NAME}' does not have a valid 'iam.gke.io/gcp-service-account' annotation (got '${GSA_EMAIL}'). Expected '<gsa>@<project>.iam.gserviceaccount.com'. Direct IAM binding to a KSA is not supported; use GKE Workload Identity."
  fi
  GSA_PROJECT="${GSA_EMAIL##*@}"
  GSA_PROJECT="${GSA_PROJECT%.iam.gserviceaccount.com}"
  log "Resolved GSA: ${GSA_EMAIL}"

  fetch_edge_kubeconfig

  log "Verifying twin namespace '${SA_NAMESPACE}' exists on the edge cluster..."
  edge_kubectl get namespace "$SA_NAMESPACE" >/dev/null 2>&1 \
    || die "namespace '${SA_NAMESPACE}' does not exist on edge cluster '${EDGE_CLUSTER}' (is it offloaded yet?)"

  log "Ensuring ServiceAccount '${SA_NAME}' exists on the edge cluster..."
  edge_kubectl create serviceaccount "$SA_NAME" -n "$SA_NAMESPACE" \
    --dry-run=client -o yaml \
    | edge_kubectl apply -f -

  SA_CM="wif-sts-creds-${SA_NAME}"
  SA_POLICY="wif-auth-${SA_NAME}"

  log "Generating sts-creds.json for ${GSA_EMAIL}..."
  local sts_creds_file="/tmp/sts-creds-${EDGE_CLUSTER}-${SA_NAMESPACE}-${SA_NAME}.json"
  gcloud iam workload-identity-pools create-cred-config "$PROVIDER_URL" \
    --service-account="$GSA_EMAIL" \
    --credential-source-file="$TOKEN_PATH" \
    --output-file="$sts_creds_file"

  log "Applying ConfigMap '${SA_NAMESPACE}/${SA_CM}' on edge cluster..."
  edge_kubectl create configmap "$SA_CM" -n "$SA_NAMESPACE" \
    --from-file="${CRED_FILE}=${sts_creds_file}" \
    --dry-run=client -o yaml \
    | edge_kubectl apply -f -

  log "Applying Kyverno policy '${SA_NAMESPACE}/${SA_POLICY}' on edge cluster..."
  edge_kubectl apply -f - <<POLICY
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: ${SA_POLICY}
  namespace: ${SA_NAMESPACE}
spec:
  rules:
  - name: inject-wif-credentials
    match:
      any:
      - resources:
          kinds:
          - Pod
    context:
    - name: tokenSecret
      apiCall:
        urlPath: "/api/v1/namespaces/{{request.namespace}}/secrets/{{request.object.metadata.name}}-token"
    preconditions:
      all:
      - key: "{{ tokenSecret }}"
        operator: NotEquals
        value: ""
      - key: '{{ tokenSecret.metadata.labels."offloading.liqo.io/service-account-name" || "none" }}'
        operator: Equals
        value: "${SA_NAME}"
    mutate:
      patchStrategicMerge:
        spec:
          # Liqo rewrites serviceAccountName to "default"; restore the original SA
          # so the projected token subject matches the IAM principal.
          serviceAccountName: ${SA_NAME}
          containers:
          - (name): "*"
            env:
            - name: GOOGLE_APPLICATION_CREDENTIALS
              value: ${CRED_MOUNT}/${CRED_FILE}
            - name: CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE
              value: ${CRED_MOUNT}/${CRED_FILE}
            volumeMounts:
            - name: wif-auth-config
              mountPath: ${CRED_MOUNT}
              readOnly: true
            - name: wif-ksa-token
              mountPath: ${TOKEN_MOUNT_DIR}
              readOnly: true
          volumes:
          - name: wif-auth-config
            configMap:
              name: ${SA_CM}
          - name: wif-ksa-token
            projected:
              sources:
              - serviceAccountToken:
                  path: $(basename "$TOKEN_PATH")
                  expirationSeconds: 3600
                  audience: "https://iam.googleapis.com/${PROVIDER_URL}"
POLICY

  log "Granting edge KSA permission to impersonate ${GSA_EMAIL}..."
  local principal="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/subject/system:serviceaccount:${SA_NAMESPACE}:${SA_NAME}"
  gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" \
    --project="$GSA_PROJECT" \
    --role="roles/iam.workloadIdentityUser" \
    --member="$principal"
  wait_iam

  registry_add "${SA_NAMESPACE}/${SA_NAME}" "$GSA_EMAIL"
  state_write_all

  cat <<EOF

==========================================================================
  Authorized ${SA_NAMESPACE}/${SA_NAME} -> ${GSA_EMAIL} on edge '${EDGE_CLUSTER}'.

  Note: only pods created (or recreated) after this point are mutated.
  Restart existing pods so Omni can inject the credentials, e.g.:
    kubectl rollout restart deployment/<name> -n ${SA_NAMESPACE}

  Note: IAM bindings can take up to ~2 minutes to propagate. The first token
  acquisition in a pod may fail transiently with
  'iam.serviceAccounts.getAccessToken denied'; it succeeds once propagated.
==========================================================================
EOF
}

# ---------------------------------------------------------------------------
# DEAUTHORIZE
# ---------------------------------------------------------------------------
do_deauthorize() {
  require_tools
  state_load
  fetch_edge_kubeconfig

  GSA_EMAIL="$(registry_gsa "${SA_NAMESPACE}/${SA_NAME}")"
  if [[ -z "$GSA_EMAIL" ]]; then
    warn "'${SA_NAMESPACE}/${SA_NAME}' not in the authorization registry; attempting best-effort cleanup."
    GSA_EMAIL="$(read_gsa_from_main_ksa "$SA_NAMESPACE" "$SA_NAME" || true)"
  fi

  deauthorize_entry "$SA_NAMESPACE" "$SA_NAME" "$GSA_EMAIL"

  registry_remove "${SA_NAMESPACE}/${SA_NAME}"
  state_write_all

  log "Deauthorized ${SA_NAMESPACE}/${SA_NAME} on edge '${EDGE_CLUSTER}'."
}

# ---------------------------------------------------------------------------
# DESTROY
# ---------------------------------------------------------------------------
do_destroy() {
  require_tools
  fetch_edge_kubeconfig

  if state_cm_exists; then
    state_load

    if [[ -n "$REGISTRY" ]]; then
      log "Deauthorizing tracked ServiceAccounts for edge '${EDGE_CLUSTER}'..."
      local line ns_sa gsa
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        ns_sa="${line%% *}"
        gsa="${line#* }"
        [[ "$gsa" == "$line" ]] && gsa=""
        log "  - ${ns_sa}"
        deauthorize_entry "${ns_sa%%/*}" "${ns_sa##*/}" "$gsa"
      done <<< "$REGISTRY"
    else
      log "No authorized ServiceAccounts recorded."
    fi

    log "Deleting state ConfigMap '${OMNI_NAMESPACE}/${STATE_CM}'..."
    kubectl delete configmap "$STATE_CM" -n "$OMNI_NAMESPACE" --ignore-not-found=true
  else
    warn "No state ConfigMap '${OMNI_NAMESPACE}/${STATE_CM}' found; skipping per-SA cleanup and Kyverno uninstall."
    KYVERNO_MANAGED=""
  fi

  require_project_id

  if [[ "$KYVERNO_MANAGED" == "true" ]]; then
    log "Uninstalling Kyverno from edge cluster..."
    edge_kubectl delete -f "$KYVERNO_INSTALL_URL" --ignore-not-found=true || warn "Kyverno uninstall reported errors"
    log "Deleting Kyverno extra RBAC (ClusterRole '${KYVERNO_RBAC_NAME}')..."
    edge_kubectl delete clusterrole "$KYVERNO_RBAC_NAME" --ignore-not-found=true || warn "RBAC cleanup reported errors"
  elif [[ "$KYVERNO_MANAGED" == "false" ]]; then
    log "Kyverno was pre-existing; leaving it, but removing our RBAC."
    edge_kubectl delete clusterrole "$KYVERNO_RBAC_NAME" --ignore-not-found=true || true
  fi

  log "Deleting OIDC Provider '${PROVIDER_NAME}'..."
  gcloud iam workload-identity-pools providers delete "$PROVIDER_NAME" \
    --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL_NAME" \
    --quiet >/dev/null 2>&1 || warn "provider delete skipped (may not exist)"

  log "Deleting Workload Identity Pool '${POOL_NAME}'..."
  gcloud iam workload-identity-pools delete "$POOL_NAME" \
    --project="$PROJECT_ID" --location=global \
    --quiet >/dev/null 2>&1 || warn "pool delete skipped (may not exist)"

  log "Destroy complete for edge cluster '${EDGE_CLUSTER}'."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$MODE" in
  apply)       do_apply       ;;
  destroy)     do_destroy     ;;
  authorize)   do_authorize   ;;
  deauthorize) do_deauthorize ;;
esac
