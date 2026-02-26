#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Kubernetes Kubeconfig Generator
# - All component kubeconfigs point to internal API server (10.0.0.4:6443)
# - Admin kubeconfig points to 127.0.0.1:6443 (used via SSH tunnel)
# - Nothing is exposed to the public internet
# Run this on the VPS host.
# =============================================================================

# --- Detect environment dynamically ---------------------------------------

CONTROL_PLANE_IP="10.0.0.4"
WORKER_1_IP="10.0.0.36"
WORKER_2_IP="10.0.0.37"
WORKER_1_HOST="worker-node-1"
WORKER_2_HOST="worker-node-2"

# Internal API server address — used by all cluster components
INTERNAL_API="https://${CONTROL_PLANE_IP}:6443"

# Tunnel address — used only by admin kubectl (via SSH tunnel on your laptop)
TUNNEL_API="https://127.0.0.1:6443"

SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
SSH_USER="adminuser"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

CERT_DIR="$HOME/k8s-pki"
KUBECONFIG_DIR="$HOME/k8s-kubeconfigs"
mkdir -p "$KUBECONFIG_DIR"
cd "$CERT_DIR"

echo "=============================================="
echo " Kubernetes Kubeconfig Generator"
echo "=============================================="
echo " Internal API server : $INTERNAL_API"
echo " Admin tunnel API    : $TUNNEL_API"
echo " Certs dir           : $CERT_DIR"
echo " Output dir          : $KUBECONFIG_DIR"
echo "=============================================="
echo ""

# --- Helper: generate one kubeconfig --------------------------------------
# Usage: make_kubeconfig <output_file> <api_server> <ca> <cert> <key> <user>

make_kubeconfig() {
  local OUTPUT="$1"
  local API_SERVER="$2"
  local CA="$3"
  local CERT="$4"
  local KEY="$5"
  local USER="$6"

  kubectl config set-cluster kubernetes \
    --certificate-authority="$CA" \
    --embed-certs=true \
    --server="$API_SERVER" \
    --kubeconfig="$OUTPUT"

  kubectl config set-credentials "$USER" \
    --client-certificate="$CERT" \
    --client-key="$KEY" \
    --embed-certs=true \
    --kubeconfig="$OUTPUT"

  kubectl config set-context default \
    --cluster=kubernetes \
    --user="$USER" \
    --kubeconfig="$OUTPUT"

  kubectl config use-context default \
    --kubeconfig="$OUTPUT"

  echo "[+] Generated: $(basename $OUTPUT)"
}

# --- 1. kubelet kubeconfigs (one per worker node) -------------------------

echo "[+] Generating kubelet kubeconfigs..."

make_kubeconfig \
  "$KUBECONFIG_DIR/${WORKER_1_HOST}.kubeconfig" \
  "$INTERNAL_API" \
  "$CERT_DIR/ca.pem" \
  "$CERT_DIR/${WORKER_1_HOST}.pem" \
  "$CERT_DIR/${WORKER_1_HOST}-key.pem" \
  "system:node:${WORKER_1_HOST}"

make_kubeconfig \
  "$KUBECONFIG_DIR/${WORKER_2_HOST}.kubeconfig" \
  "$INTERNAL_API" \
  "$CERT_DIR/ca.pem" \
  "$CERT_DIR/${WORKER_2_HOST}.pem" \
  "$CERT_DIR/${WORKER_2_HOST}-key.pem" \
  "system:node:${WORKER_2_HOST}"

# --- 2. kube-controller-manager kubeconfig --------------------------------

echo "[+] Generating kube-controller-manager kubeconfig..."

make_kubeconfig \
  "$KUBECONFIG_DIR/kube-controller-manager.kubeconfig" \
  "$INTERNAL_API" \
  "$CERT_DIR/ca.pem" \
  "$CERT_DIR/kube-controller-manager.pem" \
  "$CERT_DIR/kube-controller-manager-key.pem" \
  "system:kube-controller-manager"

# --- 3. kube-scheduler kubeconfig -----------------------------------------

echo "[+] Generating kube-scheduler kubeconfig..."

make_kubeconfig \
  "$KUBECONFIG_DIR/kube-scheduler.kubeconfig" \
  "$INTERNAL_API" \
  "$CERT_DIR/ca.pem" \
  "$CERT_DIR/kube-scheduler.pem" \
  "$CERT_DIR/kube-scheduler-key.pem" \
  "system:kube-scheduler"

# --- 4. admin kubeconfig --------------------------------------------------
# Points to 127.0.0.1:6443 — only works via SSH tunnel from your laptop.
# Never exposes the API server to the public internet.

echo "[+] Generating admin kubeconfig (tunnel-based)..."

make_kubeconfig \
  "$KUBECONFIG_DIR/admin.kubeconfig" \
  "$TUNNEL_API" \
  "$CERT_DIR/ca.pem" \
  "$CERT_DIR/admin.pem" \
  "$CERT_DIR/admin-key.pem" \
  "admin"

# --- Distribute kubeconfigs to nodes --------------------------------------

echo ""
echo "[+] Distributing kubeconfigs to nodes..."

# Worker nodes get their own kubelet kubeconfig
for i in \
  "$WORKER_1_HOST:$WORKER_1_IP" \
  "$WORKER_2_HOST:$WORKER_2_IP"; do

  HOST="${i%%:*}"
  IP="${i##*:}"

  echo "[+] Copying kubeconfig to $HOST ($IP)..."
  scp $SSH_OPTS \
    "$KUBECONFIG_DIR/${HOST}.kubeconfig" \
    "${SSH_USER}@${IP}:~/"
done

# Control plane gets controller-manager and scheduler kubeconfigs
echo "[+] Copying kubeconfigs to control-plane ($CONTROL_PLANE_IP)..."
scp $SSH_OPTS \
  "$KUBECONFIG_DIR/kube-controller-manager.kubeconfig" \
  "$KUBECONFIG_DIR/kube-scheduler.kubeconfig" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:~/"

# --- Copy admin kubeconfig to VPS host for local use ----------------------

mkdir -p "$HOME/.kube"
cp "$KUBECONFIG_DIR/admin.kubeconfig" "$HOME/.kube/config"
echo "[+] Admin kubeconfig copied to ~/.kube/config"

# --- Summary --------------------------------------------------------------

echo ""
echo "=============================================="
echo " Kubeconfig Generation Complete"
echo "=============================================="
echo " Generated files:"
ls -1 "$KUBECONFIG_DIR/"
echo ""
echo " Admin kubectl usage (from your laptop):"
echo ""
echo "   1. Open SSH tunnel:"
echo "      ssh -L 6443:${CONTROL_PLANE_IP}:6443 -N -i ~/.ssh/id_rsa_k8s_vm ${SSH_USER}@<VPS_PUBLIC_IP>"
echo ""
echo "   2. Copy admin kubeconfig to your laptop:"
echo "      scp -i ~/.ssh/id_rsa_k8s_vm ${SSH_USER}@<VPS_PUBLIC_IP>:~/k8s-kubeconfigs/admin.kubeconfig ~/.kube/config"
echo ""
echo "   3. Then use kubectl normally:"
echo "      kubectl get nodes"
echo ""
echo "=============================================="