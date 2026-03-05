# 07: Nodes Bootstrap

## What This Phase Does

Installs containerd, runc, CNI plugins, and kubelet on **all three cluster nodes** in a single script. This phase is
responsible for making every machine in the cluster a functioning Kubernetes node: workers and control plane alike.

```
bootstrap-nodes.sh
  ├── worker-node-1  : kubelet registered, no taint, fully schedulable
  ├── worker-node-2  : kubelet registered, no taint, fully schedulable
  └── control-plane-1: kubelet registered, tainted immediately after
```

---

## Why All Three Nodes: Not Just the Workers

This is the most important design decision in this phase and it is not obvious from reading Kubernetes documentation.

### The Problem: ClusterIP Routing From the Apiserver

The kube-apiserver is a **systemd process running on the control-plane-1 host network**. It is not a pod. It does not
live inside the Kubernetes network. It operates at the raw Linux networking layer of its host.

Cilium's eBPF programs: which handle all ClusterIP routing: only load onto nodes where Cilium has a pod running.
Without kubelet on control-plane-1, the Cilium DaemonSet never schedules there. Without a Cilium pod, no eBPF rules are
loaded onto the control-plane-1 network interface. Without eBPF rules, `10.96.0.x` ClusterIP addresses are completely
unroutable from the host network stack.

The consequence: whenever the apiserver calls an **admission webhook**: cert-manager, any validating or mutating
webhook: it resolves the webhook's ClusterIP and tries to connect. It times out every time:

```
apiserver -> POST https://cert-manager-webhook.cert-manager.svc:443/validate
         -> resolves to ClusterIP 10.96.0.19:443
         -> dial tcp 10.96.0.19:443: i/o timeout
         -> Error: failed calling webhook "webhook.cert-manager.io"
```

This is not a cert-manager bug. This is not a Cilium bug. It is an architectural gap: the apiserver process lives
outside the eBPF-managed network and cannot reach ClusterIPs unless Cilium runs on the same host.

### The Fix

Installing kubelet on control-plane-1 registers it as a Kubernetes node. The Cilium DaemonSet immediately schedules a
pod there. That pod loads eBPF rules onto the control-plane-1 network interface. ClusterIP routing starts working for
the apiserver process.

```
kubelet on control-plane-1 registers node
        v
Cilium DaemonSet schedules pod on control-plane-1
        v
eBPF rules loaded onto control-plane-1 network interface
        v
apiserver can reach any ClusterIP service
        v
admission webhooks work
```

---

## The Taint: Keeping Workloads Off the Control Plane

control-plane-1 already runs etcd, kube-apiserver, kube-controller-manager, and kube-scheduler as systemd processes.
Adding arbitrary user pods risks resource contention with these critical components.

The solution is a **taint** applied immediately after kubelet registers the node:

```
node-role.kubernetes.io/control-plane:NoSchedule
```

A taint is a marker that tells the scheduler: "do not place pods here unless they explicitly tolerate this". The effect:

```
Regular Deployment / StatefulSet / Job
  -> no toleration -> never scheduled on control-plane-1

Cilium DaemonSet
  -> has toleration for node-role.kubernetes.io/control-plane:NoSchedule
  -> schedules on control-plane-1  ✅: exactly what we need

CoreDNS Deployment
  -> no toleration -> stays on workers  ✅

Your application pods
  -> no toleration -> stay on workers  ✅
```

The taint is standard Kubernetes convention. kubeadm applies it automatically. We apply it explicitly in the bootstrap
script immediately after the node registers.

---

## Component Roles

### containerd

The container runtime. kubelet communicates with it via Unix socket (`/var/run/containerd/containerd.sock`) to start and
stop containers. containerd handles image pulls, container lifecycle, and delegates process isolation to runc.

Configured with `SystemdCgroup = true`: mandatory on Ubuntu 24.04 which uses systemd as its cgroup driver. kubelet must
use the same driver (`cgroupDriver: systemd`) or it crash-loops silently on startup.

### runc

The low-level OCI container runtime. containerd delegates to it for actual Linux namespace and cgroup setup. Never
interacted with directly.

### CNI Plugins

Base network plugins (`bridge`, `loopback`, `host-local`, etc.) installed to `/opt/cni/bin/`. Cilium is the CNI but it
builds on these binary plugins. They must exist before Cilium installs.

### kubelet

The node agent. On every node it:

1. Registers the node with the apiserver
2. Watches for pod assignments via the apiserver
3. Instructs containerd to start/stop containers
4. Reports pod and node health back to the apiserver
5. Runs liveness and readiness probes

---

## KubeletConfiguration: Key Fields

