#!/usr/bin/env bash
# Stretch demo: HA control plane and VIP failover.
#
# Scales the control plane to 3 (if needed), finds the host that holds the
# kube-vip lease — and therefore the API VIP — and pulls its power through
# the BMC: BMO -> Ironic -> Redfish -> KubeVirtBMC -> VM off. A probe hits
# the API through the VIP every second, so you can see the VIP move to
# another host and the API keep answering (etcd keeps quorum with 2 of 3).
# Then the host is powered back on and rejoins.
#
#   HOLD_SECONDS=90 ./demo-ha-failover.sh     how long the leader stays off (default 60)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_error $LINENO' ERR

: "${HOLD_SECONDS:=60}"
POWER_OFF_ANNOTATION="reboot.metal3.io/capm3-demo-failover"

require_kind_context
wl_sync_kubeconfig

version=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.version}')
cp=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.replicas}')
workers=$(kubectl -n "$NAMESPACE" get md "$CLUSTER_NAME-workers" -o jsonpath='{.spec.replicas}')

if (( cp < 3 )); then
  stage_start "Scale control plane $cp -> 3"
  ensure_free_hosts $(( 3 - cp ))
  kubectl -n "$NAMESPACE" scale kcp "$CLUSTER_NAME" --replicas=3
  wait_until "KubeadmControlPlane 3/3 ready" 5400 "kcp_settled 3 $version" kcp_status
  wait_until "$(( 3 + workers )) Ready nodes" 1800 "(( \$(wl_ready_nodes) >= $(( 3 + workers )) ))" \
    "wl get nodes --no-headers | awk '{print \$1\"=\"\$2}'"
  stage_end
fi

leader_node() { wl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'; }
leader=$(leader_node)
bmh=$(node_to_bmh "$leader")
[[ -n "$bmh" ]] || die "couldn't map kube-vip leader node '$leader' to a BareMetalHost"
section "kube-vip leader: node $leader on BareMetalHost $bmh"
wl get nodes -o wide

# API probe through the VIP, once a second, in the background.
probe_log="$OUT/failover-probe.log"; : > "$probe_log"
(
  while :; do
    if WL_TIMEOUT=1s wl get --raw=/readyz >/dev/null 2>&1; then r=ok; else r=FAIL; fi
    printf '%s %s %s\n' "$(date +%s)" "$(date +%T)" "$r" >> "$probe_log"
    sleep 1
  done
) &
probe_pid=$!
trap 'kill $probe_pid 2>/dev/null || true' EXIT
sleep 5

stage_start "Power off $bmh through its BMC"
t0=$(date +%s)
# Any reboot.metal3.io/<key> annotation keeps a host powered off until it is
# removed; "hard" skips the graceful OS shutdown — like pulling the plug.
kubectl -n "$NAMESPACE" annotate bmh "$bmh" --overwrite "$POWER_OFF_ANNOTATION={\"mode\":\"hard\"}"
wait_until "$bmh powered off" 300 \
  "[[ \$(kubectl -n $NAMESPACE get bmh $bmh -o jsonpath='{.status.poweredOn}') == false ]]"
wait_until "VIP to move off $leader" 300 \
  "n=\$(leader_node) && [[ -n \$n && \$n != $leader ]]" "echo holder=\$(leader_node)"
new_leader=$(leader_node)
info "VIP moved: $leader -> $new_leader, $(( $(date +%s) - t0 ))s after the power-off request"
stage_end

info "holding $bmh off for ${HOLD_SECONDS}s; the API keeps answering through the VIP:"
sleep "$HOLD_SECONDS"
wl get nodes
fails=$(grep -c FAIL "$probe_log" || true)
total=$(wc -l < "$probe_log" | tr -d ' ')
info "API probes through the VIP: $(( total - fails ))/$total ok, $fails failed"
grep FAIL "$probe_log" | awk 'NR==1{f=$2} {l=$2} END{ if (NR) print "    first failure " f ", last failure " l }'

stage_start "Power $bmh back on"
kubectl -n "$NAMESPACE" annotate bmh "$bmh" "$POWER_OFF_ANNOTATION-"
wait_until "node $leader Ready again" 1200 \
  "wl get node $leader --no-headers | awk '\$2 == \"Ready\"' | grep -q ." \
  "wl get node $leader --no-headers | awk '{print \$2}'"
stage_end

kill $probe_pid 2>/dev/null || true
wl get nodes -o wide
info "full probe log: $probe_log"
