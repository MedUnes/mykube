# 05- kube-apiserver Bootstrap

## What is the kube-apiserver?

The kube-apiserver is the **single entry point** to the entire Kubernetes cluster. Every interaction: whether from
`kubectl`, the scheduler, the controller-manager, or a kubelet: goes exclusively through this component. Nothing talks
to etcd directly except the apiserver.

```
kubectl / external clients
         v
   kube-apiserver :6443     <- the only door
         v
      etcd :2379            <- only the apiserver touches this
```

It is stateless: it holds no data itself. All state lives in etcd. This means the apiserver can be restarted freely
without data loss, and in Ingress setups you can run multiple apiservers behind a load balancer.

---

## Why After etcd?

The apiserver's startup sequence immediately connects to etcd to verify it can read and write state. **If etcd is
unreachable at startup, the apiserver exits**. The `systemd unit` enforces this explicitly:

```ini
After=network.target etcd.service
Requires=etcd.service
```

`Requires=` means systemd will refuse to start the apiserver if etcd is not active. Hard dependency: no silent
failures.

---

## Script Structure

Same pattern as the `etcd` bootstrap:

### `kube-apiserver.service.tpl`

A standalone readable `systemd` unit template. One placeholder filled by `envsubst` at runtime:

- `${INTERNAL_IP}` -> `10.0.0.4`

### `bootstrap-apiserver.sh`

The orchestrator. Runs on the VPS host, connects to `control-plane-1` via SSH. Flow:

```
1. Render kube-apiserver.service.tpl -> kube-apiserver.service (local /tmp)
2. scp kube-apiserver.service -> control-plane-1:/tmp/
3. SSH: download kube-apiserver binary (v1.35.1)
4. SSH: create /etc/kubernetes/pki/, install ALL certs from ~/
5. SSH: install kubeconfigs into /etc/kubernetes/
6. SSH: install service, systemctl enable + start
7. SSH: verify /version endpoint responds with valid JSON
```

---

## Key Flags Explained

### Authentication and Authorization

| Flag                   | Value       | Meaning                                                                                                                                                                                    |
|------------------------|-------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--client-ca-file`     | `ca.pem`    | Any request presenting a cert signed by this CA is considered authenticated. This is how kubectl, kubelet, and other components prove their identity                                       |
| `--authorization-mode` | `Node,RBAC` | Two authorization modes active simultaneously. `Node` restricts what kubelets can do: they can only modify their own node's objects. `RBAC` handles everything else via roles and bindings |
| `--allow-privileged`   | `true`      | Required for system components like Cilium that need to run privileged containers. Without this, CNI installation fails                                                                    |

### etcd Connectivity

| Flag                                 | Value                    | Meaning                                                                                              |
|--------------------------------------|--------------------------|------------------------------------------------------------------------------------------------------|
| `--etcd-servers`                     | `https://127.0.0.1:2379` | Loopback address: apiserver and etcd are on the same node, no need to leave the host                 |
| `--etcd-cafile`                      | `ca.pem`                 | CA to verify etcd's server certificate                                                               |
| `--etcd-certfile` / `--etcd-keyfile` | `etcd.pem/key`           | Client cert the apiserver presents to etcd: required because we enabled `--client-cert-auth` on etcd |

### TLS: Serving

| Flag                     | Value                | Meaning                                                                      |
|--------------------------|----------------------|------------------------------------------------------------------------------|
| `--tls-cert-file`        | `kubernetes.pem`     | The apiserver's own server certificate: presented to every connecting client |
| `--tls-private-key-file` | `kubernetes-key.pem` | Corresponding private key                                                    |

### Service Accounts

| Flag                                 | Value                     | Meaning                                                                                                      |
|--------------------------------------|---------------------------|--------------------------------------------------------------------------------------------------------------|
| `--service-account-key-file`         | `service-account.pem`     | Public key: used to **verify** JWT tokens that pods present                                                  |
| `--service-account-signing-key-file` | `service-account-key.pem` | Private key: used to **sign** new JWT tokens issued to pods                                                  |
| `--service-account-issuer`           | `https://10.0.0.4:6443`   | The issuer claim embedded in every JWT token. Must be a valid URL: clients use this to validate token origin |

