#!/usr/bin/env bash
# setup-workload.sh — run the proof job: a pod offloaded to the Omni edge location
# reads and writes the GCS bucket *as the GSA*, with no keys exported.
#
# Usage: PROJECT_ID=<gcp-project> EDGE_LOCATION_NAME=<edge-location-name> ./setup-workload.sh
# Optional overrides: NS (default wif-demo), KSA (default wif-demo),
#                     BUCKET (default <PROJECT_ID>-omni-wif-demo)
set -euo pipefail

: "${PROJECT_ID:?export PROJECT_ID=<your-gcp-project-id>}"
: "${EDGE_LOCATION_NAME:?export EDGE_LOCATION_NAME=<your-edge-location-name> (the value your workloads use in nodeSelector)}"

NS="${NS:-wif-demo}"
KSA="${KSA:-wif-demo}"
BUCKET="${BUCKET:-${PROJECT_ID}-omni-wif-demo}"

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: wif-demo
  namespace: ${NS}
spec:
  backoffLimit: 2
  template:
    spec:
      serviceAccountName: ${KSA}
      restartPolicy: Never
      # Replace with whatever nodeSelector/tolerations you normally use to target
      # the Omni edge location's virtual node.
      nodeSelector:
        omni.cast.ai/edge-location-name: "${EDGE_LOCATION_NAME}"
      containers:
      - name: gcs
        image: google/cloud-sdk:slim
        env:
        - name: BUCKET
          value: ${BUCKET}
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          echo "GOOGLE_APPLICATION_CREDENTIALS=\$GOOGLE_APPLICATION_CREDENTIALS"
          for i in \$(seq 1 12); do
            gcloud storage ls gs://\$BUCKET && break
            echo "not authorized yet, retrying (\$i)..."; sleep 10
          done
          gcloud storage cat gs://\$BUCKET/hello.txt
          echo "written from omni pod \$(hostname) at \$(date)" \
            | gcloud storage cp - gs://\$BUCKET/from-omni-\$(hostname).txt
          echo "OK"
EOF

echo "--> watch:  kubectl logs -n ${NS} -l job-name=wif-demo -f"
echo "--> expect: bucket listing, hello.txt content, and 'OK' (file from-omni-<pod>.txt written back)"
