# 11: nginx Ingress Layer

## What This Phase Does

Establishes the entry point for all public traffic into the cluster. nginx
runs on the VPS host, terminates TLS, and proxies requests inward to
Kubernetes Services: resolved via CoreDNS. A generator script renders
nginx virtual host configs from templates and reloads nginx safely.

---

## The Problem

The cluster runs workloads. Those workloads are not reachable from the
internet: they live on an internal network (`10.0.0.x`) behind NAT, with
Cilium eBPF handling all internal routing. There is no cloud load balancer.
There is no public IP on any node.

The VPS host is the only machine with a public IP. nginx already runs there
(from Phase 10: cert-manager ACME proxy). The question is: how does public
HTTP/HTTPS traffic reach the right pod for the right domain?

---

## Options Considered

| Approach                            | How it works                                                      | Verdict                                                                  |
|-------------------------------------|-------------------------------------------------------------------|--------------------------------------------------------------------------|
| **ingress-nginx** (community)       | Kubernetes controller generates nginx config from Ingress objects | Retired March 2026: unmaintained                                         |
| **NGINX Ingress Controller** (F5)   | Same concept, maintained by F5/nginx team                         | Adds a controller layer, CRDs, another nginx instance inside the cluster |
| **Traefik**                         | Dynamic reverse proxy with K8s integration                        | Config complexity, performance characteristics not preferred             |
| **Gateway API**                     | New Kubernetes networking standard                                | Good long-term direction, heavy for current scope                        |
| **VPS nginx → Kubernetes Services** | nginx on host proxies to cluster Services via CoreDNS             | Direct, auditable, zero extra cluster components                         |

We chose **VPS nginx as the ingress layer**. It is the exact same mental model
as running nginx in Docker fronting other containers: the only difference is
that upstreams are Kubernetes Services resolved by CoreDNS instead of Docker
DNS.

---

## Architecture

```
Internet
    │
    │  :80 / :443
    v
VPS nginx (host process)
    │  TLS terminated here
    │  cert from /etc/nginx/ssl/ (written by cert-sync)
    │
    │  resolver 10.96.0.10 (CoreDNS)
    │   set $upstream my-service.default.svc.cluster.local:8000
    │
    v
Kubernetes Service (ClusterIP)
    │
    │  Cilium eBPF routes to pod replica
    │
    v
Pod (your application)
```

nginx is not inside the cluster. It lives on the VPS host and communicates
with the cluster's internal network directly: the VPS host is on the same
`10.0.0.x` network as the nodes (it is the libvirt bridge host).

---

## The CoreDNS Resolver Trick

This is the single most important detail in the proxy template. nginx resolves
DNS **at config-load time by default**. In a normal web server this is fine —
upstreams don't change IP. In Kubernetes, pod IPs change every time a pod
restarts. A plain `proxy_pass http://my-service:8000` would cache the IP at
nginx startup and silently break when the pod behind the Service is replaced.

The fix is two directives working together:

```nginx
resolver 10.96.0.10 valid=10s ipv6=off;

location / {
    set $upstream my-service.default.svc.cluster.local:8000;
    proxy_pass http://$upstream;
}
```

`resolver` tells nginx where to resolve names and how long to cache the result.
`set $upstream` with a variable forces nginx to go through the resolver on
every request cycle instead of resolving once at startup. Without both
directives together, this does not work.

`10.96.0.10` is the CoreDNS ClusterIP: hardcoded in every kubelet's
`clusterDNS` config in Phase 07. It never changes.

---

## PHP-FPM: Option C (nginx sidecar)

PHP-FPM communicates via FastCGI: a binary protocol, not HTTP. nginx would
normally need `fastcgi_pass` to talk to it directly. That creates a problem:
`try_files $uri` needs to check if a PHP file exists on the local filesystem,
but the PHP files live inside the pod, not on the VPS.

Three options were evaluated:

| Option                          | How                                                                         | Problem                                                |
|---------------------------------|-----------------------------------------------------------------------------|--------------------------------------------------------|
| A: copy public dir to VPS       | `try_files` works against local copy                                        | Deployment sync complexity, fragile                    |
| B: skip `try_files`             | Symfony/Laravel front controller handles everything                         | Loses nginx-level 404 short-circuit                    |
| **C: nginx sidecar in the pod** | An nginx container in the pod handles FastCGI internally, exposes HTTP port | VPS sees plain HTTP: identical to any other proxy_pass |

**Option C is the right answer.** The pod runs two containers:

```
Pod: my-php-app
├── nginx container   (port 80) ← VPS proxies here via proxy-pass template
└── php-fpm container (port 9000, internal to pod only)
```

nginx inside the pod handles `fastcgi_pass` to PHP-FPM, serves static files
from the shared volume, and does `try_files`: all with direct filesystem
access. The VPS nginx sees a clean HTTP upstream and uses the standard
`proxy-pass` template. No special template needed at the VPS level.

This also means PHP-FPM is never directly reachable from outside the pod —
only nginx inside the pod can talk to it. Better security posture.

---

## Templates

### `proxy-pass.conf.tpl`

For any HTTP upstream running inside the cluster. Covers:

- Node.js / Next.js
- Django / Flask / FastAPI / Go / Rust
- PHP-FPM with nginx sidecar (transparent to this template)

Variables:

