# 04- etcd Bootstrap: Cluster State Store Installation

## What is etcd?

etcd is the **only stateful component** in a Kubernetes cluster. It is a distributed key-value store that holds the
entire cluster state: every pod definition, node registration, secret, configmap, service, and deployment lives here as
a key-value entry.

Every other Kubernetes component is stateless and can be restarted freely. etcd cannot. If etcd is lost without a
backup, the cluster state is gone permanently.

```
kubectl apply -f pod.yaml
        v
   kube-apiserver validates the request
        v
   writes desired state to etcd   <- source of truth
        v
   kube-scheduler reads from etcd (via apiserver)
        v
   kubelet reads from etcd (via apiserver)
        v
   containerd starts the container
```

Nothing in this chain works without etcd. It is bootstrapped first because the apiserver literally refuses to start
without a healthy etcd endpoint.

---

## Why Before Everything Else?

The apiserver's startup flags include `--etcd-servers=https://10.0.0.4:2379`. If etcd is not running and healthy when
the apiserver starts, the apiserver exits immediately. The order is non-negotiable:

```
etcd -> apiserver -> controller-manager + scheduler -> kubelet -> Cilium
```

---

## Single Node vs Cluster

In production, etcd runs as a cluster of 3 or 5 nodes for high availability. The number must always be odd: this is
because etcd uses the **Raft consensus algorithm** which requires a quorum (majority) to commit a write. With 3 nodes, 1
can fail. With 5 nodes, 2 can fail.

We run a **single etcd node** on `control-plane-1`. This is standard for a learning cluster: it is also what `kubeadm`
does by default for single control-plane setups.

---

## Script Structure

The bootstrap is split into two files:

### `configs/etcd.service.tpl`

A plain systemd unit file template. Two placeholders are filled at runtime by `envsubst`:

- `${ETCD_NAME}` -> `control-plane-1`
- `${INTERNAL_IP}` -> `10.0.0.4`

The template is a standalone readable file in the repo. The rendered result is printed to stdout before upload so you
can verify it before anything is executed on the node.

### `bootstrap-etcd.sh`

Runs entirely on the VPS host. Connects to `control-plane-1` via SSH for execution. The flow:

```
1. Render etcd.service.tpl -> etcd.service (local /tmp)
2. scp etcd.service -> control-plane-1:/tmp/
3. SSH: download etcd binary from GitHub releases
4. SSH: create /etc/etcd/, install certs from ~/
5. SSH: install etcd.service, systemctl enable + start
6. SSH: verify with etcdctl member list + endpoint health
```

---

## Key etcd Flags Explained

These are the flags in `etcd.service.tpl` worth understanding:

| Flag                      | Value                                          | Meaning                                                                                                             |
|---------------------------|------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| `--name`                  | `control-plane-1`                              | Human-readable member name in the cluster                                                                           |
| `--data-dir`              | `/var/lib/etcd`                                | Where etcd persists all data to disk                                                                                |
| `--listen-client-urls`    | `https://10.0.0.4:2379,https://127.0.0.1:2379` | Accepts client connections on both internal IP and loopback: apiserver uses loopback since it runs on the same node |
| `--listen-peer-urls`      | `https://10.0.0.4:2380`                        | Port for etcd peer-to-peer communication (unused in single node, required by the protocol)                          |
| `--advertise-client-urls` | `https://10.0.0.4:2379`                        | The address etcd tells other members to use to reach it                                                             |
| `--initial-cluster`       | `control-plane-1=https://10.0.0.4:2380`        | Defines the initial cluster membership: just one node here                                                          |
| `--initial-cluster-state` | `new`                                          | Signals this is a brand new cluster, not rejoining an existing one                                                  |
| `--initial-cluster-token` | `etcd-cluster-k8s`                             | Prevents accidental cross-cluster communication if multiple etcd clusters exist on the same network                 |
| `--client-cert-auth`      | :                                              | Requires all clients to present a valid certificate signed by the CA. Anonymous access is rejected                  |
| `--peer-client-cert-auth` | :                                              | Same requirement for peer connections between etcd members                                                          |

---

## Certificate Layout

etcd uses mutual TLS: both the server and the client must present certificates:

```
/etc/etcd/
├── ca.pem          # CA cert: used to verify connecting clients
├── etcd.pem        # etcd server cert: presented to clients
└── etcd-key.pem    # etcd private key: chmod 600, never leaves the node
```

These were generated in the PKI step and distributed by `certs.sh`. The bootstrap script moves them from `~/` into
`/etc/etcd/` and sets correct permissions.

---

## Verifying Health

After bootstrap, `etcdctl` is used to verify:

```bash
# Member list: confirms the node is registered
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/etcd.pem \
  --key=/etc/etcd/etcd-key.pem \
  member list

# Endpoint health: confirms reads/writes are working
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/etcd.pem \
  --key=/etc/etcd/etcd-key.pem \
  endpoint health
```

A healthy response looks like:

```
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 9ms
```

The `successfully committed proposal` part is the important signal: it means etcd was able to write to its Raft log,
which is the core operation the apiserver depends on.

---

## What kubeadm Would Have Done

`kubeadm init` runs etcd as a **static pod**: a YAML manifest placed in `/etc/kubernetes/manifests/` that the kubelet
picks up and manages automatically. We are running it as a **systemd service** instead, which is more explicit, easier
to inspect with `journalctl`, and does not depend on the kubelet being up first.

---

## Next Step

With etcd healthy on port `2379`, bootstrap the **kube-apiserver**: the front door to the cluster that all other
components and users communicate through.

The remaining bootstrap order:

```
✅ VM: using libvrit and QEMU to create controller and worker nodes
✅ PKI: certificates generated and distributed
✅ Kubeconfigs: credentials generated and distributed
✅ etcd: cluster state store (next)
⬜ kube-apiserver: the front door
⬜ kube-controller-manager + kube-scheduler
⬜ kubelet on worker nodes
⬜ Cilium CNI
⬜ kubectl get nodes → all Ready
```