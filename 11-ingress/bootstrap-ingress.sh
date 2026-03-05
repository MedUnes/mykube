#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# bootstrap-ingress.sh — nginx Ingress DaemonSet + VPS DNAT
#
# Usage:
#   export INGRESS_NODE=worker-node-1
#   export INGRESS_NODE_IP=10.0.0.36
#   ./bootstrap-ingress.sh
# =============================================================================

CONTROL_PLANE_IP="10.0.0.4"
SSH_USER="adminuser"
SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${CONTROL_PLANE_IP}"
SCP="scp -i ${SSH_KEY} -o StrictHostKeyChecking=no"

CONFIGS_DIR="$(dirname "$0")/configs"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INGRESS_NODE="${INGRESS_NODE:-worker-node-1}"
INGRESS_NODE_IP="${INGRESS_NODE_IP:-10.0.0.36}"

echo ""
echo "=============================================="
echo " Ingress Bootstrap"
echo "=============================================="
echo " Ingress node    : ${INGRESS_NODE} (${INGRESS_NODE_IP})"
echo " Control plane   : ${CONTROL_PLANE_IP}"
echo "=============================================="
echo ""

# --- Step 1: Create ingress namespace ----------------------------------------

echo "[1/6] Creating ingress namespace..."
$SSH "kubectl create namespace ingress --dry-run=client -o yaml | kubectl apply -f -"
echo "[+] ingress namespace ready."

# --- Step 2: Label ingress node ----------------------------------------------

echo ""
echo "[2/6] Labeling ${INGRESS_NODE} as ingress node..."
$SSH "kubectl label node ${INGRESS_NODE} ingress=true --overwrite"
echo "[+] Node ${INGRESS_NODE} labeled ingress=true"

# --- Step 3: Apply nginx ConfigMaps ------------------------------------------

echo ""
echo "[3/6] Applying nginx ConfigMaps..."
$SCP "${CONFIGS_DIR}/nginx-configmap.yaml" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/nginx-configmap.yaml"
$SSH "kubectl apply -f /tmp/nginx-configmap.yaml && rm /tmp/nginx-configmap.yaml"
echo "[+] nginx ConfigMaps applied."
$SSH "kubectl get configmap -n ingress"

# --- Step 4: Render and apply DaemonSet --------------------------------------

echo ""
echo "[4/6] Deploying nginx DaemonSet on ${INGRESS_NODE}..."
export INGRESS_NODE
envsubst '${INGRESS_NODE}' \
  < "${CONFIGS_DIR}/nginx-daemonset.yaml.tpl" \
  > "${TMP_DIR}/nginx-daemonset.yaml"

$SCP "${TMP_DIR}/nginx-daemonset.yaml" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/nginx-daemonset.yaml"
$SSH "kubectl apply -f /tmp/nginx-daemonset.yaml && rm /tmp/nginx-daemonset.yaml"

echo "[+] Waiting for nginx DaemonSet to be ready..."
$SSH "kubectl rollout status daemonset/nginx-ingress -n ingress --timeout=120s"
echo "[+] nginx pods:"
$SSH "kubectl get pods -n ingress -o wide"

# --- Step 5: Apply reload CronJob --------------------------------------------

echo ""
echo "[5/6] Applying nginx-reload CronJob..."
$SCP "${CONFIGS_DIR}/nginx-reload-cronjob.yaml" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/nginx-reload-cronjob.yaml"
$SSH "kubectl apply -f /tmp/nginx-reload-cronjob.yaml && rm /tmp/nginx-reload-cronjob.yaml"
echo "[+] nginx-reload CronJob applied."

# --- Step 6: Configure VPS DNAT ----------------------------------------------

echo ""
echo "[6/6] Configuring VPS DNAT forwarding → ${INGRESS_NODE_IP}..."

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
echo "[+] IP forwarding enabled."

# Detect public-facing interface
PUBLIC_IFACE=$(ip route get 8.8.8.8 | grep -oP '(?<=dev )\S+' | head -1)
echo "[+] Public interface: ${PUBLIC_IFACE}"

# Add DNAT rules — idempotent
add_dnat() {
  local PORT="$1"
  if ! sudo iptables -t nat -C PREROUTING \
      -i "${PUBLIC_IFACE}" -p tcp --dport "${PORT}" \
      -j DNAT --to-destination "${INGRESS_NODE_IP}:${PORT}" 2>/dev/null; then
    sudo iptables -t nat -A PREROUTING \
      -i "${PUBLIC_IFACE}" -p tcp --dport "${PORT}" \
      -j DNAT --to-destination "${INGRESS_NODE_IP}:${PORT}"
    echo "[+] DNAT added: :${PORT} → ${INGRESS_NODE_IP}:${PORT}"
  else
    echo "[=] DNAT already exists: :${PORT} → ${INGRESS_NODE_IP}:${PORT}"
  fi
}

add_forward() {
  local PORT="$1"
  if ! sudo iptables -C FORWARD \
      -p tcp -d "${INGRESS_NODE_IP}" --dport "${PORT}" -j ACCEPT 2>/dev/null; then
    # INSERT at position 1 — Docker appends a DROP rule that would block us
    sudo iptables -I FORWARD 1 \
      -p tcp -d "${INGRESS_NODE_IP}" --dport "${PORT}" -j ACCEPT
    echo "[+] FORWARD added: tcp:${PORT} → ${INGRESS_NODE_IP}"
  else
    echo "[=] FORWARD already exists: tcp:${PORT} → ${INGRESS_NODE_IP}"
  fi
}

add_dnat 80
add_dnat 443
add_forward 80
add_forward 443

# MASQUERADE — SNAT return traffic so replies go back through the VPS.
# Without this, the worker node replies directly to the internet client
# using its private IP (10.0.0.x) as source. The client only knows the
# VPS public IP and drops the reply — connection hangs.
add_masquerade() {
  local PORT="$1"
  if ! sudo iptables -t nat -C POSTROUTING       -p tcp -d "${INGRESS_NODE_IP}" --dport "${PORT}"       -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING       -p tcp -d "${INGRESS_NODE_IP}" --dport "${PORT}"       -j MASQUERADE
    echo "[+] MASQUERADE added: tcp:${PORT} → ${INGRESS_NODE_IP}"
  else
    echo "[=] MASQUERADE already exists: tcp:${PORT} → ${INGRESS_NODE_IP}"
  fi
}

add_masquerade 80
add_masquerade 443

# Persist rules
if ! command -v netfilter-persistent &>/dev/null; then
  echo "[+] Installing iptables-persistent..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
fi
sudo netfilter-persistent save
echo "[+] iptables rules persisted."

# --- Verify ------------------------------------------------------------------

echo ""
echo "[+] Verification:"
echo "    DNAT rules:"
sudo iptables -t nat -L PREROUTING -n --line-numbers | grep -E "80|443" || true
echo "    nginx pod:"
$SSH "kubectl get pods -n ingress -o wide"

echo ""
echo "=============================================="
echo " Ingress Bootstrap Complete"
echo "=============================================="
echo " nginx node : ${INGRESS_NODE} (${INGRESS_NODE_IP})"
echo " VPS DNAT   : :80  → ${INGRESS_NODE_IP}:80"
echo "             :443 → ${INGRESS_NODE_IP}:443"
echo ""
echo " Next: add your first site:"
echo "   ./new-site.sh --template proxy-pass \\"
echo "     --domain app.yourdomain.com \\"
echo "     --service my-app --namespace default --port 80"
echo "=============================================="