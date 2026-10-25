#!/usr/bin/env bash
# Collects what the blog post needs into out/blog-facts.md: the version matrix
# actually running, resource footprint and stage timings.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

img() { kubectl -n "$1" get deploy "$2" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "-"; }
wl_sync_kubeconfig >/dev/null 2>&1 || true

{
  echo "# CAPM3 + KubeVirtBMC demo — facts ($(date -u +%F))"
  echo
  echo "## Version matrix"
  echo
  echo "| Component | Version |"
  echo "|---|---|"
  echo "| kind node (management) | $(kubectl get node "$KIND_NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}') |"
  echo "| cert-manager | $(img cert-manager cert-manager) |"
  echo "| KubeVirt | $(kubectl -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.observedKubeVirtVersion}') |"
  echo "| CDI | $(kubectl get cdi cdi -o jsonpath='{.status.observedVersion}') |"
  echo "| Multus | $(kubectl -n kube-system get ds kube-multus-ds -o jsonpath='{.spec.template.spec.containers[0].image}') |"
  echo "| KubeVirtBMC | $(img kubevirtbmc-system kubevirtbmc-controller-manager) |"
  echo "| Ironic Standalone Operator | $(img ironic-standalone-operator-system ironic-standalone-operator-controller-manager) |"
  echo "| Ironic | $(kubectl -n baremetal-operator-system get ironic ironic -o jsonpath='{.status.installedVersion}') |"
  echo "| Bare Metal Operator | $(img baremetal-operator-system baremetal-operator-controller-manager) |"
  echo "| Cluster API | $(img capi-system capi-controller-manager) |"
  echo "| CAPM3 | $(img capm3-system capm3-controller-manager) |"
  echo "| Metal3 IPAM | $(img metal3-ipam-system ipam-controller-manager) |"
  echo "| Workload Kubernetes | $(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.version}' 2>/dev/null) |"
  echo "| kube-vip | $(WL_TIMEOUT=5s wl -n kube-system get pods -o jsonpath='{.items[?(@.spec.containers[0].name=="kube-vip")].spec.containers[0].image}' 2>/dev/null | awk '{print $1}') |"
  echo "| Calico | $CALICO_VERSION |"
  echo "| Node OS image | $(kubectl -n "$NAMESPACE" get deploy image-server -o jsonpath='{.spec.template.spec.initContainers[0].env[?(@.name=="IMAGE_URL")].value}' 2>/dev/null) |"
  echo "| Virtual media TLS | $VIRTUAL_MEDIA_TLS |"
  echo
  echo "## Footprint"
  echo
  echo "- Host: $(nproc 2>/dev/null || sysctl -n hw.ncpu) CPUs; kind node allocatable: $(kubectl get node "$KIND_NODE" -o jsonpath='{.status.allocatable.cpu} CPU, {.status.allocatable.memory}')"
  echo "- Hosts (VMs) in the pool: $(hosts_total), each $(kubectl -n "$NAMESPACE" get vm "$(host_name 0)" -o jsonpath='{.spec.template.spec.domain.cpu.cores} vCPU / {.spec.template.spec.domain.memory.guest}' 2>/dev/null) / $(kubectl -n "$NAMESPACE" get pvc "$(host_name 0)-rootdisk" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null) disk"
  echo "- /dev/kvm on the kind node: $($CONTAINER_RUNTIME exec "$KIND_NODE" test -c /dev/kvm && echo yes || echo 'no (emulation)')"
  echo
  echo "## Stage timings"
  echo
  echo "| When (UTC) | Stage | Duration |"
  echo "|---|---|---|"
  [[ -f "$OUT/timings.tsv" ]] && awk -F'\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }' "$OUT/timings.tsv"
  echo
  echo "## Current state"
  echo
  echo '```'
  kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL" 2>&1
  echo
  kubectl -n "$NAMESPACE" get machines 2>&1
  echo
  WL_TIMEOUT=5s wl get nodes -o wide 2>&1
  echo '```'
} > "$OUT/blog-facts.md"

cat "$OUT/blog-facts.md"
info "written to $OUT/blog-facts.md"
