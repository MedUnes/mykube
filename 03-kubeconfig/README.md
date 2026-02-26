# 03- Kubeconfig Generation

## Why Kubeconfigs?

Every component that talks to the [apiserver](https://kubernetes.io/docs/concepts/overview/kubernetes-api//) needs to
know three things:

- **WHERE**: the API server address
- **WHO**: which certificate to use to identify itself
- **TRUST**: the CA cert to verify the server's identity

A kubeconfig bundles all three into a single file. It is the credential file of the Kubernetes world: equivalent to an
`~/.ssh/config` + private key combined into one.

`kubeadm` generates these silently during `kubeadm init`. We are doing it manually to understand exactly what each
component uses to authenticate and where it expects the API server to be.

---

## Security Design: No Public Exposure

A critical decision was made here: **the API server is never addressed by its public IP**.

```
Internet -> VPS public IP Ex: (190.192.1.2)
                v  NAT
           libvirt bridge (virbr2)
                v
          10.0.0.4:6443  <- only reachable from within the VPS host
```

Because the VMs sit behind `libvirt` NAT, `10.0.0.4` is unreachable from the internet already. We reinforce this by:

- All **component kubeconfigs** point to `https://10.0.0.4:6443`: internal only
- The **admin kubeconfig** points to `https://127.0.0.1:6443`: only works via SSH tunnel

Nobody on the internet can reach the `apiserver` directly. If you want external kubectl access later, you add an `nginx`
stream proxy on the VPS: on your terms, with `UFW` control.

---

## What kubeconfigs.sh Does

### `setup.sh`

Checks if `kubectl` is installed and installs it if not: kubectl is used here purely as a config file generator, not to
talk to any cluster yet
anything else:

```bash
sudo ./setup.sh
```

### `kubeconfig.sh`

It then generates 5 kubeconfig files via a shared helper function:

```bash
make_kubeconfig <output> <api_server> <ca> <cert> <key> <username>
```

Each call does four things:

1. `set-cluster`: embeds the CA cert and sets the server address
2. `set-credentials`: embeds the client cert and key
3. `set-context`: links the cluster and credentials together
4. `use-context`: sets it as the active context

`--embed-certs=true` is used on every call: the certificates are baked directly into the kubeconfig file as base64. No
external file paths, no broken references if files move.

---

## Generated Kubeconfigs

### `worker-node-1.kubeconfig` and `worker-node-2.kubeconfig`

Used by [kubelet](https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/) on each worker node to
authenticate to the apiserver.

| Field    | Value                       | Why                                               |
|----------|-----------------------------|---------------------------------------------------|
| Server   | `https://10.0.0.4:6443`     | Internal only: workers are inside the NAT network |
| Username | `system:node:worker-node-1` | Must match the CN in the kubelet cert exactly     |
| Cert     | `worker-node-1.pem`         | The kubelet cert generated in the PKI step        |

The username prefix `system:node:` is not arbitrary: Kubernetes' Node Authorizer grants special permissions specifically
to identities with this prefix. Without it, the `kubelet` cannot register the node.

---

### `kube-controller-manager.kubeconfig`

Used by the **controller-manager** running on the control plane.

| Field    | Value                            | Why                                                      |
|----------|----------------------------------|----------------------------------------------------------|
| Server   | `https://10.0.0.4:6443`          | Runs on the same host as the apiserver, uses internal IP |
| Username | `system:kube-controller-manager` | Must match CN in cert: maps to built-in RBAC role        |
| Cert     | `kube-controller-manager.pem`    | Client cert from PKI step                                |

---

### `kube-scheduler.kubeconfig`

Used by the **scheduler** running on the control plane.

| Field    | Value                   | Why                                      |
|----------|-------------------------|------------------------------------------|
| Server   | `https://10.0.0.4:6443` | Same node as apiserver, internal address |
| Username | `system:kube-scheduler` | Maps to built-in RBAC role               |
| Cert     | `kube-scheduler.pem`    | Client cert from PKI step                |

---

### `admin.kubeconfig`

Used by **you** via `kubectl`. This is the only kubeconfig that points to `127.0.0.1` instead of `10.0.0.4`.

| Field    | Value                    | Why                                                   |
|----------|--------------------------|-------------------------------------------------------|
| Server   | `https://127.0.0.1:6443` | Tunnel address: never the public IP                   |
| Username | `admin`                  | CN=admin, O=system:masters -> full cluster-admin RBAC |
| Cert     | `admin.pem`              | Admin cert from PKI step                              |

It is copied automatically to `~/.kube/config` on the VPS host so kubectl works directly from the VPS too (useful while
the cluster is being bootstrapped before external tunnel access is set up).

---

## Distribution

After generation, kubeconfigs are distributed via `scp`:

| Destination       | Files                                                             |
|-------------------|-------------------------------------------------------------------|
| `worker-node-1`   | `worker-node-1.kubeconfig`                                        |
| `worker-node-2`   | `worker-node-2.kubeconfig`                                        |
| `control-plane-1` | `kube-controller-manager.kubeconfig`, `kube-scheduler.kubeconfig` |

The admin kubeconfig stays on the VPS host: it is never sent to a node.

---

## Using kubectl From Your Laptop

The admin kubeconfig points to `127.0.0.1:6443`. For that to work from your laptop you need an [SSH tunnel](https://linuxize.com/post/how-to-setup-ssh-tunneling/) that forwards
your local port 6443 to the control plane through the VPS:

```bash
# Step 1: open the tunnel (keep this terminal open)
ssh -L 6443:10.0.0.4:6443 -N \
  -i ~/.ssh/<your_vps_key> \
  your_username@<VPS_PUBLIC_IP>

# Step 2: copy the admin kubeconfig to your laptop
scp -i ~/.ssh/<your_vps_key> \
  your_username@<VPS_PUBLIC_IP>:~/k8s-kubeconfigs/admin.kubeconfig \
  ~/.kube/config

# Step 3: use kubectl normally
kubectl get nodes
```

The tunnel maps: `laptop:6443` -> `VPS` -> `10.0.0.4:6443` (control-plane-1 VM).

---

## What Is Not Running Yet

Generating kubeconfigs does not start anything. Port 6443 will return `Connection refused` until the apiserver is
bootstrapped. The kubeconfigs are just credentials waiting to be used.

The remaining bootstrap order:

```
✅ 1- VM: using libvrit and QEMU to create controller and worker nodes
✅ 2- PKI: certificates generated and distributed
✅ 3- Kubeconfigs: credentials generated and distributed
⬜ 4- etcd: cluster state store 
⬜ 5- kube-apiserver: the front door
⬜ 6- kube-controller-manager + kube-scheduler
⬜ 7- kubelet on worker nodes
⬜ 8- Cilium CNI
⬜ 9- kubectl get nodes -> all Ready
```

---

## Next Step

Bootstrap **etcd** on the control plane. Until etcd is running, the apiserver has nowhere to store state and cannot
start.