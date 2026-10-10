#!/usr/bin/env bash
# Runs on every host as the first preKubeadmCommand: turns a stock Ubuntu
# cloud image into a kubeadm-ready node. Shipped to the hosts through the
# "install-k8s" Secret, which the KubeadmControlPlane and KubeadmConfigTemplate
# write to /usr/local/bin/install-k8s.sh.
#
# The Kubernetes version comes from /etc/capm3-demo/kubernetes-version, which
# the templates write from KubeadmControlPlane/MachineDeployment .version, so
# a rolling upgrade installs the new version on the new hosts.
#
# A pre-built node image (e.g. image-builder) would skip all of this; a stock
# image keeps the demo free of custom artifacts. Adapted from
# https://github.com/lentzi90/playground (setup-scripts/).
set -euxo pipefail

KUBERNETES_VERSION="$(cat /etc/capm3-demo/kubernetes-version)"
CRICTL_VERSION="${KUBERNETES_VERSION%.*}.0"   # cri-tools follows Kubernetes minors
CNI_PLUGINS_VERSION="v1.9.1"
RELEASE_VERSION="v0.18.0"                     # kubernetes/release: kubelet unit templates
ARCH="$(dpkg --print-architecture)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg containerd

curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" \
  | tar -C /usr/local/bin -xz

mkdir -p /opt/cni/bin
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
  | tar -C /opt/cni/bin -xz

cd /tmp
curl -fsSL --remote-name-all "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/{kubeadm,kubelet}"
install kubeadm kubelet /usr/bin/

mkdir -p /usr/lib/systemd/system/kubelet.service.d
curl -fsSL -o /usr/lib/systemd/system/kubelet.service \
  "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service"
curl -fsSL -o /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf \
  "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf"
systemctl daemon-reload
# Enabled so the node comes back by itself after a power cycle (remediation demo).
systemctl enable kubelet

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

swapoff -a
sed -i '/swap/d' /etc/fstab

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
