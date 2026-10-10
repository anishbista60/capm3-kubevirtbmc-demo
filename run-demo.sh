#!/usr/bin/env bash
# Core POC: a CAPI workload cluster built on KubeVirt "bare metal".
#
#   1. KubeVirtBMC + supporting bits (CA bundle, BMC secret, image server,
#      node install script, Calico ClusterResourceSet)
#   2. A pool of hosts: VM + VirtualMachineBMC + BareMetalHost, all inspected
#      and "available"
#   3. Cluster / Metal3Cluster / KubeadmControlPlane / MachineDeployment ...
#   4. Wait until CAPM3 has claimed hosts, Ironic has written the image and
#      kubeadm has formed a cluster with Ready nodes
#
# Run ./watch.sh in a second terminal to see BMH -> Metal3Machine -> Machine
# -> Node move together.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_error $LINENO' ERR

NUM_HOSTS=$(( CP_REPLICAS + WORKER_REPLICAS + SPARE_HOSTS ))

preflight() {
  section "Preflight"
  require_cmds kubectl clusterctl curl perl ssh-keygen base64 "$CONTAINER_RUNTIME"
  require_kind_context
  kubectl -n baremetal-operator-system get ironic ironic >/dev/null 2>&1 \
    || die "Ironic not found — run ./setup-platform.sh first"
  info "cluster $CLUSTER_NAME: $CP_REPLICAS control plane + $WORKER_REPLICAS worker(s), $NUM_HOSTS hosts in the pool"
}

install_kubevirtbmc() {
  stage_start "KubeVirtBMC $KUBEVIRTBMC_VERSION"
  kubectl apply -f "https://github.com/kubevirtbmc/kubevirtbmc/releases/download/${KUBEVIRTBMC_VERSION}/kubevirtbmc-install.yaml"
  kubectl -n kubevirtbmc-system rollout status deploy/kubevirtbmc-controller-manager --timeout=180s
  stage_end
}

prepare_supporting_resources() {
  stage_start "Supporting resources"
  # Ironic's CA, under the key KubeVirtBMC expects ("ca.pem"), for
  # VirtualMachineBMC.spec.redfish.virtualMedia.tls.caBundleConfigMapRef.
  kubectl -n baremetal-operator-system get secret ironic-cacert -o jsonpath='{.data.tls\.crt}' \
    | base64 -d > "$OUT/ironic-ca.pem"
  kubectl -n "$NAMESPACE" create configmap ironic-ca --from-file=ca.pem="$OUT/ironic-ca.pem" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$MANIFESTS/hosts/bmc-credentials.yaml"

  # Node bootstrap script, referenced by the KubeadmControlPlane and KubeadmConfigTemplate.
  kubectl -n "$NAMESPACE" create secret generic install-k8s \
    --from-file=install-k8s.sh="$MANIFESTS/scripts/install-k8s.sh" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Calico for the workload cluster, delivered by a ClusterResourceSet.
  local tmp; tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/calico.yaml" "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  export MGMT_POD_CIDR WORKLOAD_POD_CIDR
  render "$MANIFESTS/addons/calico/kustomization.yaml.tpl" > "$tmp/kustomization.yaml"
  kubectl kustomize "$tmp" > "$OUT/calico.yaml"
  rm -rf "$tmp"
  # Server-side apply: the ~300 KB manifest doesn't fit in the
  # last-applied-configuration annotation of a client-side apply.
  kubectl -n "$NAMESPACE" create configmap calico-cni --from-file=calico.yaml="$OUT/calico.yaml" \
    --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f -
  kubectl apply -f "$MANIFESTS/addons/calico-crs.yaml"
  stage_end

  stage_start "Image server (downloads the Ubuntu cloud image once)"
  export UBUNTU_IMAGE_URL
  render "$MANIFESTS/platform/06-image-server.yaml" | kubectl apply -f -
  kubectl -n "$NAMESPACE" rollout status deploy/image-server --timeout=1200s
  stage_end
}

