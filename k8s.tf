terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.1"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_volume" "ubuntu_noble" {
  name = "ubuntu-24.04-base.qcow2"
  pool = "default"

  target = {
    format = { type = "qcow2" }
    compat = "1.1"
  }

  create = {
    content = {
      url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    }
  }
}

resource "libvirt_network" "kubernetes_network" {
  name = "kubernetes-network"

  forward = {
    mode = "nat"
  }

  domain = {
    name = "k8s.local"
  }

  ips = [
    {
      address = "10.0.0.1"
      netmask = "255.255.255.0"
    }
  ]
}

variable "vm_names" {
  type = map(object({
    ip   = string
    role = string
  }))
  default = {
    "control-plane-1" = {
      ip   = "10.0.0.4"
      role = "control-plane"
    }
    "worker-node-1" = {
      ip   = "10.0.0.36"
      role = "worker"
    }
    "worker-node-2" = {
      ip   = "10.0.0.37"
      role = "worker"
    }
  }
}

resource "libvirt_cloudinit_disk" "node_init" {
  for_each = var.vm_names

  name = "cloudinit-${each.key}.iso"

  meta_data = <<-EOF
    instance-id: ${each.key}
    local-hostname: ${each.key}
  EOF

  user_data = <<-EOF
#cloud-config
manage_etc_hosts: true
users:
  - name: adminuser
    ssh_authorized_keys:
      - ${file(pathexpand("~/.ssh/id_rsa_k8s_vm.pub"))}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
runcmd:
  - ufw allow 22/tcp
  - ufw allow 6443/tcp
  - ufw allow from 10.0.0.0/24
  - ufw --force enable
EOF

  network_config = <<-EOF
version: 2
ethernets:
  id0:
    match:
      name: "en*"
    dhcp4: false
    addresses:
      - ${each.value.ip}/24
    gateway4: 10.0.0.1
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
EOF
}

resource "libvirt_volume" "node_disk" {
  for_each = var.vm_names

  name = "${each.key}.qcow2"
  pool = "default"

  target = {
    format = { type = "qcow2" }
    compat = "1.1"
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_noble.path
    format = { type = "qcow2" }
  }

  capacity = 30000000000
}

# 5. Virtual Machines
resource "libvirt_domain" "kubernetes_nodes" {
  for_each = var.vm_names

  name    = each.key
  type    = "kvm"
  running = true

  vcpu        = each.value.role == "control-plane" ? 2 : 1
  memory      = each.value.role == "control-plane" ? 3072 : 1024
  memory_unit = "MiB"

  os = {
    type = "hvm"
  }

  devices = {
    disks = [
      {
        device = "disk"
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        target = { dev = "vda", bus = "virtio" }
        source = {
          volume = {
            pool   = "default"
            volume = libvirt_volume.node_disk[each.key].name
          }
        }
      },
      {
        device = "cdrom"
        driver = {
          name = "qemu"
          type = "raw"
        }
        target = { dev = "hdc", bus = "sata" }
        source = {
          file = {
            file = libvirt_cloudinit_disk.node_init[each.key].path
          }
        }
      }
    ]

    interfaces = [
      {
        source = {
          network = { network = libvirt_network.kubernetes_network.name }
        }
      }
    ]

    consoles = [
      {
        type   = "pty"
        target = { type = "serial", port = 0 }
      }
    ]
  }
}

