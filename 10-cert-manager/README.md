# 10- cert-manager + TLS Certificate Lifecycle

## What This Phase Does

Installs cert-manager into the cluster, configures Let's Encrypt issuers, and
sets up a systemd-based certificate sync mechanism so TLS certificates issued
inside Kubernetes are automatically available to nginx on the VPS host.

---

## The Problem

The VPS host runs nginx as its public-facing web server. nginx needs TLS
certificates on the filesystem (`/etc/nginx/ssl/`). Kubernetes secrets live
inside the cluster: nginx has no native way to read them.

Options considered:

| Option                 | How it works                                            | Verdict                                |
|------------------------|---------------------------------------------------------|----------------------------------------|
| Manual cert copy       | `kubectl get secret` by hand, paste into files          | Error-prone, breaks on renewal         |
| cert-manager + Ingress | Ingress controller handles TLS inside cluster           | Adds complexity, Ingress not in scope  |
| Shared volume mount    | Mount cert-manager secret into a host path              | Requires CSI driver, complex           |
| **cert-sync timer**    | systemd timer reads secrets via kubectl, writes to disk | Simple, auditable, no extra components |

We chose **cert-sync**: a small bash script running as a systemd timer every
12 hours on the VPS host. It reads TLS secrets from the cluster using a
dedicated read-only kubeconfig and writes them to `/etc/nginx/ssl/`. nginx is
reloaded only when a cert actually changes.

---

## Architecture

```
Let's Encrypt ACME
       │
       │  HTTP-01 challenge (port 80)
       v
  VPS nginx
       │  proxies /.well-known/acme-challenge/ > NodePort
       v
  cert-manager challenge solver pod (NodePort Service)
       │
       │  issues certificate
       v
  Kubernetes Secret (tls.crt + tls.key)
       │
       │  cert-sync reads every 12h
       v
  /etc/nginx/ssl/yourdomain.com.crt
  /etc/nginx/ssl/yourdomain.com.key
       │
       v
  nginx reloaded (only if cert changed)
```

---

## Challenge Types

### HTTP-01 (default, used here)

cert-manager spins up a temporary pod with a NodePort Service to respond to
the ACME challenge. nginx on the VPS proxies
`/.well-known/acme-challenge/` to this NodePort.

**Tradeoffs:**

- ✅ Works immediately: no DNS provider needed
- ✅ No API tokens to manage
- ❌ Does not support wildcard certificates
- ❌ Requires port 80 to be reachable from the internet
- ❌ NodePort is dynamic: nginx proxy config must be updated each time

The dynamic NodePort problem is solved by `acme-update-proxy.sh`: called by
cert-sync on every run. It checks for active cert-manager challenge solver
services, extracts the current NodePort, and rewrites the nginx upstream block.

### DNS-01 via Cloudflare (optional)

Set `CHALLENGE_TYPE=dns01-cloudflare` and export `CLOUDFLARE_API_TOKEN`.
cert-manager creates a TXT record via the Cloudflare API to prove domain
ownership.

**Tradeoffs:**

- ✅ Supports wildcard certificates (`*.yourdomain.com`)
- ✅ Works even if port 80 is blocked
- ❌ Requires a Cloudflare API token with `Zone:DNS:Edit` permission
- ❌ DNS propagation adds ~30s delay to issuance

### DNS-01 via Webhook (optional)

For other DNS providers. Set `CHALLENGE_TYPE=dns01-webhook`. Requires
installing a provider-specific webhook in the cluster separately.

---

## cert-sync Design

### Why not use the admin kubeconfig?

The admin kubeconfig has full cluster access (`system:masters`). Running it in
an automated timer on the host would be a significant blast radius if the
script misbehaved or was tampered with.

### cert-sync RBAC

A dedicated ServiceAccount `cert-sync` in the `cert-manager` namespace with
a Role that grants only:

```yaml
- get, list on Secrets in namespace cert-manager
```

That's it. It cannot read secrets in other namespaces, cannot create or delete
anything, cannot touch any other resource. The kubeconfig is generated with a
token bound to this ServiceAccount.

### cert-sync flow

1. Timer fires every 12 hours
2. `cert-sync.sh` reads `CERTS` array: one entry per domain
3. For each entry: checks if the Secret exists and has a cert
4. Compares new cert to what's on disk: skips if identical
5. Writes `.crt` and `.key` to `/etc/nginx/ssl/`
6. Calls `acme-update-proxy.sh` to refresh NodePort (HTTP-01 only)
7. Reloads nginx only if at least one cert changed

### Adding a new domain

1. Create a `Certificate` resource in the cluster pointing at `letsencrypt-production`
2. Add an entry to the `CERTS` array in `/usr/local/bin/cert-sync.sh`:
   ```bash
   "my-app-tls:app.yourdomain.com"
   ```
3. Run `cert-sync.sh` manually once to sync immediately
4. Add the cert to your nginx site config:
   ```nginx
   ssl_certificate     /etc/nginx/ssl/app.yourdomain.com.crt;
   ssl_certificate_key /etc/nginx/ssl/app.yourdomain.com.key;
   ```

