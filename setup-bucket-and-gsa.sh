#!/usr/bin/env bash
# setup-bucket-and-gsa.sh — demo data plane for the Omni WIF walkthrough:
# GCP service account (GSA), a GCS bucket it owns, a hello.txt object, and the IAM
# bindings. Skip this file if you already have a GSA + the resources it should reach.
#
# Usage: PROJECT_ID=<gcp-project> ./setup-bucket-and-gsa.sh
# Optional overrides: NS (default wif-demo), KSA (default wif-demo), GSA (default wif-demo),
#                     BUCKET (default <PROJECT_ID>-omni-wif-demo), REGION (default europe-west3)
set -euo pipefail

: "${PROJECT_ID:?export PROJECT_ID=<your-gcp-project-id>}"

NS="${NS:-wif-demo}"
KSA="${KSA:-wif-demo}"
GSA="${GSA:-wif-demo}"
GSA_EMAIL="${GSA}@${PROJECT_ID}.iam.gserviceaccount.com"
BUCKET="${BUCKET:-${PROJECT_ID}-omni-wif-demo}"
REGION="${REGION:-europe-west3}"

echo "--> creating GCP service account ${GSA_EMAIL}"
gcloud iam service-accounts create "$GSA" --project "$PROJECT_ID" \
  --display-name "Omni WIF demo" || echo "    (already exists)"

echo "--> creating bucket gs://${BUCKET} in ${REGION}"
gcloud storage buckets create "gs://${BUCKET}" --project "$PROJECT_ID" \
  --location "$REGION" --uniform-bucket-level-access || echo "    (already exists)"

echo "hello from GCS" | gcloud storage cp - "gs://${BUCKET}/hello.txt"

echo "--> granting ${GSA_EMAIL} objectAdmin on gs://${BUCKET}"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member "serviceAccount:${GSA_EMAIL}" \
  --role roles/storage.objectAdmin

# Legacy GKE Workload Identity binding: lets the *same-named* KSA impersonate the GSA
# when the workload runs on a regular GKE node pool. The edge-side impersonation is
# granted by `omni-wif.sh authorize` (WIF principal binding). Both may coexist.
echo "--> granting workloadIdentityUser on ${GSA_EMAIL} to ${NS}/${KSA} (main-cluster GKE identity)"
gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" --project "$PROJECT_ID" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NS}/${KSA}]" || true

echo "--> done. GSA_EMAIL=${GSA_EMAIL}  BUCKET=${BUCKET}"
