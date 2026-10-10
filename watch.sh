#!/usr/bin/env bash
# Live dashboard for recordings: run it in a split pane next to the demo
# scripts. Shows the same hosts at every layer —
#   BareMetalHost (Metal3) -> Metal3Machine (CAPM3) -> Machine (CAPI) -> Node (workload cluster)
#   INTERVAL=2 ./watch.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
: "${INTERVAL:=3}"

while :; do
  wl_sync_kubeconfig >/dev/null 2>&1 || true
  frame=$(
    printf '%s%s %s — every %ss%s\n' "$BOLD" "$CLUSTER_NAME" "$(date +%T)" "$INTERVAL" "$RESET"
    printf '\n%sBareMetalHosts%s\n' "$CYAN" "$RESET"
    kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL" \
      -o custom-columns='NAME:.metadata.name,STATE:.status.provisioning.state,CONSUMER:.spec.consumerRef.name,ONLINE:.spec.online,POWERED:.status.poweredOn,ERROR:.status.errorType' 2>&1
    printf '\n%sMetal3Machines%s\n' "$CYAN" "$RESET"
    kubectl -n "$NAMESPACE" get metal3machines \
      -o custom-columns='NAME:.metadata.name,BAREMETALHOST:.metadata.annotations.metal3\.io/BareMetalHost,PROVIDER-ID:.spec.providerID' 2>&1
    printf '\n%sMachines%s\n' "$CYAN" "$RESET"
    kubectl -n "$NAMESPACE" get machines \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,VERSION:.spec.version,NODE:.status.nodeRef.name' 2>&1
    printf '\n%sControl plane / workers%s\n' "$CYAN" "$RESET"
    echo "KCP: $(kcp_status)"
    echo "MD:  $(md_status)"
    printf '\n%sWorkload nodes (via VIP %s)%s\n' "$CYAN" "$VIP" "$RESET"
    WL_TIMEOUT=2s wl get nodes -o wide 2>/dev/null | awk '{printf "%-24s %-9s %-15s %-9s %s\n", $1, $2, $3, $5, $6}' \
      || echo "(not reachable yet)"
  )
  clear
  echo "$frame"
  sleep "$INTERVAL"
done
