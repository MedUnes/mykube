# Kubernetes The Hard Way: No Cloud Required

A cloud-free alternative to running Kubernetes on Azure/GCP/AWS. All you need is a single VPS, a Raspberry Pi, or any
machine that supports hardware virtualization. We use **QEMU/KVM** + **Terraform** to spin up 3 virtual machines in one
shot, then bootstrap a real Kubernetes cluster on top of them.

No monthly cloud bill. No vendor lock-in. Just metal and open source.

---

## Architecture

```
Your VPS / Bare Metal Host (Ubuntu)
└── QEMU/KVM Hypervisor
    └── libvirt NAT Network: 10.0.0.0/24 (kubernetes-network)
        │
        ├── control-plane-1   10.0.0.4    (2 vCPU / 3GB RAM / 30GB disk)
        │     ├── kube-apiserver
        │     ├── kube-controller-manager
        │     ├── kube-scheduler
        │     └── etcd
        │
        ├── worker-node-1     10.0.0.36   (1 vCPU / 1GB RAM / 30GB disk)
        │     ├── kubelet
        │     ├── kube-proxy
        │     └── containerd
        │
        └── worker-node-2     10.0.0.37   (1 vCPU / 1GB RAM / 30GB disk)
              ├── kubelet
              ├── kube-proxy
              └── containerd

Kubernetes Internal Networks (managed by k8s, not libvirt):
  Pod CIDR:     10.200.0.0/16  (65,534 addresses)
  Service CIDR: 10.96.0.0/24  (254 addresses)

External Access:
  SSH into VMs via host (NAT) -> adminuser@10.0.0.x
  kubectl from host           -> via kubeconfig pointing to 10.0.0.4:6443
```

Follow The installation steps:

[01- VM: using libvrit and QEMU to create controller and worker nodes](01-qemu-virt)

[02- PKI: certificates generated and distributed](02-certs)

[03- Kubeconfigs: credentials generated and distributed](03-kubeconfig)

[04- etcd Bootstrap: Cluster State Store Installation](04-etcd)
