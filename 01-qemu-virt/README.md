## 01- Prerequisites

### 1. A Machine Supporting Hardware Virtualization

Check if your CPU supports KVM:

```bash
# Intel CPU
grep -c vmx /proc/cpuinfo

# AMD CPU
grep -c svm /proc/cpuinfo
```

Any result greater than `0` means you're good. If you get `0`, your host does not support KVM and the VMs will be too
slow for Kubernetes.

Also confirm KVM is usable:

```bash
sudo apt install -y cpu-checker
sudo kvm-ok
# Expected output: INFO: /dev/kvm exists: KVM acceleration can be used
```

### 2. Minimum Host Resources

| Resource  | Minimum       | Recommended  |
|-----------|---------------|--------------|
| RAM       | 8 GB          | 16 GB        |
| CPU cores | 4             | 6+           |
| Disk      | 60 GB free    | 100 GB       |
| OS        | Ubuntu 22.04+ | Ubuntu 24.04 |

Check your available resources:

```bash
free -h
nproc
df -h /
```

### 3. Install QEMU, KVM, and libvirt

```bash
sudo apt update
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  bridge-utils \
  virt-manager

# Add your user to the libvirt and kvm groups
sudo usermod -aG libvirt $USER
sudo usermod -aG kvm $USER

# Apply group membership without logging out
newgrp libvirt

# Start and enable libvirt
sudo systemctl enable --now libvirtd

# Verify
sudo virsh version
sudo virsh list --all
```

Create the default storage pool (required if it doesn't exist):

```bash
sudo virsh pool-define-as default dir - - - - /var/lib/libvirt/images
sudo virsh pool-build default
sudo virsh pool-start default
sudo virsh pool-autostart default

# Verify
sudo virsh pool-list --all
```

### 4. Install Terraform

```bash
sudo apt install -y gnupg software-properties-common

wget -O- https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor | \
  sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update
sudo apt install -y terraform

# Verify
terraform version
```

---

## Generate SSH Key Pair

The VMs use SSH key authentication only: no passwords. Generate a dedicated key pair for this cluster:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_k8s_vm -N ""
```

This creates:

- `~/.ssh/id_rsa_k8s_vm`: private key (never share this)
- `~/.ssh/id_rsa_k8s_vm.pub`: public key (injected into VMs via cloud-init)

> **Note:** The Terraform file references `~/.ssh/id_rsa_k8s_vm.pub` by default. Either generate your key with that
> name, or update the `user_data` block in `k8s.tf` to point to your key path.

---

## Project Structure

```
k8s/
└── k8s.tf       # Single Terraform file: all infrastructure defined here
```

---

## What Terraform Creates

In a single `terraform apply`, the following resources are provisioned:

| Resource                              | Description                                       |
|---------------------------------------|---------------------------------------------------|
| `libvirt_volume.ubuntu_noble`         | Ubuntu 24.04 base image (downloaded once, shared) |
| `libvirt_network.kubernetes_network`  | NAT bridge network at 10.0.0.0/24                 |
| `libvirt_volume.node_disk[*]`         | 3x 30GB qcow2 disks backed by base image          |
| `libvirt_cloudinit_disk.node_init[*]` | 3x cloud-init ISOs (user, network, meta config)   |
| `libvirt_domain.kubernetes_nodes[*]`  | 3x KVM virtual machines, started automatically    |

---

## Build the Cluster

### Step 1: Clone and enter the directory

```bash
git clone https://github.com/medunes/mykube.git
cd k8s-libvirt
```

### Step 2: Update the SSH key path (if needed)

Open `k8s.tf` and find this line in the `user_data` block:

```hcl
- ${file(pathexpand("~/.ssh/id_rsa_k8s_vm.pub"))}
```

Change it to match your key:

```hcl
- ${file(pathexpand("~/.ssh/id_rsa_k8s_vm.pub"))}
```

### Step 3: Initialize and apply

```bash
terraform init
terraform plan
terraform apply
```

Terraform will download the Ubuntu 24.04 cloud image (~600MB on first run), create all disks, configure cloud-init, and
start all 3 VMs automatically.

### Step 4: Wait for cloud-init

Give the VMs ~60 seconds to finish booting and running cloud-init:

```bash
sleep 60
```

### Step 5: Verify VMs are running

```bash
sudo virsh list --all
#  Id   Name              State
#  ---------------------------------
#   1   control-plane-1   running
#   2   worker-node-1     running
#   3   worker-node-2     running
```

---

## SSH Into the Nodes

```bash
# Control plane
ssh -i ~/.ssh/id_rsa_k8s_vm adminuser@10.0.0.4

# Worker node 1
ssh -i ~/.ssh/id_rsa_k8s_vm adminuser@10.0.0.36

# Worker node 2
ssh -i ~/.ssh/id_rsa_k8s_vm adminuser@10.0.0.37
```

> The VMs are on a libvirt NAT network. They are reachable directly from the host machine. If you need access from
> outside the host, set up an SSH tunnel or port forward through the host.

If you reprovision and get a host key warning:

```bash
ssh-keygen -f ~/.ssh/known_hosts -R '10.0.0.4'
ssh-keygen -f ~/.ssh/known_hosts -R '10.0.0.36'
ssh-keygen -f ~/.ssh/known_hosts -R '10.0.0.37'
```

---

## Tear Down

```bash
terraform destroy
```

This removes all VMs, disks, and the network. The libvirt storage pool and the host OS are untouched.

---

## Next Steps

With 3 running Ubuntu 24.04 nodes, you're ready to bootstrap Kubernetes:

1. Install `containerd` on all nodes
2. Install `kubeadm`, `kubelet`, `kubectl` on all nodes
3. Run `kubeadm init` on `control-plane-1`
4. Run `kubeadm join` on both worker nodes
5. Install a CNI plugin (Flannel or Calico)
6. Verify with `kubectl get nodes`

---

## Troubleshooting

**VMs stuck at shut off after apply**
Make sure `running = true` is set in the `libvirt_domain` resource in `k8s.tf`.

**Storage pool not found**
Run the pool creation commands in the Prerequisites section above.

**SSH connection refused right after apply**
Cloud-init is still running. Wait 60 seconds and try again.

**Host key changed warning after reprovision**
Expected: the VM got a new identity. Run the `ssh-keygen -R` commands shown above.

**Not enough memory**
Check `free -h`. You need at least 5GB free before applying. Stop any unnecessary services on the host first.

The remaining bootstrap order:

```
✅ VM: using libvrit and QEMU to create controller and worker nodes
⬜ PKI: certificates generated and distributed
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

[PKI: certificates generated and distributed](../02-certs)