#!/usr/bin/env bash
# kubectl against the workload cluster, e.g. ./scripts/wl-kubectl.sh get nodes -o wide
# The API VIP is only reachable from inside the kind node, so this runs the
# kind node's kubectl with the kubeconfig CAPI generated.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
wl_sync_kubeconfig || die "no kubeconfig for $CLUSTER_NAME yet (Secret $CLUSTER_NAME-kubeconfig)"
WL_TIMEOUT=${WL_TIMEOUT:-30s} wl "$@"
