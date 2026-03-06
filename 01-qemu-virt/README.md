# Phase 01: VM Provisioning

## What This Phase Does

Creates three Ubuntu 24.04 virtual machines on the host using QEMU/KVM and
Terraform. These VMs become the Kubernetes nodes. Everything from phase 02
onward runs inside them.

---

## Why QEMU/KVM Instead of Cloud VMs

The entire cluster runs on a single VPS. QEMU/KVM with libvirt lets you carve
that machine into multiple isolated VMs with real network separation: the same
result as renting three cloud instances, without the per-instance cost.

libvirt creates a NAT bridge (`10.0.0.0/24`) that the VMs share. They talk to
each other over this private network. The host machine acts as the gateway.
From outside, only the host's public IP is visible.

---

## Why Terraform

The three VMs are identical in structure: same base image, same cloud-init
config, same network: but with different names, IPs, and resource allocations.
Terraform expresses this as a single resource block with a count, renders
cloud-init per node, and provisions everything in one command. Tearing down
and reprovisioning is equally one command.

---

## What Gets Created

| VM              | IP        | Role                 | vCPU | RAM | Disk |
|-----------------|-----------|----------------------|------|-----|------|
| control-plane-1 | 10.0.0.4  | etcd + control plane | 2    | 3GB | 30GB |
| worker-node-1   | 10.0.0.36 | workloads + ingress  | 1    | 1GB | 30GB |
| worker-node-2   | 10.0.0.37 | workloads            | 1    | 1GB | 30GB |

All three boot Ubuntu 24.04 via cloud-init with:

- A dedicated user (`adminuser`) with your SSH public key injected
- Static IPs configured at boot
- No passwords: SSH key only

---

## Prerequisites

Hardware virtualization must be available on the host:

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo   # must be > 0
sudo kvm-ok                            # must say KVM acceleration can be used
```

Minimum host resources: 6GB RAM, 4 CPU cores, 60GB free disk.

---

## Scripts

### `setup.sh`

Installs and configures everything the host needs before Terraform can run:
QEMU/KVM, libvirt, the Terraform binary, the libvirt storage pool, and the
SSH key pair (`~/.ssh/id_rsa_k8s_vm`). Run once on a fresh host.

```bash
sudo ./setup.sh
```

### `k8s.tf`

Terraform manifest. Defines the libvirt network, base image volume, per-node
disks, cloud-init ISOs, and VM domains. All node differences are expressed
through a locals map: no copy-paste between nodes.

```bash
terraform init
terraform apply
```

After apply, wait ~60 seconds for cloud-init to finish before moving to
phase 02.

---

## Verify

```bash
sudo virsh list --all
# control-plane-1   running
# worker-node-1     running
# worker-node-2     running

ssh -i ~/.ssh/id_rsa_k8s_vm adminuser@10.0.0.4    # control plane
ssh -i ~/.ssh/id_rsa_k8s_vm adminuser@10.0.0.36   # worker 1
ssh -i ~/.ssh/id_rsa_k8s_vm adminuser@10.0.0.37   # worker 2
```

## Tear Down

```bash
terraform destroy
```

Removes all VMs, disks, and the network. The host OS and storage pool are
untouched. Re-running `terraform apply` gives you three fresh nodes.

---

## Next Step

[02-certs: PKI and certificate distribution](../02-certs)