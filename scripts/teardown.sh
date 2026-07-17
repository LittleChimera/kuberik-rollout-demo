#!/usr/bin/env bash
# Delete the kind cluster created by setup.sh.
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-kuberik-demo}"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> deleting kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "==> no kind cluster named '${CLUSTER_NAME}'"
fi
