# Kubernetes The Hard Way: Self-Hosted on QEMU/KVM

This repository bootstraps a fully functional Kubernetes cluster from scratch
on a single VPS using QEMU/KVM virtual machines. Every component is installed
manually: no kubeadm, no managed control plane, no cloud provider.

The goal is to understand exactly what Kubernetes is made of by building each
layer yourself and making deliberate decisions at every step.

---

## What Was Built

A three-node Kubernetes cluster running inside QEMU/KVM VMs on a single VPS,
with a complete production ingress stack:

- **Custom PKI**: CA, apiserver, kubelet, etcd, service-account certs, all
  generated and distributed manually
- **etcd**: bootstrapped as a systemd service, single-node cluster state store
- **Control plane**: kube-apiserver, kube-controller-manager, kube-scheduler
  all running as systemd services from raw binaries
- **Worker nodes**: containerd, runc, CNI plugins, kubelet
- **Cilium**: eBPF-based CNI replacing kube-proxy entirely
- **CoreDNS**: cluster DNS, manually deployed with its RBAC and ConfigMap
- **cert-manager**: Let's Encrypt certificate lifecycle automation
- **nginx ingress**: runs inside the cluster as a hostNetwork DaemonSet,
  reached via iptables DNAT from the VPS

---

## Architecture

```
Internet :80/:443
    │
    v
VPS (public IP)
    iptables DNAT → worker-node-1:80/443
    No nginx. No proxy. Pure packet forwarding.
    │
    v
QEMU/KVM: libvirt bridge 10.0.0.0/24
    │
    ├── control-plane-1   10.0.0.4
    │     etcd
    │     kube-apiserver
    │     kube-controller-manager
    │     kube-scheduler
    │
    ├── worker-node-1     10.0.0.36   ← ingress node
    │     kubelet + containerd
    │     nginx pod (hostNetwork: true, ports 80/443)
    │
    └── worker-node-2     10.0.0.37
          kubelet + containerd

Kubernetes networks:
  Pod CIDR:     10.200.0.0/16  (Cilium)
  Service CIDR: 10.96.0.0/12
  CoreDNS:      10.96.0.10
```

---

## Key Design Decisions

**Why not kubeadm?**
kubeadm abstracts away certificate generation, kubeconfig distribution, static
pod manifests, and component flags. Doing it manually means understanding what
each of those actually does and why it exists.

**Why QEMU/KVM instead of bare metal or cloud VMs?**
A single VPS with virtualization support gives you multiple isolated nodes
with real network separation, without paying for multiple cloud instances.
libvirt manages the NAT bridge so nodes communicate on a private network while
the VPS host controls external access.

**Why Cilium instead of Flannel/Calico?**
Cilium replaces kube-proxy entirely using eBPF. Service routing, load
balancing, and network policy all happen in the kernel without iptables chain
overhead. It is the direction the industry is moving.

**Why hostNetwork DaemonSet for ingress instead of a cloud load balancer?**
There is no cloud load balancer. The VPS is the only machine with a public IP.
Running nginx on the VPS host looks simple but fails: the host cannot reach
Kubernetes ClusterIPs because they are virtual IPs that only exist inside
cluster nodes via Cilium eBPF. Running nginx inside the cluster as a
hostNetwork pod solves this cleanly: the pod binds to the node's real IP and
has full access to CoreDNS and all ClusterIPs. The VPS forwards packets to
that node with two iptables DNAT rules.

**Why manual cert-sync was abandoned in favour of Secret volume mounts?**
The earlier design synced certs from Kubernetes Secrets to the VPS filesystem
via a systemd timer, so VPS-hosted nginx could read them. Once nginx moved
inside the cluster, certs could be mounted directly as pod volumes: simpler,
automatic, and cert renewals are picked up without any sync process.

---

## What You Learn From This Repo

- How Kubernetes PKI works: which components trust which CAs, what goes in
  each certificate's CN and O fields, how kubeconfigs embed credentials
- How the apiserver authenticates kubelets, and why `kubectl logs` requires a
  separate RBAC binding (`system:kubelet-api-admin`)
- How etcd stores cluster state and why the apiserver is the only component
  that talks to it directly
