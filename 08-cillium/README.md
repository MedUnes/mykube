# 8- Cilium Bootstrap

## What is Cilium?

Cilium is the CNI (Container Network Interface) for our cluster. But calling it "just a CNI" undersells it
significantly. Cilium uses **eBPF**: a technology that allows programs to run sandboxed inside the Linux kernel without
modifying kernel source: to implement networking, security, and observability at the lowest possible level.

In our cluster, Cilium is doing three jobs simultaneously:

```
1. CNI                   : assigns pod IPs, sets up pod-to-pod networking
2. kube-proxy replacement: handles Service ClusterIP/NodePort via eBPF
3. Network policy        : enforces firewall rules between pods
```

---

## Why Cilium Instead of kube-proxy + flannel/calico?

The traditional stack is flannel or calico for pod networking and kube-proxy for service routing. kube-proxy maintains
iptables rules on every node. At scale this is a serious problem:

- Thousands of iptables rules evaluated linearly for every packet
- Every Service change triggers a full iptables rewrite on every node
- Rules are stateful and painful to debug

Cilium's eBPF approach bypasses iptables entirely. Rules are compiled directly into the kernel and evaluated in O(1).
The result is lower latency, higher throughput, and dramatically better observability.

For a self-hosted cluster built to understand what happens under the hood, Cilium is the right choice: it is also what
major cloud providers use for their managed Kubernetes offerings internally.

---

## Why We Never Generated a kube-proxy Certificate

In the PKI step we deliberately skipped the `kube-proxy.pem` certificate. There is no kube-proxy process running
anywhere in the cluster. Cilium's eBPF programs handle all Service IP routing directly in the kernel: kube-proxy is
completely absent.

---

## Installation Method: cilium CLI

Three methods exist: Helm, cilium CLI, and raw manifests. We chose **cilium CLI** because:

- Single command install with sensible defaults
- Auto-detects cluster configuration (cluster name, kube-proxy status: it correctly identified kube-proxy was not
  installed)
- Built-in `cilium status` and `cilium connectivity test` for verification
- Wraps Helm under the hood: all deployed resources are inspectable via `kubectl`

---

## Script: `bootstrap-cilium.sh`

Runs on the VPS host, executes remotely on control-plane-1 via SSH. Flow:

```
1. SSH: install cilium CLI binary
2. SSH: cilium install with our cluster parameters
3. SSH: cilium status --wait (waits up to 3 minutes)
4. SSH: kubectl get nodes + kubectl get pods -n kube-system
5. SSH: cilium connectivity test
```

---

## Key Installation Parameters Explained

| Parameter                                  | Value           | Reason                                                                                                                                                           |
|--------------------------------------------|-----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `kubeProxyReplacement`                     | `true`          | Full eBPF replacement: no iptables, no kube-proxy process anywhere                                                                                               |
| `k8sServiceHost`                           | `10.0.0.4`      | When kube-proxy is fully replaced, Cilium itself bootstraps its connection to the apiserver directly. Without this, Cilium cannot reach the apiserver on startup |
| `k8sServicePort`                           | `6443`          | Apiserver port                                                                                                                                                   |
| `ipam.mode`                                | `cluster-pool`  | Cilium manages IP allocation from a central pool, carving per-node subnets automatically                                                                         |
| `ipam.operator.clusterPoolIPv4PodCIDRList` | `10.200.0.0/16` | Must match `--cluster-cidr` in kube-controller-manager exactly: both must agree on the same pod IP space                                                         |
| `ipam.operator.clusterPoolIPv4MaskSize`    | `24`            | Each node gets a `/24` carved from the pool: `worker-node-1` gets `10.200.0.0/24`, `worker-node-2` gets `10.200.1.0/24`. 254 pod IPs per node                    |

---

## What Cilium Deploys into the Cluster

Cilium installs itself as Kubernetes workloads: the first real pods in our cluster:

