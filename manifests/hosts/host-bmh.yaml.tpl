# The BareMetalHost for one VM. Metal3 only sees a Redfish BMC address and a
# boot MAC — nothing in here says "virtual machine".
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: @@HOST_NAME@@
  namespace: @@NAMESPACE@@
  labels:
    @@HOST_LABEL@@: "true"
spec:
  online: true
  bootMode: UEFI
  bootMACAddress: "@@HOST_BOOT_MAC@@"
  bmc:
    address: redfish-virtualmedia+http://@@HOST_NAME@@-virtbmc.@@NAMESPACE@@.svc.cluster.local:80/redfish/v1/Systems/1
    credentialsName: bmc-credentials
  rootDeviceHints:
    deviceName: /dev/vda
