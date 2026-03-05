#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Phase 01 — QEMU/KVM/libvirt Setup Script
# Checks hardware requirements, installs all dependencies, configures libvirt,
# fixes known AppArmor/permission issues, generates SSH key, and verifies
# the environment is ready for terraform apply.
#
# Usage: sudo ./setup.sh
# =============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo ./setup.sh"
  exit 1
fi

# Run as root but remember the actual user for key generation and group setup
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

# --- Colors ----------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
step()  { echo -e "\n${BLUE}--- $* ---${NC}"; }

ERRORS=0

# =============================================================================
# PHASE 1 — REQUIREMENTS CHECK
# =============================================================================

echo "============================================================"
echo " Phase 01 — Requirements Check"
echo "============================================================"

# --- CPU Virtualization ---------------------------------------------------

step "Checking CPU virtualization support"

VIRT_SUPPORT=$(grep -E -c 'vmx|svm' /proc/cpuinfo || true)
if [ "$VIRT_SUPPORT" -gt 0 ]; then
  pass "Virtualization extensions found ($VIRT_SUPPORT logical CPUs supported)."
else
  fail "CPU does not support hardware virtualization (vmx/svm). KVM will not work."
  ERRORS=$((ERRORS + 1))
fi

# --- KVM usability --------------------------------------------------------

step "Checking KVM usability"

if ! command -v kvm-ok &>/dev/null; then
  info "kvm-ok not found — installing cpu-checker..."
  apt-get update -qq
  apt-get install -y -qq cpu-checker
fi

if command -v kvm-ok &>/dev/null; then
  OUTPUT=$(kvm-ok 2>&1 || true)
  if echo "$OUTPUT" | grep -q "KVM acceleration can be used"; then
    pass "KVM acceleration is usable."
  else
    fail "KVM acceleration cannot be used. Enable Virtualization in BIOS."
    echo "    Output: $OUTPUT"
    ERRORS=$((ERRORS + 1))
  fi
else
  warn "Could not run kvm-ok check — skipping."
fi

# --- RAM ------------------------------------------------------------------

step "Checking RAM"

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

if [ "$TOTAL_RAM_GB" -ge 16 ]; then
  pass "RAM: ${TOTAL_RAM_GB}GB — recommended 16GB met."
elif [ "$TOTAL_RAM_GB" -ge 8 ]; then
  warn "RAM: ${TOTAL_RAM_GB}GB — minimum 8GB met, recommended 16GB not met."
else
  fail "RAM: ${TOTAL_RAM_GB}GB — below minimum 8GB."
  ERRORS=$((ERRORS + 1))
fi

# --- CPU cores ------------------------------------------------------------

step "Checking CPU cores"

CPU_CORES=$(nproc)
if [ "$CPU_CORES" -ge 6 ]; then
  pass "CPU cores: ${CPU_CORES} — recommended 6+ met."
elif [ "$CPU_CORES" -ge 4 ]; then
  warn "CPU cores: ${CPU_CORES} — minimum 4 met, recommended 6+ not met."
else
  fail "CPU cores: ${CPU_CORES} — below minimum 4."
  ERRORS=$((ERRORS + 1))
fi

# --- Disk space -----------------------------------------------------------

step "Checking disk space"

DISK_AVAIL_GB=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
if [ "$DISK_AVAIL_GB" -ge 100 ]; then
  pass "Disk: ${DISK_AVAIL_GB}GB available — recommended 100GB met."
elif [ "$DISK_AVAIL_GB" -ge 60 ]; then
  warn "Disk: ${DISK_AVAIL_GB}GB available — minimum 60GB met, recommended 100GB not met."
else
  fail "Disk: ${DISK_AVAIL_GB}GB available — below minimum 60GB."
  ERRORS=$((ERRORS + 1))
fi

# --- Abort if hard requirements not met -----------------------------------

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  fail "${ERRORS} requirement(s) not met. Fix the issues above before continuing."
  exit 1
fi

echo ""
pass "All requirements met — proceeding with installation."

# =============================================================================
# PHASE 2 — INSTALL PACKAGES
# =============================================================================

echo ""
echo "============================================================"
echo " Phase 02 — Installing QEMU, KVM, libvirt, Terraform"
echo "============================================================"

step "Installing QEMU/KVM/libvirt packages"

apt-get update -qq
apt-get install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  bridge-utils \
  virt-manager \
  cpu-checker

pass "QEMU/KVM/libvirt installed."

step "Adding ${ACTUAL_USER} to libvirt and kvm groups"

usermod -aG libvirt "$ACTUAL_USER"
usermod -aG kvm     "$ACTUAL_USER"
pass "${ACTUAL_USER} added to libvirt and kvm groups."
warn "Group membership takes effect on next login. Use 'newgrp libvirt' in your session if needed."

step "Enabling and starting libvirtd"

systemctl enable --now libvirtd
systemctl is-active --quiet libvirtd \
  && pass "libvirtd is running." \
  || { fail "libvirtd failed to start."; exit 1; }

step "Installing Terraform"

if command -v terraform &>/dev/null; then
  pass "Terraform already installed: $(terraform version -json | python3 -c 'import sys,json; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform version | head -1)"
else
  apt-get install -y -qq gnupg software-properties-common

  wget -qO- https://apt.releases.hashicorp.com/gpg | \
    gpg --dearmor | \
    tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
    https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/hashicorp.list > /dev/null

  apt-get update -qq
  apt-get install -y terraform
  pass "Terraform installed: $(terraform version | head -1)"
fi

# =============================================================================
# PHASE 3 — CONFIGURE LIBVIRT
# =============================================================================

echo ""
echo "============================================================"
echo " Phase 03 — Configuring libvirt"
echo "============================================================"

