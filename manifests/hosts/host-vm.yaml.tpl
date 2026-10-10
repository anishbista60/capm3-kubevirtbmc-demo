# One "bare metal server": a root disk, a KubeVirt VM and the
# VirtualMachineBMC that gives it a Redfish BMC. Rendered by lib.sh
# create_host for each index; placeholders are filled from the environment.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: @@HOST_NAME@@-rootdisk
  namespace: @@NAMESPACE@@
  labels:
    @@HOST_LABEL@@: "true"
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: @@HOST_DISK_SIZE@@
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: @@HOST_NAME@@
  namespace: @@NAMESPACE@@
  labels:
    @@HOST_LABEL@@: "true"
spec:
  # Powered off until Ironic turns it on through the BMC — like a racked server.
  runStrategy: Halted
  template:
    metadata:
      labels:
        kubevirt.io/domain: @@HOST_NAME@@
    spec:
      domain:
        cpu:
          cores: @@HOST_CPUS@@
        memory:
          guest: @@HOST_MEMORY@@
        machine:
          type: q35
        firmware:
          bootloader:
            efi:
              secureBoot: false
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          # Empty drive that KubeVirtBMC hotplugs the virtual media ISO into.
          - name: cdrom
            cdrom:
              bus: sata
          interfaces:
          # eth0: pod network. Bridge binding (not masquerade) so each VM has
          # its own routable IP — kubelet node IPs and Calico need that.
          - name: default
            macAddress: "@@HOST_BOOT_MAC@@"
            bridge: {}
          # Second NIC on baremetal-net, where the kube-vip VIP lives.
          - name: baremetal
            macAddress: "@@HOST_BM_MAC@@"
            bridge: {}
      networks:
      - name: default
        pod: {}
      - name: baremetal
        multus:
          networkName: baremetal-net
      volumes:
      - name: rootdisk
        persistentVolumeClaim:
          claimName: @@HOST_NAME@@-rootdisk
---
apiVersion: bmc.kubevirt.io/v1beta1
kind: VirtualMachineBMC
metadata:
  name: @@HOST_NAME@@-bmc
  namespace: @@NAMESPACE@@
  labels:
    @@HOST_LABEL@@: "true"
  annotations:
    # Pad the virtual media DataVolume so the ~500 MB IPA ISO still fits after
    # filesystem overhead on local-path storage (KubeVirtBMC >= v0.11.0).
    bmc.kubevirt.io/datavolume-size-margin: "15"
spec:
  virtualMachineRef:
    name: @@HOST_NAME@@
  authSecretRef:
    name: bmc-credentials
  redfish:
    virtualMedia:
      tls:
        # Trust Ironic's CA when fetching HTTPS virtual media
        # (KubeVirtBMC >= v0.11.0). Unused when virtual media is plain HTTP.
        caBundleConfigMapRef:
          name: ironic-ca
