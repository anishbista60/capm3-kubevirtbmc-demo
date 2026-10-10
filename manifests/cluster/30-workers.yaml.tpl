# Workers: a MachineDeployment of BareMetalHosts. The KubeadmConfigTemplate
# name carries the Kubernetes version because bootstrap templates are treated
# as immutable — an upgrade creates a new one and points the MachineDeployment
# at it, which is what triggers the rollout.
apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
kind: KubeadmConfigTemplate
metadata:
  name: @@CLUSTER_NAME@@-workers-@@K8S_TARGET_SLUG@@
  namespace: @@NAMESPACE@@
spec:
  template:
    spec:
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
      preKubeadmCommands:
      - /usr/local/bin/install-k8s.sh
      joinConfiguration:
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
  name: @@CLUSTER_NAME@@-workers
  namespace: @@NAMESPACE@@
spec:
  nodeReuse: false
  template:
    spec:
      automatedCleaningMode: metadata
      dataTemplate:
        name: @@CLUSTER_NAME@@-workers
      image:
        url: @@IMAGE_SERVER@@/node-image.img
        checksum: @@IMAGE_SERVER@@/node-image.img.sha256sum
        checksumType: sha256
        diskFormat: qcow2
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: Metal3DataTemplate
metadata:
  name: @@CLUSTER_NAME@@-workers
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
---
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachineDeployment
metadata:
  name: @@CLUSTER_NAME@@-workers
  namespace: @@NAMESPACE@@
  labels:
    cluster.x-k8s.io/cluster-name: @@CLUSTER_NAME@@
    nodepool: workers
spec:
  clusterName: @@CLUSTER_NAME@@
  replicas: @@WORKER_TARGET_REPLICAS@@
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: @@CLUSTER_NAME@@
      nodepool: workers
  rollout:
    strategy:
      type: RollingUpdate
      rollingUpdate:
        # Replace in place: release one host, then claim one. Needs no spare.
        maxSurge: 0
        maxUnavailable: 1
  template:
    metadata:
      labels:
        cluster.x-k8s.io/cluster-name: @@CLUSTER_NAME@@
        nodepool: workers
    spec:
      clusterName: @@CLUSTER_NAME@@
      version: @@K8S_TARGET_VERSION@@
      bootstrap:
        configRef:
          apiGroup: bootstrap.cluster.x-k8s.io
          kind: KubeadmConfigTemplate
          name: @@CLUSTER_NAME@@-workers-@@K8S_TARGET_SLUG@@
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: Metal3MachineTemplate
        name: @@CLUSTER_NAME@@-workers
