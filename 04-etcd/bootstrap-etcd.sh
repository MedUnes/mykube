#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# etcd Bootstrap Script
# Runs on the VPS host. Generates configs locally, uploads them, then
# executes installation steps on control-plane-1 via SSH.
#
# Usage: ./bootstrap-apiserver.sh
# =============================================================================

# --- Environment -----------------------------------------------------------

CONTROL_PLANE_IP="10.0.0.4"
ETCD_NAME="control-plane-1"
ETCD_VERSION="3.6.8"

SSH_USER="adminuser"
SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${CONTROL_PLANE_IP}"
SCP="scp -i ${SSH_KEY} -o StrictHostKeyChecking=no"

CONFIGS_DIR="$(dirname "$0")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=============================================="
echo " etcd Bootstrap"
echo "=============================================="
echo " Target node  : ${CONTROL_PLANE_IP} (${ETCD_NAME})"
echo " etcd version : ${ETCD_VERSION}"
echo " Configs dir  : ${CONFIGS_DIR}"
echo "=============================================="
echo ""

# --- Step 1: Render etcd.service from template ----------------------------

echo "[+] Rendering etcd.service from template..."

export ETCD_NAME INTERNAL_IP="${CONTROL_PLANE_IP}"
envsubst < "${CONFIGS_DIR}/etcd.service.tpl" > "${TMP_DIR}/etcd.service"

echo "[+] Rendered etcd.service:"
echo "---"
cat "${TMP_DIR}/etcd.service"
echo "---"

# --- Step 2: Upload service file and certs --------------------------------

echo "[+] Uploading etcd.service to control-plane..."
$SCP "${TMP_DIR}/etcd.service" "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/etcd.service"

# --- Step 3: Download and install etcd binaries ---------------------------

echo "[+] Installing etcd v${ETCD_VERSION} on control-plane..."

$SSH "bash -s" << EOF
set -euo pipefail

ETCD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"

echo "[+] Downloading etcd..."
curl -fsSL "\$ETCD_URL" -o /tmp/etcd.tar.gz

echo "[+] Extracting binaries..."
tar -xzf /tmp/etcd.tar.gz -C /tmp/
sudo mv /tmp/etcd-v${ETCD_VERSION}-linux-amd64/etcd    /usr/local/bin/
sudo mv /tmp/etcd-v${ETCD_VERSION}-linux-amd64/etcdctl /usr/local/bin/
sudo chmod +x /usr/local/bin/etcd /usr/local/bin/etcdctl
rm -rf /tmp/etcd.tar.gz /tmp/etcd-v${ETCD_VERSION}-linux-amd64

echo "[+] etcd:    \$(etcd --version | head -1)"
echo "[+] etcdctl: \$(etcdctl version | head -1)"
EOF

# --- Step 4: Create directories and install certificates ------------------

echo "[+] Setting up /etc/etcd and installing certificates..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

sudo mkdir -p /etc/etcd /var/lib/etcd
sudo chmod 700 /var/lib/etcd

sudo cp ~/ca.pem       /etc/etcd/
sudo cp ~/etcd.pem     /etc/etcd/
sudo cp ~/etcd-key.pem /etc/etcd/

sudo chmod 644 /etc/etcd/ca.pem /etc/etcd/etcd.pem
sudo chmod 600 /etc/etcd/etcd-key.pem

echo "[+] Certificates in place:"
ls -la /etc/etcd/
EOF

# --- Step 5: Install and start the systemd service ------------------------

echo "[+] Installing and starting etcd systemd service..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

sudo mv /tmp/etcd.service /etc/systemd/system/etcd.service
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

sleep 3

if sudo systemctl is-active --quiet etcd; then
  echo "[+] etcd is running."
else
  echo "[!] etcd failed to start. Journal output:"
  sudo journalctl -u etcd --no-pager -n 40
  exit 1
fi
EOF

# --- Step 6: Verify cluster health ----------------------------------------

echo "[+] Verifying etcd cluster health..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

ETCDCTL="sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/etcd.pem \
  --key=/etc/etcd/etcd-key.pem"

echo "[+] Member list:"
$ETCDCTL member list

echo ""
echo "[+] Endpoint health:"
$ETCDCTL endpoint health
EOF

# --- Summary --------------------------------------------------------------

echo ""
echo "=============================================="
echo " etcd Bootstrap Complete"
echo "=============================================="
echo " Listening on : ${CONTROL_PLANE_IP}:2379 (clients)"
echo "              : ${CONTROL_PLANE_IP}:2380 (peers)"
echo " Data dir     : /var/lib/etcd"
echo " Certs        : /etc/etcd/"
echo " Service      : systemctl status etcd"
echo ""
echo " Next step: Bootstrap kube-apiserver"
echo "=============================================="