# --- Fix QEMU user/group --------------------------------------------------
# QEMU processes must run as root to access image files without AppArmor
# permission issues. Without this, terraform apply fails with:
#   Permission denied on /var/lib/libvirt/images/ubuntu-24.04-base.qcow2
# The default value is #user = "libvirt-qemu" — we set it to "root".

step "Configuring QEMU to run as root (fixes image permission issues)"

QEMU_CONF="/etc/libvirt/qemu.conf"

# Handle both commented forms: #user = "libvirt-qemu" and #user = "root"
if grep -qE '^user\s*=\s*"root"' "$QEMU_CONF"; then
  pass "QEMU already configured to run as root."
else
  # Replace whichever commented user line exists
  sed -i 's|^#\s*user\s*=.*|user = "root"|' "$QEMU_CONF"
  sed -i 's|^#\s*group\s*=.*|group = "root"|' "$QEMU_CONF"

  # Verify
  if grep -qE '^user\s*=\s*"root"' "$QEMU_CONF"; then
    pass "QEMU user set to root."
  else
    fail "Could not set QEMU user — edit /etc/libvirt/qemu.conf manually:"
    fail "  Set: user = \"root\" and group = \"root\""
    exit 1
  fi

  systemctl restart libvirtd
  pass "libvirtd restarted with new QEMU user config."
fi

# --- Storage pool ---------------------------------------------------------

step "Setting up libvirt default storage pool"

POOL_DIR="/var/lib/libvirt/images"
mkdir -p "$POOL_DIR"

if virsh pool-info default &>/dev/null; then
  POOL_STATE=$(virsh pool-info default | grep State | awk '{print $2}')
  if [ "$POOL_STATE" = "running" ] || [ "$POOL_STATE" = "active" ]; then
    pass "Default storage pool already running."
  else
    virsh pool-start default
    pass "Default storage pool started."
  fi
else
  virsh pool-define-as default dir - - - - "$POOL_DIR"
  virsh pool-build default
  virsh pool-start default
  virsh pool-autostart default
  pass "Default storage pool created and started."
fi

# --- Image permissions ----------------------------------------------------
# Belt-and-suspenders: set correct permissions on the pool directory.
# The real fix is the QEMU root user above, but this doesn't hurt.

step "Setting storage pool directory permissions"

chmod 755 "$POOL_DIR"
pass "Storage pool directory permissions set."

# =============================================================================
# PHASE 4 — SSH KEY
# =============================================================================

echo ""
echo "============================================================"
echo " Phase 04 — SSH Key"
echo "============================================================"

step "Checking SSH key for cluster nodes"

SSH_KEY_PATH="${ACTUAL_HOME}/.ssh/id_rsa_k8s_vm"

if [ -f "${SSH_KEY_PATH}" ] && [ -f "${SSH_KEY_PATH}.pub" ]; then
  pass "SSH key already exists at ${SSH_KEY_PATH}"
else
  mkdir -p "${ACTUAL_HOME}/.ssh"
  chmod 700 "${ACTUAL_HOME}/.ssh"
  sudo -u "$ACTUAL_USER" ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N ""
  chmod 600 "${SSH_KEY_PATH}"
  chmod 644 "${SSH_KEY_PATH}.pub"
  chown "${ACTUAL_USER}:${ACTUAL_USER}" "${SSH_KEY_PATH}" "${SSH_KEY_PATH}.pub"
  pass "SSH key generated at ${SSH_KEY_PATH}"
fi

# =============================================================================
# PHASE 5 — FINAL VERIFICATION
# =============================================================================

echo ""
echo "============================================================"
echo " Phase 05 — Final Verification"
echo "============================================================"

step "Verifying environment"

# libvirtd running
systemctl is-active --quiet libvirtd \
  && pass "libvirtd: running" \
  || { fail "libvirtd: not running"; ERRORS=$((ERRORS + 1)); }

# virsh accessible
virsh version &>/dev/null \
  && pass "virsh: working ($(virsh version --short 2>/dev/null || echo ok))" \
  || { fail "virsh: not working"; ERRORS=$((ERRORS + 1)); }

# Storage pool active
POOL_STATE=$(virsh pool-info default 2>/dev/null | grep -i "^State" | awk '{print $2}')
if [ "$POOL_STATE" = "running" ] || [ "$POOL_STATE" = "active" ]; then
  pass "Storage pool: running"
else
  fail "Storage pool: not running (state=${POOL_STATE:-unknown})"
  ERRORS=$((ERRORS + 1))
fi

# QEMU user set to root
grep -qE '^user\s*=\s*"root"' /etc/libvirt/qemu.conf \
  && pass "QEMU user: root (permission issues prevented)" \
  || { fail "QEMU user: not set to root"; ERRORS=$((ERRORS + 1)); }

# Terraform installed
command -v terraform &>/dev/null \
  && pass "Terraform: $(terraform version | head -1)" \
  || { fail "Terraform: not found"; ERRORS=$((ERRORS + 1)); }

# SSH key exists
[ -f "${SSH_KEY_PATH}" ] \
  && pass "SSH key: ${SSH_KEY_PATH}" \
  || { fail "SSH key: not found at ${SSH_KEY_PATH}"; ERRORS=$((ERRORS + 1)); }

# --- Final result ---------------------------------------------------------

echo ""
echo "============================================================"

if [ "$ERRORS" -gt 0 ]; then
  fail "${ERRORS} verification(s) failed. Review errors above."
  exit 1
fi

echo -e "${GREEN}"
echo " Environment ready. Run terraform:"
echo -e "${NC}"
echo "   cd 01-qemu-virt"
echo "   terraform init"
echo "   terraform plan"
echo "   terraform apply"
echo ""
echo " After VMs are running, continue with:"
echo "   02-certs/certs.sh"
echo "============================================================"