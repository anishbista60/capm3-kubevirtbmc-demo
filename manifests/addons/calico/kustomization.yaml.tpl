# Upstream Calico, plus two settings this lab needs. run-demo.sh downloads
# calico.yaml (CALICO_VERSION) next to the rendered copy of this file.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- calico.yaml
patches:
- target:
    kind: DaemonSet
    name: calico-node
  patch: |-
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: calico-node
    spec:
      template:
        spec:
          containers:
          - name: calico-node
            env:
            # Control-plane nodes have two NICs (pod network + baremetal-net).
            # Calico's default autodetection sometimes picks baremetal-net,
            # which breaks cross-node pod traffic; pin it to the pod network.
            - name: IP_AUTODETECTION_METHOD
              value: cidr=@@MGMT_POD_CIDR@@
            # Calico's default pool is 192.168.0.0/16, which would overlap
            # baremetal-net (192.168.100.0/24). Use the cluster's pod CIDR.
            - name: CALICO_IPV4POOL_CIDR
              value: "@@WORKLOAD_POD_CIDR@@"
