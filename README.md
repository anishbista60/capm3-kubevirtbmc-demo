# CAPM3-kubevirtbmc-demo

**From Hosts to Clusters: Running Cluster API Provider Metal3 on KubeVirtBMC**

[Part 2](https://www.cncf.io/blog/2026/09/02/metal3-meets-kubevirtbmc-provisioning-kubevirt-vms-like-bare-metal/) of this series (demo: [`metal3-kubevirtbmc-demo`](https://github.com/anishbista60/metal3-kubevirtbmc-demo)) took a single KubeVirt VM through the Metal3 BareMetalHost lifecycle, from registering to provisioned. This demo goes one layer up. You declare a Kubernetes cluster with Cluster API, and [CAPM3](https://github.com/metal3-io/cluster-api-provider-metal3) picks hosts from a pool of KubeVirt "bare metal" servers, has Ironic write an OS image to them over Redfish virtual media, and runs kubeadm. After that you can scale, upgrade, fail over and remediate the cluster the same way you would on a real rack.

None of the components are patched. Metal3 only sees Redfish BMC addresses and boot MACs, and [KubeVirtBMC](https://github.com/kubevirtbmc/kubevirtbmc) is what turns each VM into a server with a BMC.

## Architecture

```
┌──────────────────────── kind node (management cluster) ────────────────────────────┐
│                                                                                       │
│   Cluster API + CAPM3 ──▶ Bare Metal Operator ──▶ Ironic (TLS) ──Redfish──┐          │
│        ▲                                              │ virtual media     ▼          │
│        │ Cluster / KCP / MachineDeployment            │ over HTTPS     KubeVirtBMC   │
│        │                                              ▼ (CDI import)   (one BMC per  │
│   you: kubectl apply                              ┌────────┐           VM, Redfish)  │
│                                                   │ cdrom  │              │ power,   │
│   image server (Ubuntu cloud image) ─────────────▶│  disk  │◀─────────────┘ boot,    │
│   10.96.200.200:8080                              └────────┘                media    │
│                                                                                       │
│   ┌─ VM kvbmc-node-0 ─┐  ┌─ VM kvbmc-node-1 ─┐  ┌─ VM kvbmc-node-2 ─┐                │
│   │ control plane     │  │ worker            │  │ (spare BMH)       │  ...           │
│   │ kube-vip ★        │  │                   │  │                   │                │
│   │ eth0: pod network │  │ eth0: pod network │  │ eth0: pod network │──▶ Ironic,     │
│   │ eth1: baremetal   │  │ eth1: baremetal   │  │ eth1: baremetal   │    images,     │
│   └────────┬──────────┘  └────────┬──────────┘  └────────┬──────────┘    internet    │
│            └──────── br-baremetal 192.168.100.0/24 (Multus, real L2) ─┘              │
│                       ★ API VIP 192.168.100.100 (kube-vip, ARP)                       │
│                       .1 = kind node → CAPI controllers reach the VIP                 │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

Each host has two networks:

- **eth0, the pod network.** It uses KubeVirt `bridge` binding, so every VM gets its own routable pod IP. Ironic, the image server, KubeVirtBMC and the internet are all reached through this network.
- **eth1, `baremetal-net`.** This is a Multus NIC on a real Linux bridge, and the kube-vip API VIP lives here. Kind's pod network has no L2 broadcast domain, so ARP-based VIPs can't work on it. A LoadBalancer Service would get around that, but real racks don't have one. A bridge behaves like a switch.

## Prerequisites

- **An x86_64 Linux host with KVM.** Nested virtualization works if `/dev/kvm` exists in the guest. The node images and IPA ramdisks are x86_64. Without `/dev/kvm` the scripts fall back to KubeVirt software emulation, which works but is very slow. Apple Silicon Macs are not supported.
- **Resources.** The default pool is 3 hosts (1 control plane, 1 worker, 1 spare) with 2 vCPU, 4 GiB RAM and a 30 GiB disk each. Plan for about **8 CPUs, 20 GiB RAM and 100 GiB disk**. The HA demo grows the pool to 5 hosts, which needs about **12 CPUs and 28 GiB RAM**.
- **Tools:** `kind`, `kubectl`, `clusterctl` (v1.14.x), `docker` and `curl`.
- **Outbound internet** from the host, because the VMs download packages and images.

Platform versions are pinned in [`versions.env`](versions.env) and can be overridden from the environment. Ironic, the node image, the workload Kubernetes versions and kube-vip are written directly into the manifests.

| Component | Version | Component | Version |
|---|---|---|---|
| KubeVirt | v1.9.0 | Cluster API | v1.14.3 |
| CDI | v1.66.1 | CAPM3 / IPAM | v1.14.1 |
| KubeVirtBMC | **v0.11.0** | Workload Kubernetes | v1.35.9 → v1.36.5 |
| IrSO / Ironic | v0.12.0 / 39.0 | kube-vip | v1.2.4 |
| Bare Metal Operator | v0.14.1 | Calico | v3.31.7 |
| Multus | v4.3.1 | Node OS | Ubuntu 24.04 cloud image |

## Usage

```bash
kind create cluster --config kind-config.yaml
./setup-platform.sh   # one-time: cert-manager, KubeVirt, CDI, Multus + baremetal-net,
                      #           CAPI + CAPM3, Ironic Standalone Operator, Ironic, BMO
./run-demo.sh         # core POC: host pool → workload cluster with Ready nodes
```

In a second terminal, start the dashboard. It's the view to record:

```bash
./watch.sh            # BareMetalHost → Metal3Machine → Machine → Node, live
```

Then run the lifecycle demos. Each one is independent and safe to re-run:

```bash
./demo-scale.sh out       # +1 worker: a free BMH is claimed, provisioned and joins
./demo-scale.sh in        # -1 worker: node drained, BMH cleaned, back to "available"
./demo-upgrade.sh         # rolling upgrade v1.35.9 → v1.36.5, new disks for every node
./demo-ha-failover.sh     # 3 control planes; pull the VIP holder's power via its BMC
./demo-remediation.sh     # stretch: MachineHealthCheck + Metal3Remediation reboot
```

Helpers:

```bash
./wl-kubectl.sh get pods -A     # kubectl against the workload cluster (via the VIP)
./collect-info.sh               # version matrix, footprint, timings → out/blog-facts.md
KEEP_HOSTS=true ./cleanup.sh    # delete the Cluster only: watch every BMH return to the pool
./cleanup.sh                    # delete cluster, hosts and demo resources (platform stays)
kind delete cluster --name capm3-kubevirtbmc   # everything
```

Useful knobs (see the top of [`lib.sh`](lib.sh)): `SPARE_HOSTS`, `VIRTUAL_MEDIA_TLS`, and `HOLD_SECONDS` for the failover demo. Everything else (cluster name, replica counts, host sizes, CIDRs, VIP) is plain YAML under [`manifests/`](manifests).

## What each step shows

### `run-demo.sh`: the core POC

1. **KubeVirtBMC v0.11.0**, plus the supporting pieces:
   - Ironic's CA as a ConfigMap
   - the BMC credentials
   - the node bootstrap script (`install-k8s` Secret)
   - Calico, delivered through a `ClusterResourceSet`
   - an in-cluster image server
2. **A host pool.** For each host the script creates a PVC, a VM (powered off, two NICs), a `VirtualMachineBMC` and a `BareMetalHost`. Every BMH goes `registering → inspecting → available`, with IPA booted over Redfish virtual media.
3. **The cluster.** The script applies these objects in [`manifests/cluster/`](manifests/cluster): `Cluster`, `Metal3Cluster` (endpoint = the VIP), `KubeadmControlPlane`, `MachineDeployment`, `Metal3MachineTemplate`s and `Metal3DataTemplate`s.
4. **The result.** BMHs go `available → provisioning → provisioned` with a consumer set. Machines reach `Running`. The workload cluster answers on `192.168.100.100:6443`, and `kubectl get nodes` shows Ready nodes named after their BareMetalHosts.

### Lifecycle (why CAPM3 matters)

- **Scale out and in** (`demo-scale.sh`). A Machine is a claim on a host. Scaling out takes a free BMH. Scaling in drains the node, deprovisions the host (Ironic wipes the disk metadata) and returns it to `available`.
- **Rolling upgrade** (`demo-upgrade.sh`). Hosts are never upgraded in place. The control plane uses `maxSurge: 1`: a spare host gets a fresh disk with the new version, joins, and then an old host is released. Workers use `maxSurge: 0`: release one, re-claim one. The new KubeadmConfigTemplate name carries the version, which is what triggers the MachineDeployment rollout.
- **Delete the cluster** (`KEEP_HOSTS=true ./cleanup.sh`). Every BMH goes back to the pool.

### Stretch

- **HA control plane and VIP failover** (`demo-ha-failover.sh`). The script scales the KCP to 3 and finds the kube-vip lease holder. It then powers that host off through its BMC with the `reboot.metal3.io/<key>` annotation in hard mode, so the path is BMO → Ironic → Redfish → KubeVirtBMC. A probe hits the API through the VIP every second and logs to `out/failover-probe.log`, so you can see how long the VIP took to move and that etcd kept quorum. Then the host is powered back on.
- **Remediation** (`demo-remediation.sh`). The script stops kubelet on a worker. After 60s of NotReady, the MachineHealthCheck asks CAPM3 for a `Metal3Remediation`. The `Reboot` strategy power-cycles the host through Redfish, and the node comes back with no replacement host needed.

## New since Part 2: HTTPS virtual media

Part 2 had to run Ironic with `disableVirtualMediaTLS: true`. Neither KubeVirtBMC's size probe nor CDI's importer trusted Ironic's self-signed CA, and the only workaround was to rebuild both images with the CA baked in.

[KubeVirtBMC v0.11.0](https://github.com/kubevirtbmc/kubevirtbmc/releases/tag/v0.11.0) (#293, tracking #280) adds `spec.redfish.virtualMedia.tls` to `VirtualMachineBMC`:

```yaml
spec:
  redfish:
    virtualMedia:
      tls:
        caBundleConfigMapRef:
          name: ironic-ca        # key "ca.pem"; also passed to CDI as certConfigMap
```

With that in place, this demo runs Ironic with TLS on both the API and virtual media ([`05-ironic-vmedia-tls.yaml`](manifests/platform/05-ironic-vmedia-tls.yaml)) and uses stock images. `VIRTUAL_MEDIA_TLS=false ./setup-platform.sh` switches back to the Part 2 configuration.

The same release added `bmc.kubevirt.io/datavolume-size-margin` (#300). This demo uses it in place of raising CDI's global filesystem overhead so the IPA ISO fits on local-path storage.

## Lessons learned

Most of the work in getting this running was networking. These are the points worth knowing:

1. **CAPI needs a stable control-plane endpoint, and kind can't provide one with ARP.** kindnet is a mesh of point-to-point veths with no broadcast domain, so a gratuitous ARP for a floating IP goes nowhere. The fix is a second NIC per VM on a Multus `bridge` network (`baremetal-net`), with kube-vip in ARP mode on it. That's also why kind runs as a **single node**: the bridge is local to one node, just as servers share one switch.
2. **Bring the second NIC up before `kubeadm init`.** cloud-init's fallback config only configures the first NIC. If kube-vip can't announce the VIP during init, kubeadm's own calls to the endpoint time out, and init fails or leaves the cluster half-bootstrapped (missing RBAC bindings) while the static pods look healthy. The KCP writes a netplan file and brings the link up in `preKubeadmCommands`.
3. **Find NICs by MAC, not by name.** q35 PCI slot ordering makes predictable interface names unpredictable across interfaces. baremetal-net MACs use the prefix `52:54:00:10:00:xx`, and the boot NIC uses `52:54:00:00:00:xx`.
4. **Use bridge binding, not masquerade.** With masquerade every VM gets `10.0.2.2`, and kubelet node IPs and Calico both need unique, routable addresses. Bridge binding needs two host fixes, which [`02-network-fixups.yaml`](manifests/platform/02-network-fixups.yaml) applies: `proxy_arp` on veths, and loose `rp_filter`, because replies to the VIP leave through eth0.
5. **Calico can pick the wrong NIC.** Pin `IP_AUTODETECTION_METHOD=cidr=<pod network>`. Also set `CALICO_IPV4POOL_CIDR`, because Calico's default `192.168.0.0/16` overlaps baremetal-net.
6. **Don't overlap service CIDRs.** The VMs' eth0 sits on the management pod network and resolves through its DNS, so the workload service CIDR is `10.128.0.0/12`.
7. **kube-vip and kubeadm ≥ 1.29.** During `kubeadm init`, kube-vip has to use `super-admin.conf` ([kube-vip#684](https://github.com/kube-vip/kube-vip/issues/684)). The control plane config only swaps the file on the init node, detected through `/run/kubeadm/kubeadm.yaml`, and swaps it back afterwards.
8. **Make Ironic's advertised URLs match its certificate.** Without host networking, IrSO advertises the pod IP, which isn't in the certificate. Setting `externalCallbackURL` and `imageServerExternalURL` to the Service FQDN fixes that.

## Layout

```
kind-config.yaml            single-node kind, pinned pod/service CIDRs
versions.env                every pinned version
lib.sh                      shared helpers (waits, host pool, workload kubectl)
setup-platform.sh           one-time platform install
run-demo.sh                 core POC
demo-*.sh                   lifecycle and stretch demos
watch.sh  wl-kubectl.sh  collect-info.sh  cleanup.sh
manifests/
  platform/   baremetal-net NAD, network fixups, Ironic certs/creds/CR, image server
  hosts/      BMC secret; kvbmc-node-<i>/ with vm.yaml (PVC + VM + VirtualMachineBMC) and bmh.yaml
  cluster/    Cluster + Metal3Cluster, control plane, workers (v1.35.9)
  upgrade/    control plane and workers at v1.36.5, for demo-upgrade.sh
  addons/     Calico ClusterResourceSet (+ kustomize patch)
  remediation/ MachineHealthCheck + Metal3RemediationTemplate
  scripts/    install-k8s.sh (node bootstrap, from the install-k8s Secret)
out/                        generated: kubeconfig, timings.tsv, blog-facts.md, probe logs
```

Every manifest is plain YAML that the scripts apply as-is with `kubectl apply -f`. The host pool has 6 hosts (`kvbmc-node-0` to `kvbmc-node-5`). To grow it, copy a host directory and change the name and the last byte of both MACs.

## Troubleshooting

| Symptom | Where to look |
|---|---|
| BMH stuck in `registering` | `kubectl get virtualmachinebmc`: is the condition `ServiceReady`? Check `kubectl logs -l app=virtbmc` and the BMC Service `<host>-virtbmc`. |
| BMH stuck in `inspecting` | `kubectl get dv`: did the IPA ISO import? Check `virtctl console <host>` and `kubectl -n baremetal-operator-system logs deploy/ironic-service`. |
| DataVolume `x509: certificate signed by unknown authority` | Check that `configmap/ironic-ca` exists in `default` and the VMBMC references it. Fallback: `VIRTUAL_MEDIA_TLS=false`. |
| DataVolume too small / out of space | Raise `bmc.kubevirt.io/datavolume-size-margin` in `manifests/hosts/kvbmc-node-*/vm.yaml`, or patch CDI `filesystemOverhead`. |
| BMH `provisioned` but no kubeconfig / API never answers | Log into the host (`virtctl console`) and check `/var/log/cloud-init-output.log`. Is the baremetal-net NIC up with an address? Is kube-vip running (`crictl ps`)? |
| Nodes Ready but pods can't reach each other | Calico autodetection: `./wl-kubectl.sh -n kube-system logs ds/calico-node \| grep -i autodetect`. |
| CAPI controllers can't reach the VIP | Is `ds/network-fixups` running? Does the kind node have 192.168.100.1 on `br-baremetal`? |

To get a shell on a host, use `virtctl console <host>`. The manifests don't add an SSH key; to use SSH, add a `users` entry with your public key to `kubeadmConfigSpec` in [`20-controlplane.yaml`](manifests/cluster/20-controlplane.yaml) and to the KubeadmConfigTemplate in [`30-workers.yaml`](manifests/cluster/30-workers.yaml) (and their copies in `manifests/upgrade/`).

## Credits

The networking design (baremetal-net, kube-vip in ARP mode, MAC-based NIC detection, the sysctl fixups, the Calico pinning and the node bootstrap script) comes from Lennart Jern's working experiment in [lentzi90/playground](https://github.com/lentzi90/playground/tree/main/Metal3) (Metal3 maintainer), adapted here to pinned releases, Metal3 v1beta2 APIs and KubeVirtBMC v0.11.0's HTTPS virtual media. The related upstream threads are [baremetal-operator#1736](https://github.com/metal3-io/baremetal-operator/issues/1736), [#3190](https://github.com/metal3-io/baremetal-operator/issues/3190) and [starbops/bare-metal-lab](https://github.com/starbops/bare-metal-lab).
