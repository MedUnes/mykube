#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# kube-apiserver Bootstrap Script
# Runs on the VPS host. Renders config locally, uploads, then executes
# installation steps on control-plane-1 via SSH.
#
# Usage: ./bootstrap-apiserver.sh
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
echo " kube-apiserver Bootstrap"
echo "=============================================="
echo " Target node   : ${CONTROL_PLANE_IP}"
echo " K8s version   : ${K8S_VERSION}"
echo "=============================================="
echo ""

# --- Step 1: Render kube-apiserver.service from template ------------------

echo "[+] Rendering kube-apiserver.service from template..."

export INTERNAL_IP="${CONTROL_PLANE_IP}"
envsubst < "${CONFIGS_DIR}/kube-apiserver.service.tpl" > "${TMP_DIR}/kube-apiserver.service"

echo "[+] Rendered kube-apiserver.service:"
echo "---"
cat "${TMP_DIR}/kube-apiserver.service"
echo "---"

# --- Step 2: Upload service file ------------------------------------------

echo "[+] Uploading kube-apiserver.service to control-plane..."
$SCP "${TMP_DIR}/kube-apiserver.service" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/kube-apiserver.service"

# --- Step 3: Download kube-apiserver binary -------------------------------

echo "[+] Installing kube-apiserver ${K8S_VERSION} on control-plane..."

$SSH "bash -s" << EOF
set -euo pipefail

echo "[+] Downloading kube-apiserver..."
curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-apiserver" \
  -o /tmp/kube-apiserver

sudo mv /tmp/kube-apiserver /usr/local/bin/kube-apiserver
sudo chmod +x /usr/local/bin/kube-apiserver

echo "[+] kube-apiserver version: \$(kube-apiserver --version)"
EOF

# --- Step 4: Create PKI directory and install certificates ----------------

echo "[+] Setting up /etc/kubernetes/pki and installing certificates..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

sudo mkdir -p /etc/kubernetes/pki

# These were distributed to ~/ by certs.sh
sudo cp ~/ca.pem                        /etc/kubernetes/pki/
sudo cp ~/ca-key.pem                    /etc/kubernetes/pki/
sudo cp ~/kubernetes.pem                /etc/kubernetes/pki/
sudo cp ~/kubernetes-key.pem            /etc/kubernetes/pki/
sudo cp ~/service-account.pem          /etc/kubernetes/pki/
sudo cp ~/service-account-key.pem      /etc/kubernetes/pki/
sudo cp ~/kube-controller-manager.pem  /etc/kubernetes/pki/
sudo cp ~/kube-controller-manager-key.pem /etc/kubernetes/pki/
sudo cp ~/kube-scheduler.pem           /etc/kubernetes/pki/
sudo cp ~/kube-scheduler-key.pem       /etc/kubernetes/pki/

# Lock down private keys
sudo chmod 600 /etc/kubernetes/pki/*-key.pem
sudo chmod 644 /etc/kubernetes/pki/*.pem

echo "[+] PKI directory contents:"
ls -la /etc/kubernetes/pki/
EOF

# --- Step 5: Install kubeconfigs ------------------------------------------

echo "[+] Installing kubeconfigs on control-plane..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

sudo mkdir -p /etc/kubernetes

sudo cp ~/kube-controller-manager.kubeconfig /etc/kubernetes/
sudo cp ~/kube-scheduler.kubeconfig          /etc/kubernetes/

echo "[+] Kubeconfigs installed:"
ls -la /etc/kubernetes/*.kubeconfig
EOF

# --- Step 6: Install and start the systemd service ------------------------

echo "[+] Installing and starting kube-apiserver systemd service..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

sudo mv /tmp/kube-apiserver.service /etc/systemd/system/kube-apiserver.service
sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver
sudo systemctl start kube-apiserver

sleep 5

if sudo systemctl is-active --quiet kube-apiserver; then
  echo "[+] kube-apiserver is running."
else
  echo "[!] kube-apiserver failed to start. Journal output:"
  sudo journalctl -u kube-apiserver --no-pager -n 40
  exit 1
fi
EOF

# --- Step 7: Verify apiserver is responding -------------------------------

echo "[+] Verifying kube-apiserver is responding..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

# Give it a moment to fully initialize
sleep 3

curl -sk \
  --cacert /etc/kubernetes/pki/ca.pem \
  --cert   /etc/kubernetes/pki/kubernetes.pem \
  --key    /etc/kubernetes/pki/kubernetes-key.pem \
  https://127.0.0.1:6443/version

echo ""
echo "[+] API server is responding."
EOF

# --- Summary --------------------------------------------------------------

echo ""
echo "=============================================="
echo " kube-apiserver Bootstrap Complete"
echo "=============================================="
echo " Listening on : ${CONTROL_PLANE_IP}:6443"
echo " PKI          : /etc/kubernetes/pki/"
echo " Kubeconfigs  : /etc/kubernetes/"
echo " Service      : systemctl status kube-apiserver"
echo ""
echo "=============================================="