| Variable       | Example              | Meaning                  |
|----------------|----------------------|--------------------------|
| `DOMAIN`       | `api.yourdomain.com` | Public domain            |
| `SERVICE_NAME` | `my-api`             | Kubernetes Service name  |
| `NAMESPACE`    | `production`         | Kubernetes namespace     |
| `SERVICE_PORT` | `8000`               | Port the Service exposes |
| `SITE_NAME`    | auto-derived         | Slug for log file names  |

### `static-files.conf.tpl`

For compiled static output served directly from the VPS filesystem. No
Kubernetes involvement: nginx serves files locally.

Covers:

- React / Vue / Svelte / Angular SPA builds
- Next.js `next export` output
- Plain HTML/CSS/JS sites
- Docusaurus, VitePress, and similar documentation sites

Caching strategy built into the template:

- JS/CSS/fonts: `Cache-Control: immutable` (content-hashed filenames)
- Images/media: 30-day cache
- HTML: never cached (new deploys must be picked up immediately)

Variables:

| Variable    | Example              | Meaning                 |
|-------------|----------------------|-------------------------|
| `DOMAIN`    | `www.yourdomain.com` | Public domain           |
| `WEBROOT`   | `/var/www/mysite`    | Absolute path on VPS    |
| `SITE_NAME` | auto-derived         | Slug for log file names |

---

## Generator: `new-site.sh`

Renders a template, writes the config to `sites-available`, symlinks it into
`sites-enabled`, runs `nginx -t`, and reloads nginx. Idempotent: re-running
overwrites the existing config for the same domain.

nginx is only reloaded if `nginx -t` passes. A broken config is written to
`sites-available` but never activated.

### Adding a proxy-pass site

```bash
./new-site.sh \
  --template proxy-pass \
  --domain   api.yourdomain.com \
  --service  my-api \
  --namespace production \
  --port     8000
```

### Adding a static site

```bash
./new-site.sh \
  --template static-files \
  --domain   www.yourdomain.com \
  --webroot  /var/www/mysite
```

Then deploy your files:

```bash
rsync -av --delete ./dist/ medunes@vps:/var/www/mysite/
```

### Removing a site

```bash
./new-site.sh --remove --domain api.yourdomain.com
```

Removes the config, removes the symlink, reloads nginx.

---

## TLS Certificates

The template references:

```nginx
ssl_certificate     /etc/nginx/ssl/${DOMAIN}.crt;
ssl_certificate_key /etc/nginx/ssl/${DOMAIN}.key;
```

These are written by `cert-sync` (Phase 10). Before a site goes live:

1. Create a `Certificate` resource in the cluster pointing to your domain
2. Wait for cert-manager to issue it (staging first, then production)
3. Run cert-sync manually to pull it to disk:
   ```bash
   /usr/local/bin/cert-sync.sh
   ```
4. Then run `new-site.sh`: or re-run it if you already created the site

The site will return a 500 SSL error if the cert files don't exist yet.
Run `new-site.sh` only after the cert is on disk.

---

## nginx.conf Prerequisite

`new-site.sh` checks that `sites-enabled` is included in nginx.conf. If it
isn't, add this inside the `http {}` block:

```nginx
include /etc/nginx/sites-enabled/*.conf;
```

On a fresh Debian/Ubuntu nginx install this is already present. On a
manually configured nginx it may not be.

---

## Workflow: Adding a New Service End-to-End

```
1. Deploy your app to the cluster
   kubectl apply -f my-app-deployment.yaml
   kubectl apply -f my-app-service.yaml

2. Create a Certificate in cert-manager
   (staging first, then production)

3. Run cert-sync to pull the cert to disk
   /usr/local/bin/cert-sync.sh

4. Run new-site.sh to generate and activate the nginx config
   ./new-site.sh --template proxy-pass --domain app.yourdomain.com \
     --service my-app --namespace default --port 8000

5. Verify
   curl -I https://app.yourdomain.com
```

---

## Tradeoffs Summary

| Decision                           | Alternative                                          | Why we chose this                                                                                               |
|------------------------------------|------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| nginx on VPS host                  | nginx Ingress controller inside cluster              | Direct, no controller overhead, no CRDs, identical mental model to pre-K8s experience                           |
| Manual template generation         | Controller watches K8s API and auto-generates config | Full config control, no magic, debuggable with standard nginx tools                                             |
| CoreDNS resolver + `set $upstream` | Static IP in proxy_pass                              | Pod IPs are ephemeral: static IPs break on pod restart                                                          |
| Static files on VPS filesystem     | Static files in a pod                                | Zero network hops for files with no runtime, no container image rebuilds for content updates                    |
| nginx sidecar for PHP-FPM          | Direct `fastcgi_pass` from VPS nginx                 | VPS nginx cannot do `try_files` against pod filesystem; sidecar solves this cleanly and keeps PHP-FPM unexposed |

---

## Files

```
11-ingress/
├── new-site.sh                      # Config generator and nginx reloader
└── templates/
    ├── proxy-pass.conf.tpl          # HTTP upstream in cluster (Node, Go, Django, PHP+sidecar)
    └── static-files.conf.tpl        # Compiled static files on VPS filesystem
```

Runtime files on VPS host (managed by new-site.sh):

```
/etc/nginx/sites-available/<domain>.conf    # generated config
/etc/nginx/sites-enabled/<domain>.conf      # symlink → sites-available
/var/log/nginx/<site_name>.access.log       # per-site access log
/var/log/nginx/<site_name>.error.log        # per-site error log
```

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
✅ 11- Ingress
```

