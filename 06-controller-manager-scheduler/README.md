# 06- Controller Manager & Scheduler Bootstrap

## What Are These Two Components?

These are the remaining two control plane components. Together with the apiserver and etcd, they complete the control
plane. Unlike the apiserver, neither component serves external traffic: they only make outbound connections to the
apiserver.

### kube-controller-manager

Runs all the reconciliation control loops inside a single binary. A control loop watches the current state of the
cluster and works to bring it toward the desired state.

```
desired state (stored in etcd via apiserver)
        v
controller-manager reads it continuously
        v
compares with actual state
        v
acts on the difference
```

Examples of loops it runs:

| Loop                       | What it does                                                      |
|----------------------------|-------------------------------------------------------------------|
| Node controller            | Detects when nodes go unreachable and marks pods for rescheduling |
| Deployment controller      | Ensures the correct number of ReplicaSet replicas exist           |
| ReplicaSet controller      | Ensures the correct number of pods exist for a ReplicaSet         |
| Service account controller | Creates default service accounts in new namespaces                |
| Job controller             | Tracks job completion and cleans up finished pods                 |

All of these loops run inside one process: that is why it is called the **controller-manager**, not the controller.

### kube-scheduler

Watches for pods that have been created but not yet assigned to a node (`nodeName` is empty). For each unscheduled pod
it:

1. **Filters**: removes nodes that cannot run the pod (insufficient CPU/RAM, taints, affinity rules)
2. **Scores**: ranks remaining nodes by how good a fit they are
3. **Assigns**: writes the chosen node name to the pod spec in etcd via apiserver

The scheduler only makes the decision. It never starts anything: that is the kubelet's job.

---

## Why After the apiserver?

Both components authenticate to the apiserver using their kubeconfigs. The `systemd` units enforce this dependency:

```ini
After=network.target kube-apiserver.service
Requires=kube-apiserver.service
```

Neither can do anything useful without a running apiserver to read from and write to.

---

## Script Structure

### `kube-controller-manager.service.tpl`

No runtime placeholders: all values are static. We run it through `envsubst` anyway for pipeline consistency and
future-proofing.

### `kube-scheduler.service.tpl`

The simplest service file in the entire cluster. The scheduler needs only its kubeconfig and the leader election flag
everything else is self-contained.

### `bootstrap-control-plane.sh`

Bootstraps both components in a single script. Flow:

```
1. Render both .tpl files → service files (local /tmp)
2. scp both service files → control-plane-1:/tmp/
3. SSH: download both binaries (v1.35.1)
4. SSH: install both systemd services, enable + start
5. SSH: verify both are active
6. SSH: kubectl get nodes to confirm apiserver responds
```

---

## Key Flags Explained

### kube-controller-manager

| Flag                                                         | Value                                | Meaning                                                                                                                                                                          |
|--------------------------------------------------------------|--------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--kubeconfig`                                               | `kube-controller-manager.kubeconfig` | How it authenticates to the apiserver: uses the cert we generated in the PKI step with `CN=system:kube-controller-manager`                                                       |
| `--cluster-cidr`                                             | `10.200.0.0/16`                      | The pod IP address space for the entire cluster. Must match the CNI (Cilium) configuration exactly                                                                               |
| `--service-cluster-ip-range`                                 | `10.96.0.0/24`                       | Must match the apiserver's `--service-cluster-ip-range`: they must agree on the same range                                                                                       |
| `--allocate-node-cidrs`                                      | `true`                               | Automatically carves a `/24` subnet from the cluster CIDR for each node. worker-node-1 gets `10.200.0.0/24`, worker-node-2 gets `10.200.1.0/24`. `Cilium` uses these allocations |
| `--cluster-signing-cert-file` / `--cluster-signing-key-file` | `ca.pem / ca-key.pem`                | The CA keypair used to sign certificates for new nodes and service accounts at runtime. This is how the controller-manager issues TLS credentials dynamically                    |
| `--root-ca-file`                                             | `ca.pem`                             | Injected into every service account token so pods can verify the apiserver's TLS certificate                                                                                     |
| `--service-account-private-key-file`                         | `service-account-key.pem`            | Private key used to **sign** JWT tokens issued to pods. The apiserver holds the public key to verify them                                                                        |
| `--use-service-account-credentials`                          | `true`                               | Each controller loop runs with its own dedicated service account token rather than sharing one credential. Better security isolation between controllers                         |
| `--leader-elect`                                             | `true`                               | Only one controller-manager instance is active leader at a time. Costs nothing with a single instance but enables safe HA later without config changes                           |

### kube-scheduler

| Flag             | Value                       | Meaning                                                     |
|------------------|-----------------------------|-------------------------------------------------------------|
| `--kubeconfig`   | `kube-scheduler.kubeconfig` | Authentication to the apiserver: `CN=system:kube-scheduler` |
| `--leader-elect` | `true`                      | Same as controller-manager: safe HA-ready by default        |

The scheduler is intentionally minimal. Scheduling policy, priorities, and plugins can be configured via a
`KubeSchedulerConfiguration` file if needed later: but defaults are correct for our cluster.

---

## IP Range Design: Why These Values

All three IP ranges in the cluster must be completely non-overlapping:

```
Node network     : 10.0.0.0/24     (libvirt NAT: VMs live here)
Service CIDR     : 10.96.0.0/24    (ClusterIP services: virtual IPs)
Pod CIDR         : 10.200.0.0/16   (actual pod IPs assigned by Cilium)
```

`10.200.0.0/16` was chosen specifically because it is far from both other ranges with no possibility of overlap. It
provides `65534` pod addresses: more than enough for any learning cluster and well beyond what our 2-worker setup will
ever use.

---

## What "No Nodes Yet" Means

The final verification step runs `kubectl get nodes` and returns empty. This is correct and expected:

- The control plane has no knowledge of any workers yet
- Workers join by running kubelet, which registers itself with the apiserver
- Until then, the scheduler has nowhere to place pods: it simply waits

The control plane is fully operational. It is waiting for nodes.

---

## Complete Control Plane Status

At this point, the following are running on `control-plane-1`:

| Component               | Port                               | Role                                     |
|-------------------------|------------------------------------|------------------------------------------|
| etcd                    | `:2379` (clients), `:2380` (peers) | Cluster state store                      |
| kube-apiserver          | `:6443`                            | Single entry point: all reads and writes |
| kube-controller-manager | :                                  | Reconciliation loops                     |
| kube-scheduler          | :                                  | Pod placement decisions                  |

---

## Next Step

Bootstrap the **worker nodes**: install `containerd` as the container runtime, then `kubelet` which registers each
worker with the apiserver. Once workers join, `kubectl get nodes` will return all three nodes and the scheduler will
have somewhere to place pods.

## Next Step

With the apiserver healthy on port `6443`, bootstrap the **kube-controller-manager** and **kube-scheduler**: the two
remaining control plane components that watch cluster state and make decisions.

The remaining bootstrap order:

```
✅ 1- VM: using libvrit and QEMU to create controller and worker nodes
✅ 2- PKI: certificates generated and distributed
✅ 3- Kubeconfigs: credentials generated and distributed
✅ 4- etcd: cluster state store 
✅ 5- kube-apiserver: the front door
✅ 6- kube-controller-manager + kube-scheduler
⬜ 7- kubelet on worker nodes
⬜ 8- Cilium CNI
⬜ 9- kubectl get nodes -> all Ready
```