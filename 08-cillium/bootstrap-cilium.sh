#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Cilium Bootstrap Script
# Installs Cilium CNI on the cluster via the cilium CLI.
# Runs on the VPS host, executes remotely on control-plane-1 via SSH.
#
# Cilium replaces kube-proxy entirely using eBPF.
# Must be run after all nodes are registered (kubectl get nodes shows NotReady).
#
# Usage: ./bootstrap-cilium.sh
# =============================================================================

# --- Environment -----------------------------------------------------------

CONTROL_PLANE_IP="10.0.0.4"
CILIUM_VERSION="1.19.1"
CILIUM_CLI_VERSION="v0.18.3"

SSH_USER="adminuser"
SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${CONTROL_PLANE_IP}"

echo "=============================================="
echo " Cilium Bootstrap"
echo "=============================================="
echo " Target        : ${CONTROL_PLANE_IP}"
echo " Cilium        : ${CILIUM_VERSION}"
echo " Cilium CLI    : ${CILIUM_CLI_VERSION}"
echo " Pod CIDR      : 10.200.0.0/16"
echo " kube-proxy    : replaced by Cilium eBPF"
echo "=============================================="
echo ""

# --- Step 1: Install cilium CLI on control-plane-1 ------------------------

echo "[+] Installing cilium CLI ${CILIUM_CLI_VERSION} on control-plane-1..."

$SSH "bash -s" << EOF
set -euo pipefail

curl -fsSL \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
  -o /tmp/cilium-cli.tar.gz

sudo tar -xzf /tmp/cilium-cli.tar.gz -C /usr/local/bin
sudo chmod +x /usr/local/bin/cilium
rm /tmp/cilium-cli.tar.gz

echo "[+] cilium CLI version: \$(cilium version --client)"
EOF

# --- Step 2: Install Cilium into the cluster ------------------------------

echo "[+] Installing Cilium ${CILIUM_VERSION}..."

$SSH "bash -s" << EOF
set -euo pipefail

cilium install \
  --version "${CILIUM_VERSION}" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${CONTROL_PLANE_IP}" \
  --set k8sServicePort=6443 \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.200.0.0/16" \
  --set ipam.operator.clusterPoolIPv4MaskSize=24

echo "[+] Cilium install command completed."
EOF

# --- Step 3: Wait for Cilium to be ready ----------------------------------

echo "[+] Waiting for Cilium pods to become ready (this may take 60-90s)..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

# Wait up to 3 minutes for Cilium DaemonSet to be ready
cilium status --wait --wait-duration 3m

echo "[+] Cilium is ready."
EOF

# --- Step 4: Verify nodes are Ready ---------------------------------------

echo "[+] Checking node status..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

echo "[+] Node status:"
kubectl get nodes -o wide

echo ""
echo "[+] Cilium pod status:"
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
EOF

# --- Step 5: Run Cilium connectivity test ---------------------------------

echo "[+] Running Cilium connectivity test..."
echo "    (this deploys test pods and verifies pod-to-pod networking)"
echo "    (may take 3-5 minutes)"
echo ""

$SSH "bash -s" << 'EOF'
set -euo pipefail

cilium connectivity test --test-namespace cilium-test 2>&1 | tail -20

echo ""
echo "[+] Connectivity test complete."
EOF

# --- Summary --------------------------------------------------------------

echo ""
echo "=============================================="
echo " Cilium Bootstrap Complete"
echo "=============================================="
echo " CNI          : Cilium ${CILIUM_VERSION}"
echo " kube-proxy   : replaced (eBPF)"
echo " Pod CIDR     : 10.200.0.0/16"
echo " IPAM         : cluster-pool (/24 per node)"
echo ""
echo " Verify from control-plane-1:"
echo "   kubectl get nodes -o wide"
echo "   cilium status"
echo ""
echo " Next step: Install CoreDNS"
echo "=============================================="
