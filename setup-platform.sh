#!/usr/bin/env bash
# One-time: installs the management-cluster platform on the kind cluster.
#   cert-manager, KubeVirt, CDI, Multus + baremetal-net, Cluster API + CAPM3,
#   Ironic Standalone Operator, Ironic, Bare Metal Operator
# Every step is idempotent; re-run after fixing a failure.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'on_error $LINENO' ERR

preflight() {
  section "Preflight"
  require_cmds kubectl clusterctl curl tar "$CONTAINER_RUNTIME"
  require_kind_context

  local arch; arch=$($CONTAINER_RUNTIME exec "$KIND_NODE" uname -m)
  [[ "$arch" == "x86_64" ]] \
    || die "kind node is $arch; the demo uses x86_64 node images and IPA ramdisks — run it on an x86_64 Linux host"

  if $CONTAINER_RUNTIME exec "$KIND_NODE" test -c /dev/kvm; then
    KVM=true; info "/dev/kvm available"
  else
    KVM=false
    warn "/dev/kvm not available — KubeVirt will use software emulation. Expect each host to take"
    warn "several times longer to inspect and provision; a full cluster may take well over an hour."
  fi

  local cc; cc=$(clusterctl version -o short 2>/dev/null || true)
  info "clusterctl $cc (providers pinned: CAPI $CAPI_VERSION, CAPM3 $CAPM3_VERSION)"
}

install_cert_manager() {
  stage_start "cert-manager $CERT_MANAGER_VERSION"
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=300s
  stage_end
}

install_kubevirt() {
  stage_start "KubeVirt $KUBEVIRT_VERSION"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
  # KubeVirtBMC hotplugs the virtual media volume into the VM's cdrom when
  # Ironic issues a Redfish InsertMedia call — that needs this feature gate.
  kubectl -n kubevirt patch kubevirt kubevirt --type merge -p "{
    \"spec\": {\"configuration\": {\"developerConfiguration\": {
      \"featureGates\": [\"DeclarativeHotplugVolumes\"],
      \"useEmulation\": $([[ "$KVM" == true ]] && echo false || echo true)
    }}}}"
  kubectl -n kubevirt wait --for=condition=Available kubevirt/kubevirt --timeout=600s
  stage_end
}

install_cdi() {
  stage_start "CDI $CDI_VERSION"
  kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
  kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"
  kubectl wait --for=condition=Available cdi/cdi --timeout=300s
  # kind's local-path StorageClass doesn't advertise CSI capabilities, so CDI
  # can't fill in the StorageProfile by itself. Without this, the DataVolume
  # KubeVirtBMC creates for virtual media fails with
  #   "no accessMode specified in StorageProfile <name>"
  local sc
  sc=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
  wait_until "StorageProfile/$sc" 120 "kubectl get storageprofile $sc"
  kubectl patch storageprofile "$sc" --type=merge \
    -p '{"spec":{"claimPropertySets":[{"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem"}]}}'
  stage_end
}

install_networking() {
  stage_start "Multus $MULTUS_VERSION + baremetal-net"
  # kind nodes only ship kindnet's CNI plugins; baremetal-net needs "bridge".
  if ! $CONTAINER_RUNTIME exec "$KIND_NODE" test -x /opt/cni/bin/bridge; then
    local tmp; tmp=$(mktemp -d)
    curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" \
      | tar -xz -C "$tmp" ./bridge
    $CONTAINER_RUNTIME cp "$tmp/bridge" "$KIND_NODE:/opt/cni/bin/bridge"
    rm -rf "$tmp"
    info "installed CNI bridge plugin $CNI_PLUGINS_VERSION on $KIND_NODE"
  fi
  # Upstream thick-plugin manifest, pinned to the release image.
  curl -fsSL "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml" \
    | sed "s#multus-cni:snapshot-thick#multus-cni:${MULTUS_VERSION}-thick#" \
    | kubectl apply -f -
  kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=300s
  kubectl apply -f "$MANIFESTS/platform/01-baremetal-net.yaml"
  kubectl apply -f "$MANIFESTS/platform/02-network-fixups.yaml"
  kubectl -n kube-system rollout status daemonset/network-fixups --timeout=120s
  stage_end
}

install_capi() {
  stage_start "Cluster API $CAPI_VERSION + CAPM3 $CAPM3_VERSION"
  if kubectl get deploy -n capm3-system capm3-controller-manager >/dev/null 2>&1; then
    info "CAPI/CAPM3 already installed, leaving as-is"
  else
    # cert-manager is already present, so clusterctl reuses it.
    clusterctl init \
      --core "cluster-api:${CAPI_VERSION}" \
      --bootstrap "kubeadm:${CAPI_VERSION}" \
      --control-plane "kubeadm:${CAPI_VERSION}" \
      --infrastructure "metal3:${CAPM3_VERSION}" \
      --ipam "metal3:${IPAM_VERSION}" \
      --wait-providers
  fi
  stage_end
}

install_ironic() {
  stage_start "Ironic Standalone Operator $IRSO_VERSION + Ironic"
  kubectl apply -f "https://github.com/metal3-io/ironic-standalone-operator/releases/download/${IRSO_VERSION}/install.yaml"
  kubectl -n ironic-standalone-operator-system wait --for=condition=Available \
    deploy/ironic-standalone-operator-controller-manager --timeout=300s

  kubectl create namespace baremetal-operator-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$MANIFESTS/platform/03-ironic-certs.yaml"
  kubectl apply -f "$MANIFESTS/platform/04-ironic-credentials.yaml"
  kubectl -n baremetal-operator-system wait --for=condition=Ready certificate/ironic-cert --timeout=120s

  local ironic_cr="$MANIFESTS/platform/05-ironic-vmedia-tls.yaml"
  [[ "$VIRTUAL_MEDIA_TLS" == "true" ]] || ironic_cr="$MANIFESTS/platform/05-ironic-vmedia-http.yaml"
  info "Ironic CR: $(basename "$ironic_cr")"
  # The IrSO webhook can take a moment to start answering after the deployment is Available.
  wait_until "Ironic CR accepted" 120 "kubectl apply -f '$ironic_cr'"
  kubectl -n baremetal-operator-system wait --for=condition=Ready ironic/ironic --timeout=600s
  stage_end
}

install_bmo() {
  stage_start "Bare Metal Operator $BMO_VERSION"
  kubectl apply -f "https://github.com/metal3-io/baremetal-operator/releases/download/${BMO_VERSION}/baremetal-operator.yaml"
  # Instead of an endpoint + CA file, point BMO at the Ironic CR — it reads the
  # URL, credentials and CA from it. Same as upstream's config/use-irso overlay.
  kubectl -n baremetal-operator-system create configmap ironic \
    --from-literal=IRONIC_NAME=ironic --dry-run=client -o yaml | kubectl replace -f -
  kubectl -n baremetal-operator-system rollout restart deploy/baremetal-operator-controller-manager
  kubectl -n baremetal-operator-system rollout status deploy/baremetal-operator-controller-manager --timeout=300s
  stage_end
}

summary() {
  section "Done"
  info "Platform installed: cert-manager, KubeVirt, CDI, Multus, CAPI, CAPM3, IrSO, Ironic, BMO"
  info "Virtual media TLS: $VIRTUAL_MEDIA_TLS"
  info "Next: ./run-demo.sh"
}

main() {
  preflight
  install_cert_manager
  install_kubevirt
  install_cdi
  install_networking
  install_capi
  install_ironic
  install_bmo
  summary
}

main "$@"