| Field                               | Value                                        | Why                                                                                  |
|-------------------------------------|----------------------------------------------|--------------------------------------------------------------------------------------|
| `authentication.anonymous.enabled`  | `false`                                      | No unauthenticated access to the kubelet API                                         |
| `authentication.webhook.enabled`    | `true`                                       | Delegates auth to the apiserver                                                      |
| `authorization.mode`                | `Webhook`                                    | Delegates authorization to the apiserver                                             |
| `clusterDomain`                     | `cluster.local`                              | DNS domain injected into every pod                                                   |
| `clusterDNS`                        | `10.96.0.10`                                 | CoreDNS ClusterIP: injected into every pod's `/etc/resolv.conf`                      |
| `cgroupDriver`                      | `systemd`                                    | Must match containerd's `SystemdCgroup = true`                                       |
| `containerRuntimeEndpoint`          | `unix:///var/run/containerd/containerd.sock` | How kubelet talks to containerd                                                      |
| `resolvConf`                        | `/run/systemd/resolve/resolv.conf`           | Ubuntu 24.04 systemd-resolved path: avoids pod DNS breakage                          |
| `tlsCertFile` / `tlsPrivateKeyFile` | node cert/key                                | kubelet's TLS identity for apiserver->kubelet connections (logs, exec, port-forward) |

---

## Certificate Layout on Each Node

```
/etc/kubernetes/pki/
├── ca.pem                 : cluster CA, used to verify apiserver identity
├── {node-name}.pem        : kubelet TLS cert, unique per node
└── {node-name}-key.pem    : kubelet private key, chmod 600

/etc/kubernetes/
└── kubelet.kubeconfig     : apiserver address + node credentials
```

All node certificates were generated in phase `02-certs` and distributed to each node's home directory. This phase
copies them into the correct system paths.

---

## The Admin Kubeconfig on control-plane-1

At the end of this phase, the script installs `~/.kube/config` on control-plane-1. Two things are notable:

**Why admin, not kube-controller-manager?**
An early attempt used the `kube-controller-manager.kubeconfig` as the default kubeconfig on control-plane-1. The
controller-manager identity has restricted RBAC: it cannot manage ClusterRoles or ClusterRoleBindings. Cilium
installation immediately fails:

```
User "system:kube-controller-manager" cannot get resource "clusterroles"
in API group "rbac.authorization.k8s.io" at the cluster scope
```

The correct kubeconfig is `admin.kubeconfig`: `CN=admin`, `O=system:masters`, full cluster-admin access.

**Why patch the server address?**
`admin.kubeconfig` was generated in phase `03-kubeconfig` with server `https://127.0.0.1:6443`: the SSH tunnel address
for external kubectl access from the VPS host. On control-plane-1 itself, the tunnel is not active. The script patches
the address to `https://10.0.0.4:6443` (direct internal access) before installing it.

---

## Script Flow

```
bootstrap_node() called for worker-node-1
bootstrap_node() called for worker-node-2
bootstrap_node() called for control-plane-1

  Per node:
    1. Render kubelet-config.yaml + kubelet.service from templates
    2. scp configs to node
    3. SSH: install containerd + runc, configure, start
    4. SSH: install CNI plugins to /opt/cni/bin/
    5. SSH: install kubelet binary
    6. SSH: install PKI certs to /etc/kubernetes/pki/
    7. SSH: install kubeconfig to /etc/kubernetes/kubelet.kubeconfig
    8. SSH: install and start kubelet systemd service

After all three nodes:
    9.  Wait 10s for registration
   10.  Apply taint + label to control-plane-1
   11.  Patch admin.kubeconfig to internal IP, install as ~/.kube/config
   12.  Install kubectl on control-plane-1
   13.  Verify all three nodes with kubectl get nodes -o wide
```

---

## Expected Output

```
NAME              STATUS     ROLES           AGE   VERSION   INTERNAL-IP
control-plane-1   NotReady   control-plane   Xs    v1.35.1   10.0.0.4
worker-node-1     NotReady   <none>          Xs    v1.35.1   10.0.0.36
worker-node-2     NotReady   <none>          Xs    v1.35.1   10.0.0.37
```

All three nodes registered. `NotReady` is expected: no CNI yet. The control-plane taint and label are visible:

```
kubectl describe node control-plane-1 | grep Taints
Taints: node-role.kubernetes.io/control-plane:NoSchedule
```

---

## Next Step

Install **Cilium** (`08-cilium`). Once Cilium schedules pods on all three nodes: including control-plane-1: eBPF rules
are active everywhere, nodes transition to `Ready`, and ClusterIP routing works from the apiserver process.

```
✅ 1- Preparation: Terraform provisions 3 VMs via QEMU/KVM
✅ 2- PKI: certificates generated and distributed
✅ 3- Kubeconfigs: credentials generated and distributed
✅ 4- etcd: cluster state store 
✅ 5- kube-apiserver: the front door
✅ 6- kube-controller-manager + kube-scheduler
✅ 7- kubelet on nodes
⬜ 8- Cilium CNI
⬜ 9- CoreDNS
⬜ 10- Cert Manager
⬜ 11- Ingress
```
## Next Step

[Cilium CNI](../08-cillium)