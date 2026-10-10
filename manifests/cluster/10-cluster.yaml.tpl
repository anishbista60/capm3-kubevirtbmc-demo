# The workload cluster and its Metal3 infrastructure.
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: @@CLUSTER_NAME@@
  namespace: @@NAMESPACE@@
  labels:
    cni: calico            # selected by the Calico ClusterResourceSet
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - @@WORKLOAD_POD_CIDR@@
    services:
      cidrBlocks:
      # Must not overlap the management cluster's service CIDR: the VMs'
      # eth0 sits on the management pod network and uses its DNS/ClusterIPs.
      - @@WORKLOAD_SERVICE_CIDR@@
  infrastructureRef:
    apiGroup: infrastructure.cluster.x-k8s.io
    kind: Metal3Cluster
    name: @@CLUSTER_NAME@@
  controlPlaneRef:
    apiGroup: controlplane.cluster.x-k8s.io
    kind: KubeadmControlPlane
    name: @@CLUSTER_NAME@@
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: Metal3Cluster
metadata:
  name: @@CLUSTER_NAME@@
  namespace: @@NAMESPACE@@
spec:
  # The kube-vip VIP on baremetal-net, not a Service: it follows whichever
  # control-plane host holds the kube-vip lease, so it survives rolling
  # upgrades and host failures exactly as it would on a real rack.
  controlPlaneEndpoint:
    host: @@VIP@@
    port: 6443
  # No cloud provider: CAPM3 sets each node's providerID itself, matching
  # nodes to hosts through the metal3.io/uuid label set in the kubeadm config.
  cloudProviderEnabled: false
