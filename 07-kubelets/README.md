# 07- Worker Node Bootstrap (Kubelet)

## What Are Worker Nodes?

Worker nodes are where your actual workloads run. Every pod, container, and application you deploy lands on a worker
node. The control plane decides what runs where: the worker nodes do the actual running.

Each worker node needs three things:

```
containerd   : container runtime: pulls images, creates and manages containers
kubelet      : node agent: receives pod specs from apiserver, tells containerd what to run
CNI plugins  : network plumbing: provides the base layer Cilium builds on
```

No kube-proxy: Cilium replaces it entirely using eBPF.

---

## Component Roles

### containerd

The container runtime. When kubelet wants to start a pod, it talks to containerd via a Unix socket (
`/var/run/containerd/containerd.sock`). containerd handles:

- Pulling images from registries
- Creating and managing container lifecycles
- Interfacing with runc for actual process isolation

containerd is configured with `SystemdCgroup = true`: this is critical on Ubuntu 24.04 which uses systemd as its cgroup
driver. Both containerd and kubelet must agree on the same cgroup driver, otherwise kubelet crash-loops silently.

### runc

The low-level OCI runtime that containerd delegates to for the actual container execution. containerd manages the
lifecycle: runc does the Linux namespace and cgroup work to isolate the process. You never interact with runc directly.

### CNI Plugins

The base network plugins (`bridge`, `loopback`, `host-local` etc.) that Cilium builds on. Cilium is the CNI: these
plugins are its underlying plumbing. They must be present at `/opt/cni/bin/` before Cilium can be installed.

### kubelet

The most important component on a worker node. It:

1. Registers the node with the apiserver on startup
2. Watches for pod specs assigned to this node
3. Tells containerd to start or stop containers
4. Reports node and pod status back to the apiserver continuously
5. Runs liveness and readiness probes

kubelet is the only Kubernetes component that runs on every node including the control plane in a full setup. Here we
run it only on workers since our control plane components run as systemd services directly.

---

## Script Structure

### `containerd-config.toml`

Not a template: no placeholders needed. Same config on every node:

```toml
SystemdCgroup = true   # <- must match kubelet cgroupDriver
```

### `kubelet-config.yaml.tpl`

A `KubeletConfiguration` YAML template: the modern way to configure kubelet, replacing the old wall of CLI flags. Two
placeholders filled per node:

- `${NODE_NAME}` -> `worker-node-1` or `worker-node-2`
- `${INTERNAL_IP}` -> `10.0.0.36` or `10.0.0.37`

### `kubelet.service.tpl`

Minimal systemd unit. kubelet reads its configuration from the YAML file: the service only needs to know where that
file is and what the node IP is.

### `bootstrap-workers.sh`

Orchestrates both workers via a `bootstrap_worker()` function called once per node. Flow per worker:

```
1. Render kubelet-config.yaml + kubelet.service (local /tmp)
2. scp configs -> worker node
3. SSH: download + install containerd, configure it, start it
4. SSH: download + install runc
5. SSH: download + install CNI plugins -> /opt/cni/bin/
6. SSH: download + install kubelet binary
7. SSH: install PKI certs -> /etc/kubernetes/pki/
8. SSH: install kubeconfig -> /etc/kubernetes/kubelet.kubeconfig
9. SSH: install + start kubelet systemd service
```

After both workers are done:

```
10. Install kubectl on control-plane-1
11. Fix kubeconfig permissions on control-plane-1
12. kubectl get nodes -o wide to verify registration
```

---

## KubeletConfiguration: Key Fields

