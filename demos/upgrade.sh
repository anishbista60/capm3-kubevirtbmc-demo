#!/usr/bin/env bash
# Lifecycle demo: rolling Kubernetes upgrade on "bare metal".
#
# Control plane first (maxSurge 1: a spare host is claimed and provisioned
# with the new version, joins, then an old host is drained, released and
# cleaned), then the workers (maxSurge 0: release one, re-claim one). No host
# is upgraded in place — every new version goes onto a freshly written disk,
# which is exactly how CAPM3 handles real servers.
#
# The target version is the one in manifests/upgrade/. Those files carry no
# replica counts, so the counts in effect are added when they are applied.
# Leaving them out is not safe: the cluster was created with a client-side
# apply, and the first server-side apply takes over those fields and drops
# whatever the new manifest doesn't set, which resets the control plane to 1.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
trap 'on_error $LINENO' ERR

require_kind_context
wl_sync_kubeconfig

target=$(sed -n 's/^  version: //p' "$MANIFESTS/upgrade/20-controlplane.yaml")
from=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.version}')
cp=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.replicas}')
workers=$(kubectl -n "$NAMESPACE" get md "$CLUSTER_NAME-workers" -o jsonpath='{.spec.replicas}')
[[ "$from" != "$target" ]] || { info "$CLUSTER_NAME is already at $target"; exit 0; }
upgrade_apply() { # upgrade_apply <file> <kind> <replicas>
  sed "/^kind: $2\$/,\$ s/^spec:\$/spec:\n  replicas: $3/" "$MANIFESTS/upgrade/$1" \
    | kubectl apply --server-side --force-conflicts --field-manager=demo-upgrade -f -
}

info "upgrading $CLUSTER_NAME from $from to $target ($cp control plane, $workers worker(s))"
wl get nodes

stage_start "Upgrade control plane to $target"
ensure_free_hosts 1        # surge host for the KubeadmControlPlane rollout
upgrade_apply 20-controlplane.yaml KubeadmControlPlane "$cp"
wait_until "KubeadmControlPlane $cp/$cp at $target" 5400 "kcp_settled $cp $target" kcp_status
stage_end

stage_start "Upgrade workers to $target"
upgrade_apply 30-workers.yaml MachineDeployment "$workers"
wait_until "MachineDeployment $workers/$workers at $target" 5400 "md_settled $workers $target" md_status
wait_until "all nodes Ready at $target" 1800 \
  "[[ \$(wl get nodes --no-headers | awk '\$2 == \"Ready\" && \$5 == \"$target\"' | wc -l | tr -d ' ') -eq $(( cp + workers )) ]]" \
  "wl get nodes --no-headers | awk '{print \$1\"=\"\$2\"/\"\$5}'"
stage_end

kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL"
echo
kubectl -n "$NAMESPACE" get machines
echo
wl get nodes -o wide
