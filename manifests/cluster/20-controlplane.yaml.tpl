# Control plane: KubeadmControlPlane + which BareMetalHosts it gets and what
# is written to them. Re-applied by demo-upgrade.sh with a new version.
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: KubeadmControlPlane
metadata:
  name: @@CLUSTER_NAME@@
  namespace: @@NAMESPACE@@
spec:
  replicas: @@CP_TARGET_REPLICAS@@
  version: @@K8S_TARGET_VERSION@@
  machineTemplate:
    spec:
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: Metal3MachineTemplate
        name: @@CLUSTER_NAME@@-controlplane
  rollout:
    strategy:
      type: RollingUpdate
      rollingUpdate:
        maxSurge: 1        # an upgrade claims one spare host before releasing an old one
  kubeadmConfigSpec:
    files:
    - path: /usr/local/bin/install-k8s.sh
      owner: root:root
      permissions: "0755"
      contentFrom:
        secret:
          name: install-k8s
          key: install-k8s.sh
    - path: /etc/capm3-demo/kubernetes-version
      owner: root:root
      permissions: "0644"
      content: "@@K8S_TARGET_VERSION@@"
    # kube-vip static pod, ARP mode, announcing the API VIP on baremetal-net.
    # __VIP_IFACE__ is replaced at boot (preKubeadmCommands) with the NIC
    # whose MAC starts with 52:54:00:10 — interface names aren't predictable.
    - path: /etc/kubernetes/manifests/kube-vip.yaml
      owner: root:root
      permissions: "0644"
      content: |
        apiVersion: v1
        kind: Pod
        metadata:
          name: kube-vip
          namespace: kube-system
        spec:
          containers:
          - name: kube-vip
            image: ghcr.io/kube-vip/kube-vip:@@KUBE_VIP_VERSION@@
            imagePullPolicy: IfNotPresent
            args: ["manager"]
            env:
            - {name: vip_arp, value: "true"}
            - {name: port, value: "6443"}
            - {name: vip_interface, value: __VIP_IFACE__}
            - {name: vip_subnet, value: "32"}
            - {name: address, value: "@@VIP@@"}
            - {name: cp_enable, value: "true"}
            - {name: cp_namespace, value: kube-system}
            - {name: vip_leaderelection, value: "true"}
            - {name: vip_leasename, value: plndr-cp-lock}
            - {name: vip_leaseduration, value: "5"}
            - {name: vip_renewdeadline, value: "3"}
            - {name: vip_retryperiod, value: "1"}
            - name: vip_nodename
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            securityContext:
              capabilities:
                add: [NET_ADMIN, NET_RAW]
                drop: [ALL]
            volumeMounts:
            - name: kubeconfig
              mountPath: /etc/kubernetes/admin.conf
          hostAliases:
          - hostnames: [kubernetes]
            ip: 127.0.0.1
          hostNetwork: true
          volumes:
          - name: kubeconfig
            hostPath:
              path: /etc/kubernetes/admin.conf
    # cloud-init's fallback network config only brings up the first NIC.
    # baremetal-net must be up *before* kubeadm init: kubeadm talks to the
    # controlPlaneEndpoint (the VIP) during init, and if kube-vip can't
    # announce it, init fails or leaves the cluster half-bootstrapped
    # (e.g. missing RBAC bindings) while the static pods look healthy.
    - path: /etc/netplan/91-baremetal-net.yaml
      owner: root:root
      permissions: "0600"
      content: |
        network:
          version: 2
          ethernets:
            __BM_IFACE__:
              dhcp4: true
              dhcp4-overrides:
                use-routes: false
              optional: true
    preKubeadmCommands:
    - /usr/local/bin/install-k8s.sh
    - >-
      BM_IFACE=$(ip -o link show | grep -i "52:54:00:10:00" | awk -F': ' '{print $2}' | cut -d@ -f1) &&
      sed -i "s/__VIP_IFACE__/${BM_IFACE}/" /etc/kubernetes/manifests/kube-vip.yaml &&
      sed -i "s/__BM_IFACE__/${BM_IFACE}/" /etc/netplan/91-baremetal-net.yaml &&
      ip link set dev "${BM_IFACE}" up &&
      netplan apply &&
      for i in $(seq 1 30); do ip -o addr show dev "${BM_IFACE}" | grep -q "inet " && break; sleep 1; done
    # kubeadm init only creates super-admin.conf with full rights early on;
    # kube-vip needs it during init (https://github.com/kube-vip/kube-vip/issues/684).
    # /run/kubeadm/kubeadm.yaml only exists on the first (init) node.
    - "if [ -f /run/kubeadm/kubeadm.yaml ]; then sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/super-admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml; fi"
    postKubeadmCommands:
    - "if [ -f /run/kubeadm/kubeadm.yaml ]; then sed -i 's#path: /etc/kubernetes/super-admin.conf#path: /etc/kubernetes/admin.conf#' /etc/kubernetes/manifests/kube-vip.yaml; fi"
    initConfiguration:
      nodeRegistration:
        name: "{{ ds.meta_data.name }}"
        kubeletExtraArgs:
        - name: node-labels
          value: "metal3.io/uuid={{ ds.meta_data.uuid }}"
    joinConfiguration:
      controlPlane: {}
      nodeRegistration:
        name: "{{ ds.meta_data.name }}"
        kubeletExtraArgs:
        - name: node-labels
          value: "metal3.io/uuid={{ ds.meta_data.uuid }}"
    users:
    - name: ubuntu
      sudo: "ALL=(ALL) NOPASSWD:ALL"
      sshAuthorizedKeys:
      - "@@SSH_PUBLIC_KEY@@"
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: Metal3MachineTemplate
metadata:
  name: @@CLUSTER_NAME@@-controlplane
  namespace: @@NAMESPACE@@
spec:
  nodeReuse: false
  template:
    spec:
      # Wipe partition tables when a host is released, then back to the pool.
      automatedCleaningMode: metadata
      dataTemplate:
        name: @@CLUSTER_NAME@@-controlplane
      image:
        url: @@IMAGE_SERVER@@/node-image.img
        checksum: @@IMAGE_SERVER@@/node-image.img.sha256sum
        checksumType: sha256
        diskFormat: qcow2
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: Metal3DataTemplate
metadata:
  name: @@CLUSTER_NAME@@-controlplane
  namespace: @@NAMESPACE@@
spec:
  metaData:
    objectNames:
    - key: machine_name
      object: machine
    - key: metal3machine_name
      object: metal3machine
    - key: bmh_name
      object: baremetalhost
