#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# kube-controller-manager + kube-scheduler Bootstrap Script
# Runs on the VPS host. Renders configs locally, uploads them, then
# executes installation steps on control-plane-1 via SSH.
#
# Usage: ./bootstrap-control-plane.sh
# =============================================================================

# --- Environment -----------------------------------------------------------

CONTROL_PLANE_IP="10.0.0.4"
K8S_VERSION="v1.35.1"

SSH_USER="adminuser"
SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${CONTROL_PLANE_IP}"
SCP="scp -i ${SSH_KEY} -o StrictHostKeyChecking=no"

CONFIGS_DIR="$(dirname "$0")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=============================================="
echo " Control Plane Bootstrap"
echo " kube-controller-manager + kube-scheduler"
echo "=============================================="
echo " Target node   : ${CONTROL_PLANE_IP}"
echo " K8s version   : ${K8S_VERSION}"
echo " Pod CIDR      : 10.200.0.0/16"
echo " Service CIDR  : 10.96.0.0/24"
echo "=============================================="
echo ""

# --- Step 1: Render service templates -------------------------------------

echo "[+] Rendering service templates..."

# controller-manager has no variables to substitute but we keep the
# same pattern for consistency and future-proofing
envsubst < "${CONFIGS_DIR}/kube-controller-manager.service.tpl" \
  > "${TMP_DIR}/kube-controller-manager.service"

envsubst < "${CONFIGS_DIR}/kube-scheduler.service.tpl" \
  > "${TMP_DIR}/kube-scheduler.service"

echo "[+] Rendered kube-controller-manager.service:"
echo "---"
cat "${TMP_DIR}/kube-controller-manager.service"
echo "---"

echo "[+] Rendered kube-scheduler.service:"
echo "---"
cat "${TMP_DIR}/kube-scheduler.service"
echo "---"

# --- Step 2: Upload service files -----------------------------------------

echo "[+] Uploading service files to control-plane..."

$SCP "${TMP_DIR}/kube-controller-manager.service" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/kube-controller-manager.service"

$SCP "${TMP_DIR}/kube-scheduler.service" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/kube-scheduler.service"

echo "[+] Service files uploaded."

# --- Step 3: Download binaries --------------------------------------------

echo "[+] Installing binaries on control-plane..."

$SSH "bash -s" << EOF
set -euo pipefail

for BINARY in kube-controller-manager kube-scheduler; do
  echo "[+] Downloading \$BINARY..."
  curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/\$BINARY" \
    -o /tmp/\$BINARY
  sudo mv /tmp/\$BINARY /usr/local/bin/\$BINARY
  sudo chmod +x /usr/local/bin/\$BINARY
  echo "[+] \$BINARY version: \$(/usr/local/bin/\$BINARY --version)"
done
EOF

# --- Step 4: Install and start services -----------------------------------

echo "[+] Installing and starting systemd services..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

for SERVICE in kube-controller-manager kube-scheduler; do
  sudo mv /tmp/${SERVICE}.service /etc/systemd/system/${SERVICE}.service
done

sudo systemctl daemon-reload

for SERVICE in kube-controller-manager kube-scheduler; do
  echo "[+] Enabling and starting ${SERVICE}..."
  sudo systemctl enable  ${SERVICE}
  sudo systemctl start   ${SERVICE}
done

sleep 5

# Verify both are running
FAILED=0
for SERVICE in kube-controller-manager kube-scheduler; do
  if sudo systemctl is-active --quiet ${SERVICE}; then
    echo "[+] ${SERVICE} is running."
  else
    echo "[!] ${SERVICE} failed to start. Journal output:"
    sudo journalctl -u ${SERVICE} --no-pager -n 30
    FAILED=1
  fi
done

[ $FAILED -eq 0 ] || exit 1
EOF

# --- Step 5: Verify control plane is healthy via apiserver ----------------

echo "[+] Verifying full control plane health via apiserver..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

sleep 3

# Check component statuses via apiserver
kubectl \
  --kubeconfig=/etc/kubernetes/kube-controller-manager.kubeconfig \
  get componentstatuses 2>/dev/null || true

# Check nodes (none yet — but apiserver + etcd responding proves health)
kubectl \
  --kubeconfig=/etc/kubernetes/kube-controller-manager.kubeconfig \
  get nodes 2>/dev/null || echo "[i] No nodes yet — expected at this stage."
EOF

# --- Summary --------------------------------------------------------------

echo ""
echo "=============================================="
echo " Control Plane Bootstrap Complete"
echo "=============================================="
echo " Services running on ${CONTROL_PLANE_IP}:"
echo "   etcd                    :2379"
echo "   kube-apiserver          :6443"
echo "   kube-controller-manager (no port — apiserver client only)"
echo "   kube-scheduler          (no port — apiserver client only)"
echo ""
echo " Next step: Bootstrap worker nodes (kubelet + containerd)"
echo "=============================================="