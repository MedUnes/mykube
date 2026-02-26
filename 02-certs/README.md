# 02- PKI Certificate Generation

## Why Manual PKI Instead of kubeadm?

`kubeadm init` generates all of this automatically and silently. We are doing it manually because:

- You see exactly what certificates exist and why
- You understand what breaks when a cert expires or has wrong SANs
- You can debug TLS failures in production because you built the chain yourself
- kubeadm is a black box, this is the inside of that box

---

## Why cfssl Instead of openssl?

Both tools can generate the same certificates. We use `cfssl` (Cloudflare's PKI toolkit) because:

- Config is plain JSON, readable, versionable, copy-pasteable
- One command generates key + CSR + signed cert in a single pipeline
- No multi-step `openssl genrsa` -> `openssl req` -> `openssl x509` chains
- Output is consistently named and easy to script around

The DX is simply better. Same cryptographic result, far less ceremony.

---

## Script Layout

The PKI work is split into two scripts intentionally:

### `setup.sh`

Installs `cfssl` and `cfssljson` binaries to `/usr/local/bin`. Requires `sudo`. Run this once on the VPS host before
anything else:

```bash
sudo ./setup.sh
```

### `certs.sh`

Generates all certificates and distributes them to the nodes via `scp`. Does **not** require `sudo`, runs entirely as
your normal user:

```bash
./certs.sh
```

---

## What certs.sh Does

At startup the script detects everything dynamically, no hardcoded IPs:

```bash
VPS_PUBLIC_IP=$(curl -s ifconfig.me)
BRIDGE_IP=$(ip addr show virbr2 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
```

It then generates 9 certificate assets and distributes them to the right nodes automatically.

---

## Certificate Breakdown

### Shared Config, `ca-config.json`

Before any certificate is generated, `cfssl` needs a signing policy:

```json
{
  "signing": {
    "profiles": {
      "kubernetes": {
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ],
        "expiry": "8760h"
      }
    }
  }
}
```

`8760h` = 1 year. All certs share this profile.

---

### Step 1, Certificate Authority (CA)

Every other certificate in the cluster is signed by this CA. It is the root of trust.

```bash
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
```

The CSR fields, same structure is reused in every subsequent step:

| Field  | Value        | Meaning                                                      |
|--------|--------------|--------------------------------------------------------------|
| `CN`   | `Kubernetes` | Common Name, the identity this cert represents               |
| `algo` | `rsa`        | Key algorithm                                                |
| `size` | `2048`       | Key size in bits, 2048 is standard for internal PKI          |
| `C`    | `EU`         | Country                                                      |
| `L`    | `Frankfurt`  | City                                                         |
| `ST`   | `Hesse`      | State                                                        |
| `O`    | `Kubernetes` | Organization, Kubernetes uses this for RBAC group membership |
| `OU`   | `CA`         | Organizational Unit                                          |

`-initca` tells `cfssl` this is a self-signed root CA, not a leaf cert.

**Output:** `ca.pem` (public cert) + `ca-key.pem` (private key, never leaves the host)

---

### Step 2, Admin Certificate

```bash
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -profile=kubernetes admin-csr.json | cfssljson -bare admin
```

The only field worth noting here:

| Field | Value            | Why it matters                                                                                                                                                     |
|-------|------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `O`   | `system:masters` | Kubernetes maps this Organization field directly to the `system:masters` RBAC group, which has full cluster-admin access. The `O` field **is** your authorization. |

**Output:** `admin.pem` + `admin-key.pem`, used to generate the admin kubeconfig for kubectl.

---

### Step 3, Kubelet Certificates (one per worker node)

The only step that loops. One cert per worker, each with the node's hostname and IP as SANs:

```bash
cfssl gencert \
  -hostname="${HOST},${IP}" \
  ...
```

| Field       | Value                       | Why it matters                                                                 |
|-------------|-----------------------------|--------------------------------------------------------------------------------|
| `CN`        | `system:node:worker-node-1` | Kubernetes Node Authorizer requires this exact prefix to authorize the kubelet |
| `O`         | `system:nodes`              | Maps to the `system:nodes` RBAC group, required for kubelet authorization      |
| `-hostname` | `worker-node-1,10.0.0.36`   | SANs, the apiserver verifies the kubelet's cert matches its hostname/IP        |

---

### Steps 4, 5, Controller Manager and Scheduler

Client certificates only, they authenticate to the apiserver but are never addressed as servers themselves, so no
`-hostname` SANs needed. The `CN` must match the exact Kubernetes username the RBAC system expects:

| Component               | CN                               |
|-------------------------|----------------------------------|
| kube-controller-manager | `system:kube-controller-manager` |
| kube-scheduler          | `system:kube-scheduler`          |

The `[WARNING] This certificate lacks a "hosts" field` message `cfssl` prints for these is expected and harmless.

---

### Step 6, kube-apiserver Certificate

The most important certificate. The apiserver is a **server**, every component connects to it, so its SANs must cover
every possible address it will be reached at:

```
10.0.0.4                              # internal VM IP
control-plane-1                       # hostname
1.2.3.4                               # VPS public IP (for kubectl from outside, this is a fake value here)
10.0.0.1                              # bridge/gateway IP
10.96.0.1                             # first IP of Service CIDR (kubernetes.default service)
127.0.0.1                             # localhost
kubernetes                            # short DNS names used inside the cluster
kubernetes.default
kubernetes.default.svc
kubernetes.default.svc.cluster.local
```

If any client connects using an address not in this SAN list, TLS verification fails. This is the cert you'll revisit
most often when debugging.

---

### Step 7, etcd Certificate

Server cert for etcd, SANs scoped to the control plane only since etcd only runs there and only talks to the apiserver:

```
-hostname="10.0.0.4,control-plane-1,127.0.0.1"
```

---

### Step 8, Service Account Key Pair

Technically not a TLS certificate in the traditional sense, it's an RSA key pair used for token signing:

- `service-account-key.pem`, private key, used by kube-controller-manager to **sign** service account JWT tokens
- `service-account.pem`, public key, used by kube-apiserver to **verify** those tokens

Pods use these tokens to authenticate to the apiserver from inside the cluster.

---

## Certificate Distribution

At the end of `certs.sh`, certificates are distributed automatically via `scp`:

| Destination       | Certificates                                                                                                                                         |
|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `worker-node-1`   | `ca.pem`, `worker-node-1.pem`, `worker-node-1-key.pem`                                                                                               |
| `worker-node-2`   | `ca.pem`, `worker-node-2.pem`, `worker-node-2-key.pem`                                                                                               |
| `control-plane-1` | `ca.pem`, `ca-key.pem`, `kubernetes.pem/key`, `etcd.pem/key`, `service-account.pem/key`, `kube-controller-manager.pem/key`, `kube-scheduler.pem/key` |

Workers only get what they need, they never see the CA private key or the apiserver cert.

---

## What's Not Generated Here

| Missing            | Reason                                                                                                             |
|--------------------|--------------------------------------------------------------------------------------------------------------------|
| `kube-proxy` cert  | We use **Cilium** with eBPF instead of kube-proxy, it replaces kube-proxy entirely and does not need a certificate |
| `front-proxy` cert | Only needed for API aggregation layer (custom API servers). Not required for this cluster                          |

---

The remaining bootstrap order:

```
✅ VM: using libvrit and QEMU to create controller and worker nodes
✅ PKI: certificates generated and distributed
⬜ Kubeconfigs: credentials generated and distributed
⬜ etcd: cluster state store (next)
⬜ kube-apiserver: the front door
⬜ kube-controller-manager + kube-scheduler
⬜ kubelet on worker nodes
⬜ Cilium CNI
⬜ kubectl get nodes → all Ready
```

---

## Next Step

[Kubeconfigs: credentials generated and distributed](../03-kubeconfig)