create_host_pool() {
  stage_start "Host pool: $NUM_HOSTS × (VM + VirtualMachineBMC + BareMetalHost)"
  ensure_hosts "$NUM_HOSTS"
  kubectl -n "$NAMESPACE" get vm,virtualmachinebmc -l "$HOST_LABEL"
  # Each host: registering -> inspecting (IPA boots from Redfish virtual
  # media, reports hardware) -> available.
  wait_until "all $NUM_HOSTS BareMetalHosts available" 2400 \
    "(( \$(hosts_free) + \$(bmh_table | awk '\$3 != \"-\"' | wc -l) >= $NUM_HOSTS ))" bmh_summary
  kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL"
  stage_end
}

create_cluster() {
  stage_start "Workload cluster $CLUSTER_NAME"
  if kubectl -n "$NAMESPACE" get cluster "$CLUSTER_NAME" >/dev/null 2>&1; then
    # Re-applying would reset replicas/version changed by the lifecycle demos.
    info "cluster $CLUSTER_NAME already exists, not re-applying templates"
  else
    export SSH_PUBLIC_KEY; SSH_PUBLIC_KEY=$(ssh_public_key)
    apply_cluster_part 10-cluster.yaml.tpl      "$K8S_VERSION" "$CP_REPLICAS" "$WORKER_REPLICAS"
    apply_cluster_part 20-controlplane.yaml.tpl "$K8S_VERSION" "$CP_REPLICAS" "$WORKER_REPLICAS"
    apply_cluster_part 30-workers.yaml.tpl      "$K8S_VERSION" "$CP_REPLICAS" "$WORKER_REPLICAS"
  fi
  local version; version=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.version}')
  local cp; cp=$(kubectl -n "$NAMESPACE" get kcp "$CLUSTER_NAME" -o jsonpath='{.spec.replicas}')
  local workers; workers=$(kubectl -n "$NAMESPACE" get md "$CLUSTER_NAME-workers" -o jsonpath='{.spec.replicas}')

  # BMH: available -> provisioning (Ironic writes the image) -> provisioned,
  # then the host boots, cloud-init runs install-k8s.sh and kubeadm init.
  wait_until "first control plane host provisioned" 2400 \
    "kubectl -n $NAMESPACE get bmh -l $HOST_LABEL -o jsonpath='{.items[*].status.provisioning.state}' | grep -qw provisioned" \
    bmh_summary
  wait_until "workload kubeconfig" 1800 wl_sync_kubeconfig
  wait_until "workload API answering on the VIP ($VIP:6443)" 1800 "wl get --raw=/readyz"
  stage_end

  stage_start "Control plane ($cp) and workers ($workers) Ready"
  wait_until "KubeadmControlPlane $cp/$cp ready" 3600 "kcp_settled $cp $version" kcp_status
  wait_until "MachineDeployment $workers/$workers ready" 3600 "md_settled $workers $version" md_status
  wait_until "$(( cp + workers )) Ready nodes" 1800 "(( \$(wl_ready_nodes) >= $(( cp + workers )) ))" \
    "wl get nodes --no-headers | awk '{print \$1\"=\"\$2}'"
  stage_end
}

summary() {
  section "Result"
  kubectl -n "$NAMESPACE" get bmh -l "$HOST_LABEL"
  echo
  kubectl -n "$NAMESPACE" get metal3machines,machines
  echo
  clusterctl describe cluster "$CLUSTER_NAME" -n "$NAMESPACE" || true
  echo
  info "Workload cluster nodes (via the kube-vip VIP $VIP):"
  wl get nodes -o wide
  echo
  info "Talk to the workload cluster with:   ./wl-kubectl.sh get pods -A"
  info "Lifecycle demos:                     ./demo-scale.sh out | in"
  echo  "                                       ./demo-upgrade.sh"
  echo  "                                       ./demo-ha-failover.sh"
  echo  "                                       ./demo-remediation.sh   (stretch)"
  info "Stage timings so far: $OUT/timings.tsv"
}

main() {
  preflight
  install_kubevirtbmc
  prepare_supporting_resources
  create_host_pool
  create_cluster
  summary
}

main "$@"
