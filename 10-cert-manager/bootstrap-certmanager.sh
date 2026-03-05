#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# bootstrap-certmanager.sh
#
# 1. Installs cert-manager into the cluster
# 2. Creates ClusterIssuers (staging + production)
# 3. Applies acme-solver Service (stable ClusterIP for ACME challenge proxy)
# 4. Applies kubelet-api-admin ClusterRoleBinding (enables kubectl logs/exec)
#
# Usage:
#   export ACME_EMAIL=you@yourdomain.com
#   export CHALLENGE_TYPE=http01        # or dns01-cloudflare / dns01-webhook
#   ./bootstrap-certmanager.sh
# =============================================================================

CONTROL_PLANE_IP="10.0.0.4"
CERTMANAGER_VERSION="v1.17.1"
SSH_USER="adminuser"
SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${CONTROL_PLANE_IP}"
SCP="scp -i ${SSH_KEY} -o StrictHostKeyChecking=no"

CONFIGS_DIR="$(dirname "$0")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CHALLENGE_TYPE="${CHALLENGE_TYPE:-http01}"
ACME_EMAIL="${ACME_EMAIL:-}"

if [[ -z "${ACME_EMAIL}" ]]; then
  echo "[!] ACME_EMAIL is not set."
  echo "    export ACME_EMAIL=you@yourdomain.com"
  exit 1
fi

if [[ "${CHALLENGE_TYPE}" == "dns01-cloudflare" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "[!] CLOUDFLARE_API_TOKEN required for dns01-cloudflare."
  exit 1
fi

echo "=============================================="
echo " cert-manager Bootstrap"
echo "=============================================="
echo " Target       : ${CONTROL_PLANE_IP}"
echo " cert-manager : ${CERTMANAGER_VERSION}"
echo " ACME email   : ${ACME_EMAIL}"
echo " Challenge    : ${CHALLENGE_TYPE}"
echo "=============================================="
echo ""

# --- Step 1: Install cert-manager -------------------------------------------

echo "[1/4] Installing cert-manager ${CERTMANAGER_VERSION}..."
$SSH "kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERTMANAGER_VERSION}/cert-manager.yaml"
echo "[+] Waiting for cert-manager pods..."
$SSH "kubectl rollout status deployment/cert-manager            -n cert-manager --timeout=120s"
$SSH "kubectl rollout status deployment/cert-manager-webhook    -n cert-manager --timeout=120s"
$SSH "kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=120s"
echo "[+] cert-manager pods:"
$SSH "kubectl get pods -n cert-manager"

# --- Step 2: Cloudflare Secret (dns01-cloudflare only) ----------------------

if [[ "${CHALLENGE_TYPE}" == "dns01-cloudflare" ]]; then
  echo ""
  echo "[+] Creating Cloudflare API token Secret..."
  $SSH "kubectl create secret generic cloudflare-api-token \
    --namespace cert-manager \
    --from-literal=api-token=${CLOUDFLARE_API_TOKEN} \
    --dry-run=client -o yaml | kubectl apply -f -"
fi

# --- Step 3: ClusterIssuers -------------------------------------------------

echo ""
echo "[2/4] Applying ClusterIssuers (${CHALLENGE_TYPE})..."
export ACME_EMAIL
envsubst < "${CONFIGS_DIR}/clusterissuer-${CHALLENGE_TYPE}.yaml.tpl" \
  > "${TMP_DIR}/clusterissuers.yaml"
$SCP "${TMP_DIR}/clusterissuers.yaml" "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/clusterissuers.yaml"
$SSH "kubectl apply -f /tmp/clusterissuers.yaml && rm /tmp/clusterissuers.yaml"
echo "[+] ClusterIssuers applied:"
$SSH "kubectl get clusterissuers"

# --- Step 4: acme-solver Service + kubelet-api-admin binding ----------------

echo ""
echo "[3/4] Applying acme-solver Service..."
$SCP "${CONFIGS_DIR}/acme-solver-service.yaml" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/acme-solver-service.yaml"
$SSH "kubectl apply -f /tmp/acme-solver-service.yaml && rm /tmp/acme-solver-service.yaml"
echo "[+] acme-solver Service applied."

echo ""
echo "[4/4] Applying kubelet-api-admin ClusterRoleBinding..."
$SSH "kubectl apply -f - << 'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-apiserver-kubelet-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kubelet-api-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: kubernetes
YAML"
echo "[+] kubelet-api-admin binding applied — kubectl logs/exec now work."

# --- Verify -----------------------------------------------------------------

echo ""
echo "[+] Verifying..."
sleep 5
$SSH "kubectl get clusterissuers -o wide"
$SSH "kubectl get svc acme-solver -n cert-manager"
$SSH "kubectl get clusterrolebinding kube-apiserver-kubelet-admin"

echo ""
echo "=============================================="
echo " cert-manager Bootstrap Complete"
echo "=============================================="
echo " cert-manager : ${CERTMANAGER_VERSION}"
echo " Challenge    : ${CHALLENGE_TYPE}"
echo " Issuers      : letsencrypt-staging"
echo "                letsencrypt-production"
echo ""
echo " Next: run 11-ingress/bootstrap-ingress.sh"
echo "=============================================="