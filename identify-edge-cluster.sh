#!/usr/bin/env bash
# identify-edge-cluster.sh — resolve the edge cluster name for an Omni edge location ID.
# WIF is configured per *edge cluster*; most customer-facing references use the edge
# location, so this resolves one from the other. Run with your main-cluster kubectl context.
#
# Usage: ./identify-edge-cluster.sh           (requires EDGE_LOCATION_ID)
#        EDGE_LOCATION_ID=<uuid> ./identify-edge-cluster.sh
set -euo pipefail

: "${EDGE_LOCATION_ID:?export EDGE_LOCATION_ID=<your-edge-location-uuid> (Omni console / castai omni CLI)}"

EDGE_CLUSTER_NAME=$(kubectl get edgeclusters -n castai-omni \
  -o custom-columns='NAME:.metadata.name,LOC:.spec.edgeLocation.id' \
  --no-headers | awk -v l="$EDGE_LOCATION_ID" '$2==l {print $1}')

[[ -n "$EDGE_CLUSTER_NAME" ]] || { echo "ERROR: no edge cluster found for edge location $EDGE_LOCATION_ID" >&2; exit 1; }

echo "EDGE_CLUSTER_NAME=$EDGE_CLUSTER_NAME"
echo "export EDGE_CLUSTER_NAME=$EDGE_CLUSTER_NAME"
