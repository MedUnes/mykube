# 9- CoreDNS Bootstrap

## What Problem Does CoreDNS Solve?

Pod IPs are ephemeral: every time a pod restarts it gets a new IP. If pods had to communicate by IP directly, every
consumer would need to track IP changes constantly. Kubernetes solves this with **Services**: stable virtual IPs that
front a group of pods. But a stable IP is still not human-friendly.

CoreDNS is the cluster DNS server that turns names into IPs:

```
pod wants to reach "payment-api"
        ↓
pod queries 10.96.0.10:53  (injected by kubelet into every pod's /etc/resolv.conf)
        ↓
CoreDNS resolves "payment-api.default.svc.cluster.local" → 10.96.0.45
        ↓
pod connects to 10.96.0.45
        ↓
Cilium eBPF routes it to the correct backend pod
```

Without CoreDNS, service discovery is completely broken. Pods can only talk to each other by raw IP: which changes on
every restart.

---

## Why CoreDNS?

CoreDNS has been the default Kubernetes DNS since v1.13, replacing kube-dns. It is plugin-based: each capability is a
discrete plugin in the Corefile. This makes it easy to reason about what it does, easy to extend, and easy to
reconfigure without restarts.

---

## Installation Method: Raw Manifests

Three options exist: raw Kubernetes YAML, `kubeadm init phase addon coredns`, or Helm.

We chose **raw manifests** for the same reason we chose manual PKI over kubeadm for certificates: we want to see and own
every resource that gets created. kubeadm generates the same manifests internally. We are just doing it explicitly.

---

## What Gets Deployed

Six Kubernetes resources, each with a distinct role:

### `ConfigMap coredns`: the Corefile

The entire DNS configuration lives here as a plain text file. This is the most important resource to understand:

```
.:53 {
    errors                     # log DNS errors
    health { lameduck 5s }     # /health endpoint for liveness probe
    ready                      # /ready endpoint for readiness probe

    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure            # enable pod DNS records
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }

    forward . 8.8.8.8          # forward unresolved names upstream
    cache 30                   # cache responses for 30 seconds
    loop                       # detect and break DNS forwarding loops
    reload                     # auto-reload when ConfigMap changes
    loadbalance                # round-robin across multiple A records
}
```

**Why `8.8.8.8`**: explicit upstream is more reliable than inheriting the node's `/etc/resolv.conf`. Our Ubuntu VMs use
`127.0.0.53` (systemd-resolved) which can behave unpredictably inside containers. Hardcoding `8.8.8.8` (Google) gives
predictable, always-available external resolution.

**Changing upstream later: zero downtime:**

```bash
kubectl edit configmap coredns -n kube-system
# change: forward . 8.8.8.8
# to:     forward . 1.1.1.1 8.8.8.8  (multiple with failover)
```

The `reload` plugin watches the ConfigMap and applies changes automatically. No pod restart needed. Takes effect within
seconds.

---

### `ServiceAccount coredns`

The identity that CoreDNS pods run as. Pods use ServiceAccount tokens to authenticate to the apiserver: not certificates
like human users. Without a ServiceAccount, the CoreDNS pod would have no identity and could not read cluster state.

---

### `ClusterRole system:coredns`

Defines **what** CoreDNS is allowed to do: the permissions it needs to resolve names. CoreDNS must watch services and
endpoints to know what names exist:

```
can list/watch: endpoints, services, pods, namespaces
can list/watch: endpointslices
```

Read-only. CoreDNS never creates or modifies anything: it only reads. This is the **principle of least privilege**: the
role is exactly as wide as needed and no wider.

The `system:` prefix marks this as a protected system role: Kubernetes prevents accidental deletion.

---

### `ClusterRoleBinding system:coredns`

Binds the `system:coredns` ClusterRole to the `coredns` ServiceAccount. The full RBAC chain:

```
coredns ServiceAccount  →  ClusterRoleBinding  →  ClusterRole system:coredns
     (who)                      (link)                  (what they can do)
```

---

### `Deployment coredns`: 2 Replicas

Two replicas for **High Availability**: DNS is queried by every single pod on every service call. If the only CoreDNS
instance dies, the entire cluster's service discovery breaks instantly and cascades through all running workloads.

Two replicas means:

- One pod can die or be evicted without any DNS downtime
- Rolling updates replace one replica at a time: zero downtime during CoreDNS upgrades

The deployment has two important scheduling constraints:

**`podAntiAffinity`**: the two replicas prefer different nodes. One node going down doesn't take both DNS instances with
it. Our two replicas landed on `worker-node-1` and `worker-node-2` as intended.

**`priorityClassName: system-cluster-critical`**: the scheduler will never evict CoreDNS pods under resource pressure.
Other pods get evicted first. DNS is too foundational to lose.

**`toleration: node.kubernetes.io/not-ready`**: breaks the chicken-and-egg problem: nodes need DNS to become Ready, but
pods normally don't schedule on NotReady nodes. This toleration lets CoreDNS schedule on NotReady nodes so DNS comes up
before the nodes are fully Ready.

---

### `Service kube-dns`: ClusterIP `10.96.0.10`

The fixed virtual IP that every pod uses as its DNS server. This value was hardcoded earlier in
`kubelet-config.yaml.tpl`:

```yaml
clusterDNS:
  - 10.96.0.10
```

Every kubelet injects this into every pod's `/etc/resolv.conf` at startup:

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
```

The Service ClusterIP is **explicitly pinned** to `10.96.0.10`. Without this, Kubernetes assigns a random IP from the
service CIDR: which would not match what kubelet is injecting into pods.

`10.96.0.10` follows the convention: `10.96.0.1` is the `kubernetes` service itself, `.10` is the first reserved DNS
address. **This value should never be changed on a running cluster**: it is baked into every running pod's network
configuration.

---

## Verified Output

After a successful bootstrap:

```
NAME                      READY   STATUS    IP             NODE
coredns-xxx-yyy           1/1     Running   10.200.1.6     worker-node-2
coredns-xxx-zzz           1/1     Running   10.200.0.132   worker-node-1

NAME       TYPE        CLUSTER-IP   PORT(S)
kube-dns   ClusterIP   10.96.0.10   53/UDP,53/TCP,9153/TCP
```

Pod IPs from `10.200.x.x` confirms Cilium IPAM is working. One pod per worker confirms anti-affinity is working.
ClusterIP pinned correctly.

---

## Next Step

With CoreDNS running, the cluster is fully operational. Run a **full cluster verification**: deploy a test workload end
to end and confirm pods, services, DNS resolution, and inter-pod networking all work correctly.
```
✅ 1- VM: using libvrit and QEMU to create controller and worker nodes
✅ 2- PKI: certificates generated and distributed
✅ 3- Kubeconfigs: credentials generated and distributed
✅ 4- etcd: cluster state store 
✅ 5- kube-apiserver: the front door
✅ 6- kube-controller-manager + kube-scheduler
✅ 7- kubelet on worker nodes
✅ 8- Cilium CNI
✅ 9- CoreDNS
⬜ 10- kubectl get nodes -> all Ready
```