---

## ACME Challenge Proxy

nginx needs to proxy the ACME HTTP-01 challenge to the cert-manager solver pod
running inside the cluster. The solver is exposed as a NodePort Service: but
the NodePort number is dynamically assigned by Kubernetes each time.

`acme-update-proxy.sh` solves this by:

1. Querying `kubectl` for any Service in the cluster with the label
   `acme.cert-manager.io/http01-solver=true`
2. Extracting the current NodePort
3. Rewriting the `proxy_pass` line in `/etc/nginx/conf.d/acme-challenge.conf`
4. Reloading nginx if the port changed

When no challenge is active (between issuances), the nginx block returns 503.
This is correct: the endpoint only needs to work during the ~60 second window
when Let's Encrypt makes its validation request.

---

## ClusterIssuers

Two issuers are created:

| Issuer                   | Server                               | Purpose                                         |
|--------------------------|--------------------------------------|-------------------------------------------------|
| `letsencrypt-staging`    | acme-staging-v02.api.letsencrypt.org | Testing: issues untrusted certs, no rate limits |
| `letsencrypt-production` | acme-v02.api.letsencrypt.org         | Real trusted certs: rate limited                |

**Always test with staging first.** Let's Encrypt production has strict rate
limits (5 failed validations per domain per hour, 50 certs per domain per
week). A misconfigured nginx proxy will eat through these quickly.

---

## Staging vs Production Workflow

```bash
# Step 1: request staging cert
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-staging
  namespace: cert-manager
spec:
  secretName: myapp-staging-tls
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
  dnsNames:
    - yourdomain.com
EOF

# Step 2: watch issuance
kubectl describe certificate myapp-staging -n cert-manager
kubectl describe challenge -n cert-manager   # if stuck

# Step 3: once staging cert issued, switch to production
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-prod
  namespace: cert-manager
spec:
  secretName: myapp-prod-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - yourdomain.com
EOF

# Step 4: run cert-sync to pull cert to disk
/usr/local/bin/cert-sync.sh

# Step 5: configure nginx to use it
# ssl_certificate     /etc/nginx/ssl/yourdomain.com.crt;
# ssl_certificate_key /etc/nginx/ssl/yourdomain.com.key;
```

---

## Files

```
10-cert-manager/
├── bootstrap-certmanager.sh          # Main bootstrap script
├── configs/
│   ├── cert-sync-rbac.yaml           # ServiceAccount + Role + RoleBinding
│   ├── clusterissuer-http01.yaml.tpl
│   ├── clusterissuer-dns01-cloudflare.yaml.tpl
│   └── clusterissuer-dns01-webhook.yaml.tpl
└── cert-sync/
    ├── cert-sync.sh                  # Cert sync script (runs on VPS host)
    ├── cert-sync.service             # systemd service unit
    ├── cert-sync.timer               # systemd timer (every 12h)
    └── acme-update-proxy.sh          # Updates nginx NodePort for HTTP-01
```

Runtime files installed on the VPS host:

```
/usr/local/bin/cert-sync.sh
/usr/local/bin/acme-update-proxy.sh
/etc/systemd/system/cert-sync.service
/etc/systemd/system/cert-sync.timer
/etc/nginx/conf.d/acme-challenge.conf   # ACME proxy (http01 only)
/etc/nginx/ssl/                         # Written by cert-sync
~/.kube/cert-sync.kubeconfig            # Read-only kubeconfig for cert-sync
```

---

## Tradeoffs Summary

| Decision                                    | Alternative                                            | Why we chose this                                                |
|---------------------------------------------|--------------------------------------------------------|------------------------------------------------------------------|
| cert-sync timer on VPS host                 | Ingress controller with TLS termination inside cluster | nginx already runs on host, no need to add Ingress complexity    |
| Dedicated read-only ServiceAccount          | Use admin kubeconfig                                   | Principle of least privilege: cert-sync can only read secrets    |
| NodePort for HTTP-01 solver                 | LoadBalancer or HostPort                               | No cloud LB available, HostPort requires privileged pods         |
| Staging > production workflow               | Direct production                                      | Rate limit protection: staging has no limits, production does    |
| cert-sync reads from cert-manager namespace | Store certs in default namespace                       | cert-manager manages its secrets in its own namespace by default |

```
✅ 1- Preparation: Terraform provisions 3 VMs via QEMU/KVM
✅ 2- PKI: certificates generated and distributed
✅ 3- Kubeconfigs: credentials generated and distributed
✅ 4- etcd: cluster state store
✅ 5- kube-apiserver: the front door
✅ 6- kube-controller-manager + kube-scheduler
✅ 7- kubelet on nodes
✅ 8- Cilium CNI
✅ 9- CoreDNS
✅ 10- Cert Manager
⬜ 11- Ingress
```

## Next Step

[11- Ingress](../11-ingress)