- How Cilium replaces kube-proxy: eBPF programs intercept packets at the
  kernel level and rewrite destinations to pod IPs without iptables chains
- How CoreDNS resolves Service names and why `cluster.local` search domains
  are configured in kubelet
- How cert-manager handles the ACME HTTP-01 challenge flow end to end
- How iptables DNAT and MASQUERADE work together to forward public traffic
  into a private network and return replies through the correct source
- How nginx's `resolver` directive and `set $upstream` variable interact to
  force per-request DNS resolution: and why a plain `proxy_pass` breaks when
  pod IPs change

---

## Phases

| #  | Phase                                                           | What happens                                |
|----|-----------------------------------------------------------------|---------------------------------------------|
| 01 | [qemu-virt](01-qemu-virt)                                       | Terraform provisions 3 VMs via QEMU/KVM     |
| 02 | [certs](02-certs)                                               | Full PKI: CA + all component certificates   |
| 03 | [kubeconfig](03-kubeconfig)                                     | kubeconfigs for every cluster identity      |
| 04 | [etcd](04-etcd)                                                 | etcd bootstrapped as systemd service        |
| 05 | [apiserver](05-apiserver)                                       | kube-apiserver as systemd service           |
| 06 | [controller-manager-scheduler](06-controller-manager-scheduler) | Control plane components                    |
| 07 | [nodes](07-nodes)                                               | Worker node runtime: containerd, kubelet    |
| 08 | [cilium](08-cillium)                                            | eBPF CNI: pod networking comes alive        |
| 09 | [coredns](09-coredns)                                           | Cluster DNS                                 |
| 10 | [cert-manager](10-cert-manager)                                 | Let's Encrypt TLS automation                |
| 11 | [ingress](11-ingress)                                           | nginx DaemonSet + DNAT + full TLS lifecycle |

Each phase directory contains a bootstrap script and a README explaining the
decisions made at that layer.

---

## Prerequisites

- VPS or host machine with KVM support (`egrep -c '(vmx|svm)' /proc/cpuinfo`)
- Ubuntu 22.04+, minimum 8GB RAM, 100GB disk
- Terraform
- A domain with DNS A record pointing to the VPS public IP
- An email address for Let's Encrypt (phase 10+)

---

## Deploying a Service

Once the cluster is up, deploying a containerized application and serving it
over HTTPS takes three steps and one yaml file.

### 1. Point DNS to your VPS

Create an A record for your domain pointing to the VPS public IP before
anything else. Let's Encrypt validates domain ownership over HTTP: it must
resolve before you request a cert.

### 2. Write app.yaml

A Deployment tells Kubernetes to run your container and keep it alive.
A Service gives it a stable internal DNS name so nginx can reach it.
Both go in one file.

```yaml
# app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: youruser/yourimage:latest
          ports:
            - containerPort: 8000    # port your app listens on inside the container
---
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: default
spec:
  selector:
    app: my-app
  ports:
    - port: 8000
      targetPort: 8000
```

Apply it:

```bash
kubectl apply -f app.yaml
kubectl get pods          # wait for Running
kubectl logs my-app-xxxxx # confirm the app started cleanly
```

### 3. Run new-site.sh

```bash
cd 11-ingress
./new-site.sh --template proxy-pass \
  --domain app.yourdomain.com \
  --service my-app \
  --namespace default \
  --port 8000
```

This single command:

- Requests a staging cert to validate the ACME flow (no rate limit cost)
- Requests a production Let's Encrypt cert
- Mounts the cert Secret into the nginx ingress pod
- Generates the nginx virtual host config and adds it to the cluster
- Reloads nginx

When it finishes, `https://app.yourdomain.com` is live.

### After that

You never touch certificates or nginx again for this domain. cert-manager
renews the cert automatically before it expires. The nginx-reload CronJob
picks up renewed certs every 12 hours.

To update your application, change the image tag and reapply:

```bash
kubectl set image deployment/my-app my-app=youruser/yourimage:v2
kubectl rollout status deployment/my-app
```

To remove the site entirely:

```bash
./new-site.sh --remove --domain app.yourdomain.com
kubectl delete -f app.yaml
```