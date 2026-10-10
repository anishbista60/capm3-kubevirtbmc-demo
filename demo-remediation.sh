#!/usr/bin/env bash
# Stretch demo: automatic remediation through the BMC.
#
# Installs a MachineHealthCheck + Metal3RemediationTemplate for the workers,
# then breaks a worker by stopping its kubelet. After the node has been
# NotReady for 60s, CAPI asks CAPM3 to remediate; CAPM3's "Reboot" strategy
# power-cycles the host through BMO -> Ironic -> Redfish -> KubeVirtBMC, the
# host boots again, kubelet starts and the node is Ready again — no human,
# no replacement host.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_error $LINENO' ERR

require_kind_context
wl_sync_kubeconfig

stage_start "MachineHealthCheck + Metal3RemediationTemplate"
export CLUSTER_NAME NAMESPACE
render "$MANIFESTS/remediation/worker-remediation.yaml.tpl" | kubectl apply -f -
kubectl -n "$NAMESPACE" get mhc
stage_end

node=$(wl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
[[ -n "$node" ]] || die "no worker node found"
bmh=$(node_to_bmh "$node")
section "Breaking worker $node (BareMetalHost $bmh): stopping kubelet"
wl debug "node/$node" -n default --image=busybox:1.36 --profile=sysadmin -- \
  chroot /host systemctl stop kubelet

stage_start "Remediation of $node"
wait_until "node $node NotReady" 300 \
  "wl get node $node --no-headers | awk '\$2 != \"Ready\"' | grep -q ." \
  "wl get node $node --no-headers | awk '{print \$2}'"
wait_until "Metal3Remediation created" 600 \
  "kubectl -n $NAMESPACE get metal3remediations -o name | grep -q ." \
  "kubectl -n $NAMESPACE get machines -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}'"
kubectl -n "$NAMESPACE" get metal3remediations
wait_until "node $node Ready again" 1800 \
  "wl get node $node --no-headers | awk '\$2 == \"Ready\"' | grep -q ." \
  "echo node=\$(wl get node $node --no-headers | awk '{print \$2}') poweredOn=\$(kubectl -n $NAMESPACE get bmh $bmh -o jsonpath='{.status.poweredOn}') remediation=\$(kubectl -n $NAMESPACE get metal3remediations -o jsonpath='{.items[*].status.phase}' 2>/dev/null)"
stage_end

wl -n default get pods -o name | grep node-debugger | while read -r p; do wl -n default delete "$p" --wait=false ; done || true
kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL"
kubectl -n "$NAMESPACE" get machines
wl get nodes
info "Events on $bmh:"
kubectl -n "$NAMESPACE" get events --field-selector "involvedObject.name=$bmh" --sort-by=.lastTimestamp | tail -15
