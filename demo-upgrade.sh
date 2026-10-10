#!/usr/bin/env bash
# Lifecycle demo: rolling Kubernetes upgrade on "bare metal".
#
# Control plane first (maxSurge 1: a spare host is claimed and provisioned
# with the new version, joins, then an old host is drained, released and
# cleaned), then the workers (maxSurge 0: release one, re-claim one). No host
# is upgraded in place — every new version goes onto a freshly written disk,
# which is exactly how CAPM3 handles real servers.
#
#   ./demo-upgrade.sh [version]   default: K8S_UPGRADE_VERSION from versions.env
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_error $LINENO' ERR

require_kind_context
wl_sync_kubeconfig

target=${1:-$K8S_UPGRADE_VERSION}
from=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.version}')
cp=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.replicas}')
workers=$(kubectl -n "$NAMESPACE" get md "$CLUSTER_NAME-workers" -o jsonpath='{.spec.replicas}')
export SSH_PUBLIC_KEY; SSH_PUBLIC_KEY=$(ssh_public_key)

info "upgrading $CLUSTER_NAME from $from to $target ($cp control plane, $workers worker(s))"
wl get nodes

stage_start "Upgrade control plane to $target"
ensure_free_hosts 1        # surge host for the KubeadmControlPlane rollout
apply_cluster_part 20-controlplane.yaml.tpl "$target" "$cp" "$workers"
wait_until "KubeadmControlPlane $cp/$cp at $target" 5400 "kcp_settled $cp $target" kcp_status
stage_end

stage_start "Upgrade workers to $target"
apply_cluster_part 30-workers.yaml.tpl "$target" "$cp" "$workers"
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
