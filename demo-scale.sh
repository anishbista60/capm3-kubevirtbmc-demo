#!/usr/bin/env bash
# Lifecycle demo: scale the worker MachineDeployment.
#   ./demo-scale.sh out   +1 worker: CAPM3 claims a free BMH, Ironic provisions it, it joins
#   ./demo-scale.sh in    -1 worker: the node is drained, its BMH is cleaned and returns to the pool
#   ./demo-scale.sh <n>   scale to exactly n workers
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_error $LINENO' ERR

require_kind_context
wl_sync_kubeconfig

current=$(kubectl -n "$NAMESPACE" get md "$CLUSTER_NAME-workers" -o jsonpath='{.spec.replicas}')
version=$(kubectl -n "$NAMESPACE" get md "$CLUSTER_NAME-workers" -o jsonpath='{.spec.template.spec.version}')
cp=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.replicas}')
case "${1:-out}" in
  out) target=$(( current + 1 )) ;;
  in)  target=$(( current - 1 )) ;;
  *[!0-9]*) die "usage: $0 out|in|<replicas>" ;;
  *)   target=$1 ;;
esac
(( target >= 0 )) || die "can't scale below 0 workers"
(( target != current )) || { info "already at $current worker(s)"; exit 0; }

if (( target > current )); then
  stage_start "Scale out: workers $current -> $target"
  ensure_free_hosts $(( target - current ))
else
  stage_start "Scale in: workers $current -> $target"
fi
free_before=$(hosts_free)
kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL"
kubectl -n "$NAMESPACE" scale md "$CLUSTER_NAME-workers" --replicas="$target"

wait_until "MachineDeployment $target/$target ready" 3600 "md_settled $target $version" md_status
wait_until "$(( cp + target )) nodes in the workload cluster" 1800 \
  "[[ \$(wl get nodes --no-headers | wc -l | tr -d ' ') -eq $(( cp + target )) && \$(wl_ready_nodes) -eq $(( cp + target )) ]]" \
  "wl get nodes --no-headers | awk '{print \$1\"=\"\$2}'"
if (( target < current )); then
  # deprovisioning (Ironic wipes the disk metadata) -> available
  wait_until "released host(s) back in the pool" 1800 \
    "(( \$(hosts_free) >= $free_before + $(( current - target )) ))" bmh_summary
fi
stage_end

kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL"
echo
kubectl -n "$NAMESPACE" get machines
echo
wl get nodes -o wide