| Field                               | Value                                        | Meaning                                                                                                                   |
|-------------------------------------|----------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `authentication.anonymous.enabled`  | `false`                                      | Rejects unauthenticated requests to the kubelet API: no anonymous access                                                  |
| `authentication.webhook.enabled`    | `true`                                       | Delegates authentication decisions to the apiserver                                                                       |
| `authorization.mode`                | `Webhook`                                    | Delegates authorization to the apiserver: only components the apiserver trusts can talk to the kubelet                    |
| `clusterDomain`                     | `cluster.local`                              | The internal DNS domain for the cluster: pods resolve services as `service.namespace.svc.cluster.local`                   |
| `clusterDNS`                        | `10.96.0.10`                                 | The IP address of CoreDNS: the first usable IP reserved in the service CIDR. Injected into every pod's `/etc/resolv.conf` |
| `cgroupDriver`                      | `systemd`                                    | Must match containerd's `SystemdCgroup = true`. A mismatch causes silent crash-loops                                      |
| `containerRuntimeEndpoint`          | `unix:///var/run/containerd/containerd.sock` | How kubelet talks to containerd: via Unix socket                                                                          |
| `resolvConf`                        | `/run/systemd/resolve/resolv.conf`           | Ubuntu 24.04 uses systemd-resolved. Pointing kubelet here prevents pod DNS from breaking                                  |
| `tlsCertFile` / `tlsPrivateKeyFile` | `worker-node-x.pem/key`                      | The kubelet's own TLS cert: used when the apiserver connects back to the kubelet (for logs, exec, port-forward)           |

---

## Certificate Layout on Each Worker

```
/etc/kubernetes/pki/
├── ca.pem                  # cluster CA: verifies the apiserver's identity
├── worker-node-x.pem       # kubelet's own TLS cert
└── worker-node-x-key.pem   # kubelet's private key: chmod 600

/etc/kubernetes/
└── kubelet.kubeconfig      # credentials + apiserver address for kubelet->apiserver calls
```

Workers never receive the CA private key or any control plane certificates: they only get what they need to identify
themselves and verify the apiserver.

---

## How Node Registration Works

When kubelet starts for the first time it:

1. Reads its kubeconfig: finds the apiserver at `https://10.0.0.4:6443`
2. Authenticates using its client cert (`CN=system:node:worker-node-x`, `O=system:nodes`)
3. Sends a `Node` object to the apiserver: registers itself with its IP, hostname, capacity
4. The controller-manager assigns it a pod CIDR from `10.200.0.0/16`
5. The node appears in `kubectl get nodes` as `NotReady`

`NotReady` is correct at this point: it means the node registered successfully but has no CNI plugin yet. The node
condition `NetworkPluginNotReady` will be set. Cilium clears this in the next step.

---

## Expected Output

After a successful run, `kubectl get nodes -o wide` from control-plane-1 shows:

```
NAME            STATUS     ROLES    AGE   VERSION   INTERNAL-IP
worker-node-1   NotReady   <none>   Xs    v1.35.1   10.0.0.36
worker-node-2   NotReady   <none>   Xs    v1.35.1   10.0.0.37
```

`NotReady` is the correct and expected state here. Both nodes registered, kubelet running, containerd confirmed as
runtime. The cluster is waiting for a CNI.

---

## Complete Cluster Status At This Point

| Component               | Node            | Status    |
|-------------------------|-----------------|-----------|
| etcd                    | control-plane-1 | ✅ Running |
| kube-apiserver          | control-plane-1 | ✅ Running |
| kube-controller-manager | control-plane-1 | ✅ Running |
| kube-scheduler          | control-plane-1 | ✅ Running |
| containerd              | worker-node-1/2 | ✅ Running |
| kubelet                 | worker-node-1/2 | ✅ Running |
| CNI                     | :               | ⬜ Pending |

---

## Next Step

Install **Cilium**: the eBPF-based CNI that replaces kube-proxy, provides pod networking, network policy, and load
balancing. Once Cilium is running, nodes transition from `NotReady` to `Ready` and the cluster is fully operational.

```
✅ 1- VM: using libvrit and QEMU to create controller and worker nodes
✅ 2- PKI: certificates generated and distributed
✅ 3- Kubeconfigs: credentials generated and distributed
✅ 4- etcd: cluster state store 
✅ 5- kube-apiserver: the front door
✅ 6- kube-controller-manager + kube-scheduler
✅ 7- kubelet on worker nodes
⬜ 8- Cilium CNI
⬜ 9- kubectl get nodes -> all Ready
```