#!/usr/bin/env bash
# Tears the demo down in the order a real environment would:
#   1. delete the workload Cluster -> CAPM3 releases every host, Ironic
#      cleans them, and all BareMetalHosts go back to "available"
#   2. delete the host pool (BMH, VirtualMachineBMC, VM, disk)
#   3. delete KubeVirtBMC and the demo's supporting resources
# Everything installed by setup-platform.sh is left alone; to remove all of
# it: kind delete cluster --name capm3-kubevirtbmc
#
#   KEEP_HOSTS=true ./cleanup.sh   stop after step 1 (the "hosts return to the pool" demo)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_error $LINENO' ERR
: "${KEEP_HOSTS:=false}"

require_kind_context

if kubectl -n "$NAMESPACE" get cluster "$CLUSTER_NAME" >/dev/null 2>&1; then
  stage_start "Delete cluster $CLUSTER_NAME"
  kubectl -n "$NAMESPACE" delete mhc "$CLUSTER_NAME-workers" --ignore-not-found
  kubectl -n "$NAMESPACE" delete cluster "$CLUSTER_NAME" --wait=false
  wait_until "cluster $CLUSTER_NAME deleted" 1800 \
    "! kubectl -n $NAMESPACE get cluster $CLUSTER_NAME" bmh_summary
  wait_until "all hosts back in the pool" 1800 \
    "(( \$(hosts_free) == \$(hosts_total) ))" bmh_summary
  stage_end
  kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL"
fi
# Templates aren't owned by the Cluster.
kubectl -n "$NAMESPACE" delete kubeadmconfigtemplates,metal3machinetemplates,metal3datatemplates,metal3remediationtemplates \
  --all --ignore-not-found >/dev/null 2>&1 || true

if [[ "$KEEP_HOSTS" == "true" ]]; then
  info "KEEP_HOSTS=true: leaving the host pool in place"
  exit 0
fi

stage_start "Delete host pool"
kubectl -n "$NAMESPACE" delete bmh -l "$HOST_LABEL" --ignore-not-found --wait=true --timeout=900s
kubectl -n "$NAMESPACE" delete virtualmachinebmc,vm,pvc -l "$HOST_LABEL" --ignore-not-found --wait=true --timeout=300s
stage_end

section "Supporting resources"
kubectl delete -f "$MANIFESTS/addons/calico-crs.yaml" --ignore-not-found
kubectl -n "$NAMESPACE" delete configmap calico-cni ironic-ca --ignore-not-found
kubectl -n "$NAMESPACE" delete secret install-k8s --ignore-not-found
kubectl delete -f "$MANIFESTS/hosts/bmc-credentials.yaml" --ignore-not-found
kubectl -n "$NAMESPACE" delete deploy,svc image-server --ignore-not-found
kubectl delete -f "https://github.com/kubevirtbmc/kubevirtbmc/releases/download/${KUBEVIRTBMC_VERSION}/kubevirtbmc-install.yaml" --ignore-not-found

section "Done"
info "platform components (installed via setup-platform.sh) were left untouched"
info "the cached node image stays on the kind node in /var/lib/capm3-demo-images"