| Workload          | Type       | What it does                                                                                                             |
|-------------------|------------|--------------------------------------------------------------------------------------------------------------------------|
| `cilium`          | DaemonSet  | One pod per node: the eBPF datapath agent. Loads eBPF programs into the kernel, manages pod IPs, handles Service routing |
| `cilium-envoy`    | DaemonSet  | One pod per node: handles L7 (HTTP/gRPC-aware) network policy and observability                                          |
| `cilium-operator` | Deployment | One pod: cluster-wide coordination, IPAM management, node CIDR allocation                                                |

---

## The RBAC Lesson: Why Admin Kubeconfig Matters

The first install attempt failed with:

```
User "system:kube-controller-manager" cannot get resource "clusterroles"
in API group "rbac.authorization.k8s.io" at the cluster scope
```

The `~/.kube/config` on control-plane-1 was initially set to the `kube-controller-manager` kubeconfig: a scoped identity
with restricted RBAC. Cilium needs to create `ClusterRole`, `ClusterRoleBinding`, and `CustomResourceDefinition`
resources: all requiring cluster-admin.

The fix: use `admin.kubeconfig` instead: `CN=admin`, `O=system:masters`, full cluster-admin. But the admin kubeconfig
points to `127.0.0.1:6443` (the SSH tunnel address for external kubectl access). On the control plane itself, the tunnel
isn't active, so we patch the address:

```bash
sed 's|https://127.0.0.1:6443|https://10.0.0.4:6443|g' \
  admin.kubeconfig > admin-internal.kubeconfig
```

This fix is now baked permanently into `bootstrap-workers.sh`: the admin-internal kubeconfig is generated and installed
on every fresh provision automatically. This issue will never occur again.

---

## The DNS Errors in cilium status

After installation, `cilium status` reported:

```
dial tcp: lookup worker-node-2 on 127.0.0.53:53: server misbehaving
```

This is **not a Cilium networking failure**. The cilium CLI queries worker nodes by **hostname** to retrieve detailed
per-agent status. The control plane cannot resolve `worker-node-1` or `worker-node-2` as hostnames because CoreDNS was
not installed yet: that is the next step.

Proof that networking was working correctly despite the error: both nodes showed `Ready`, all Cilium pods showed
`Running 1/1`, and pods received IPs from the `10.200.x.x` range immediately.

The errors disappeared after CoreDNS was installed.

---

## The `cilium status --wait` Timing Issue

The script's `cilium status --wait` timed out during first install because Cilium was still pulling a 257MB image from
`quay.io`. The wait expired before the image finished downloading. By the time we re-checked manually, everything was
running correctly.

This is expected behavior on first install on a cold node. On subsequent provisions the images are already cached in
containerd and startup is near-instant.

---

## Verifying Cilium

```bash
# Quick status overview
cilium status

# Per-node agent details (requires CoreDNS)
cilium status --verbose

# Full end-to-end connectivity test
# Deploys real pods and verifies pod-to-pod, pod-to-service, external networking
cilium connectivity test --test-namespace cilium-test

# Confirm pod IPs are from the correct CIDR
kubectl get pods -A -o wide
```

---

## Next Step

Install **CoreDNS**: the cluster DNS server. Pods can communicate by IP already, but cannot resolve service names.
CoreDNS makes `my-service.my-namespace.svc.cluster.local` work: the foundation of all service discovery.

```
✅ 1- VM: using libvrit and QEMU to create controller and worker nodes
✅ 2- PKI: certificates generated and distributed
✅ 3- Kubeconfigs: credentials generated and distributed
✅ 4- etcd: cluster state store 
✅ 5- kube-apiserver: the front door
✅ 6- kube-controller-manager + kube-scheduler
✅ 7- kubelet on worker nodes
✅ 8- Cilium CNI
⬜ 9- CoreDNS
⬜ 10- kubectl get nodes -> all Ready
```