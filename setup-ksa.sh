#!/usr/bin/env bash
# setup-ksa.sh — prepare the namespace + Kubernetes service account on the MAIN cluster
# and authorize it for edge impersonation via omni-wif.sh.
#
# Usage: PROJECT_ID=<gcp-project> EDGE_CLUSTER_NAME=<edgecluster> ./setup-ksa.sh
# Optional overrides: NS (default wif-demo), KSA (default wif-demo), GSA (default wif-demo)
set -euo pipefail

cd "$(dirname "$0")"

: "${PROJECT_ID:?export PROJECT_ID=<your-gcp-project-id>}"
: "${EDGE_CLUSTER_NAME:?export EDGE_CLUSTER_NAME=<edge-cluster-name> (see identify-edge-cluster.sh)}"

NS="${NS:-wif-demo}"
KSA="${KSA:-wif-demo}"
GSA="${GSA:-wif-demo}"
GSA_EMAIL="${GSA}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "--> creating namespace ${NS} (if missing) and enabling Omni offloading"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" omni.cast.ai/enable-scheduling=true --overwrite

echo "--> creating KSA ${NS}/${KSA} annotated to GSA ${GSA_EMAIL}"
kubectl create serviceaccount "$KSA" -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount "$KSA" -n "$NS" \
  iam.gke.io/gcp-service-account="$GSA_EMAIL" --overwrite

echo "--> authorizing ${NS}/${KSA} for edge impersonation"
./omni-wif.sh authorize -e "$EDGE_CLUSTER_NAME" "${NS}/${KSA}"

echo "--> done. Any pod offloaded to edge cluster ${EDGE_CLUSTER_NAME} with"
echo "    serviceAccountName: ${KSA} now gets GCP credentials for ${GSA_EMAIL}."
echo "    NOTE: recreate already-running pods to pick up the mutation; IAM may take ~2 min."
