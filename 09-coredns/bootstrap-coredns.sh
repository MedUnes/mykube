#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CoreDNS Bootstrap Script
# Deploys CoreDNS into the cluster via raw Kubernetes manifests.
# Runs on the VPS host, applies manifests remotely on control-plane-1 via SSH.
#
# Static manifests are scp'd directly.
# The deployment manifest is rendered via envsubst (contains COREDNS_VERSION).
#
# Usage: ./bootstrap-coredns.sh
# =============================================================================

# --- Environment -----------------------------------------------------------

CONTROL_PLANE_IP="10.0.0.4"
COREDNS_VERSION="1.12.0"

SSH_USER="adminuser"
SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${CONTROL_PLANE_IP}"
SCP="scp -i ${SSH_KEY} -o StrictHostKeyChecking=no"

CONFIGS_DIR="$(dirname "$0")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=============================================="
echo " CoreDNS Bootstrap"
echo "=============================================="
echo " Target        : ${CONTROL_PLANE_IP}"
echo " CoreDNS       : ${COREDNS_VERSION}"
echo " ClusterDNS IP : 10.96.0.10"
echo " Upstream DNS  : 8.8.8.8"
echo " Replicas      : 2"
echo "=============================================="
echo ""

# --- Step 1: Render templated manifest ------------------------------------

echo "[+] Rendering coredns-deployment.yaml from template..."

export COREDNS_VERSION
envsubst < "${CONFIGS_DIR}/coredns-deployment.yaml.tpl" \
  > "${TMP_DIR}/coredns-deployment.yaml"

echo "[+] Rendered coredns-deployment.yaml:"
echo "---"
cat "${TMP_DIR}/coredns-deployment.yaml"
echo "---"

# --- Step 2: Upload all manifests -----------------------------------------

echo "[+] Uploading manifests to control-plane-1..."

# Static manifests — scp directly from configs/
for MANIFEST in \
  coredns-configmap.yaml \
  coredns-serviceaccount.yaml \
  coredns-clusterrole.yaml \
  coredns-clusterrolebinding.yaml \
  coredns-service.yaml; do
  $SCP "${CONFIGS_DIR}/${MANIFEST}" \
    "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/${MANIFEST}"
done

# Rendered manifest — scp from tmp/
$SCP "${TMP_DIR}/coredns-deployment.yaml" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/coredns-deployment.yaml"

echo "[+] All manifests uploaded."

# --- Step 3: Apply manifests ----------------------------------------------

echo "[+] Applying CoreDNS manifests..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

for MANIFEST in \
  coredns-configmap.yaml \
  coredns-serviceaccount.yaml \
  coredns-clusterrole.yaml \
  coredns-clusterrolebinding.yaml \
  coredns-deployment.yaml \
  coredns-service.yaml; do
  echo "[+] Applying ${MANIFEST}..."
  kubectl apply -f /tmp/${MANIFEST}
  rm /tmp/${MANIFEST}
done

echo "[+] All manifests applied."
EOF

# --- Step 4: Wait for CoreDNS to be ready ---------------------------------

echo "[+] Waiting for CoreDNS deployment to roll out..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

kubectl rollout status deployment/coredns -n kube-system --timeout=120s

echo ""
echo "[+] CoreDNS pods:"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide

echo ""
echo "[+] CoreDNS service:"
kubectl get svc -n kube-system kube-dns
EOF

# --- Step 5: Verify DNS resolution ----------------------------------------

echo "[+] Verifying DNS resolution with a test pod..."

$SSH "bash -s" << 'EOF'
set -euo pipefail

kubectl run dns-test \
  --image=busybox:1.28 \
  --restart=Never \
  --rm \
  -it \
  -- nslookup kubernetes.default 2>/dev/null || true

echo "[+] DNS test complete."
EOF

# --- Summary --------------------------------------------------------------

echo ""
echo "=============================================="
echo " CoreDNS Bootstrap Complete"
echo "=============================================="
echo " Deployment  : coredns (2 replicas)"
echo " Service     : kube-dns @ 10.96.0.10"
echo " Upstream    : 8.8.8.8"
echo " Domain      : cluster.local"
echo ""
echo " To change upstream DNS later (no restart needed):"
echo "   kubectl edit configmap coredns -n kube-system"
echo "   change: forward . 8.8.8.8"
echo "   to any upstream — CoreDNS reloads automatically."
echo ""
echo " Next step: Full cluster verification"
echo "=============================================="
