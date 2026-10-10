# Stretch demo: when a worker's node goes NotReady, CAPI's MachineHealthCheck
# marks the Machine unhealthy and asks CAPM3 for a Metal3Remediation. The
# "Reboot" strategy power-cycles the host through BMO -> Ironic -> Redfish ->
# KubeVirtBMC, i.e. it exercises the BMC's power actions on a live node.
# Only after retryLimit failed reboots does CAPI replace the Machine.
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachineHealthCheck
metadata:
  name: @@CLUSTER_NAME@@-workers
  namespace: @@NAMESPACE@@
spec:
  clusterName: @@CLUSTER_NAME@@
  selector:
    matchLabels:
      nodepool: workers
  checks:
    nodeStartupTimeoutSeconds: 0
    unhealthyNodeConditions:
    - type: Ready
      status: Unknown
      timeoutSeconds: 60
    - type: Ready
      status: "False"
      timeoutSeconds: 60
  remediation:
    triggerIf:
      unhealthyLessThanOrEqualTo: 100%
    templateRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
      kind: Metal3RemediationTemplate
      name: @@CLUSTER_NAME@@-workers
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: Metal3RemediationTemplate
metadata:
  name: @@CLUSTER_NAME@@-workers
  namespace: @@NAMESPACE@@
spec:
  template:
    spec:
      strategy:
        type: Reboot
        retryLimit: 1
        timeoutSeconds: 600