### Admission Controllers

```
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota,NodeRestriction
```

These were chosen deliberately: see the table below. They represent the **kubeadm defaults** tier: battle-tested,
widely documented, zero negative side effects on a learning cluster.

| Controller            | Tier             | Why included                                                                                              |
|-----------------------|------------------|-----------------------------------------------------------------------------------------------------------|
| `NamespaceLifecycle`  | Bare minimum     | Prevents resources being created in terminating or non-existent namespaces                                |
| `ServiceAccount`      | Bare minimum     | Auto-injects service account tokens into pods: without this pod-to-apiserver auth breaks entirely         |
| `LimitRanger`         | Sensible default | Enforces resource limits: prevents pods with no CPU/memory limits from starving the node                  |
| `DefaultStorageClass` | Sensible default | Assigns a default storage class to PVCs that don't specify one                                            |
| `ResourceQuota`       | Sensible default | Enforces namespace-level resource quotas                                                                  |
| `NodeRestriction`     | Sensible default | Limits what a kubelet can modify to only its own node's objects: critical security boundary between nodes |

**Adding more later:** Controllers are a flag on the apiserver service. To add one, edit the template, re-render,
upload, and restart the apiserver (~5 seconds downtime). Existing workloads are unaffected unless the new controller is
a retroactive validator like `PodSecurity`.

---

## Certificate Layout

After bootstrap, `/etc/kubernetes/pki/` contains everything the control plane components need:

```
/etc/kubernetes/pki/
├── ca.pem / ca-key.pem                          # cluster CA
├── kubernetes.pem / kubernetes-key.pem          # apiserver TLS cert
├── service-account.pem / service-account-key.pem # JWT signing keypair
├── kube-controller-manager.pem / *-key.pem      # controller-manager client cert
└── kube-scheduler.pem / *-key.pem               # scheduler client cert
```

All private keys are `chmod 600`. All public certs are `chmod 644`.

---

## Verifying the apiserver

The bootstrap script hits the `/version` endpoint as the final verification:

```bash
curl -sk \
  --cacert /etc/kubernetes/pki/ca.pem \
  --cert   /etc/kubernetes/pki/kubernetes.pem \
  --key    /etc/kubernetes/pki/kubernetes-key.pem \
  https://127.0.0.1:6443/version
```

A successful response returns a JSON blob with `gitVersion: v1.35.1`. 
```bash
[+] Verifying kube-apiserver is responding...
{
  "major": "1",
  "minor": "35",
  "emulationMajor": "1",
  "emulationMinor": "35",
  "minCompatibilityMajor": "1",
  "minCompatibilityMinor": "34",
  "gitVersion": "v1.35.1",
  "gitCommit": "8fea90b45245ef5c8ba54e7ae044d3e777c22500",
  "gitTreeState": "clean",
  "buildDate": "2026-02-10T12:53:14Z",
  "goVersion": "go1.25.6",
  "compiler": "gc",
  "platform": "linux/amd64"
}
[+] API server is responding.
```

This proves:

- TLS is working with our certificates
- The apiserver successfully connected to etcd on startup
- The apiserver is accepting authenticated requests

---

## What kubeadm Would Have Done

`kubeadm` runs the apiserver as a **static pod** via a manifest in `/etc/kubernetes/manifests/`. We run it as a
**systemd service**: same outcome, more explicit, easier to inspect with `journalctl -u kube-apiserver`, and does not
require the kubelet to be running first.

---

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
⬜ 6- kube-controller-manager + kube-scheduler
⬜ 7- kubelet on worker nodes
⬜ 8- Cilium CNI
⬜ 9- kubectl get nodes -> all Ready
```