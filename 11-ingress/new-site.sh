#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# new-site.sh — Add a new site to the nginx ingress DaemonSet
#
# Full lifecycle for a new domain:
#   1.  Request STAGING cert — validates ACME plumbing, no rate limit cost
#   2.  Wait for staging cert
#   3.  Delete staging cert + secret
#   4.  Request PRODUCTION cert
#   5.  Wait for production cert
#   6.  Patch nginx DaemonSet to mount the cert Secret as a volume
#   7.  Render site config from template → add to nginx-sites ConfigMap
#   8.  Trigger nginx reload in the ingress pod
#   9.  Verify HTTPS responds
#
# Certs live as Kubernetes Secrets and are mounted directly into the nginx pod.
# No cert-sync. No files on the VPS. Renewals are picked up automatically
# via the nginx-reload CronJob (runs every 12h).
#
# Usage:
#   ./new-site.sh --template proxy-pass \
#     --domain api.yourdomain.com \
#     --service my-api --namespace default --port 8000
#
#   ./new-site.sh --template static-files \
#     --domain www.yourdomain.com \
#     --webroot /var/www/mysite
#
#   ./new-site.sh --remove --domain api.yourdomain.com
# =============================================================================

TEMPLATES_DIR="$(dirname "$0")/templates"
CONTROL_PLANE_IP="10.0.0.4"
SSH_USER="adminuser"
SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${CONTROL_PLANE_IP}"

CERT_NAMESPACE="ingress"  # Secrets must be in same namespace as the nginx pod
INGRESS_NAMESPACE="ingress"
CERT_TIMEOUT=300
CERT_POLL=5

# --- Defaults ----------------------------------------------------------------

TEMPLATE=""
DOMAIN=""
SERVICE_NAME=""
NAMESPACE="default"
SERVICE_PORT="80"
WEBROOT=""
REMOVE=false

# --- Helpers -----------------------------------------------------------------

usage() {
  cat << EOF
Usage: $0 --template <n> --domain <domain> [options]

Required:
  --template     proxy-pass | static-files
  --domain       Public domain (e.g. api.yourdomain.com)

proxy-pass only:
  --service      Kubernetes Service name
  --namespace    Kubernetes namespace (default: default)
  --port         Service port (default: 80)

static-files only:
  --webroot      Absolute path on ingress node (e.g. /var/www/mysite)

Other:
  --remove       Remove site and all associated resources
EOF
  exit 1
}

slug()     { echo "${1//./-}"; }
sitename() { echo "${1//./_}"; }

wait_for_cert() {
  local CERT_NAME="$1"
  local SECRET_NAME="$2"
  local LABEL="$3"
  local ELAPSED=0

  echo "[+] Waiting for ${LABEL} certificate (timeout: ${CERT_TIMEOUT}s)..."

  while [[ ${ELAPSED} -lt ${CERT_TIMEOUT} ]]; do
    SECRET_DATA=$(${SSH} "kubectl get secret ${SECRET_NAME} \
      -n ${CERT_NAMESPACE} \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null" || echo "")

    if [[ -n "${SECRET_DATA}" && "${SECRET_DATA}" != "null" ]]; then
      echo "[+] ${LABEL} certificate issued."
      return 0
    fi

    ISSUING=$(${SSH} "kubectl get certificate ${CERT_NAME} \
      -n ${CERT_NAMESPACE} \
      -o jsonpath='{.status.conditions[?(@.type==\"Issuing\")].reason}' \
      2>/dev/null" || echo "unknown")
    READY=$(${SSH} "kubectl get certificate ${CERT_NAME} \
      -n ${CERT_NAMESPACE} \
      -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].reason}' \
      2>/dev/null" || echo "unknown")

    printf "    ... %3ds | issuing: %s | ready: %s\n" \
      "${ELAPSED}" "${ISSUING}" "${READY}"

    sleep ${CERT_POLL}
    ELAPSED=$((ELAPSED + CERT_POLL))
  done

  echo "[!] Timed out after ${CERT_TIMEOUT}s waiting for ${LABEL} cert."
  echo "    Diagnose: ${SSH} kubectl describe challenge -n ${CERT_NAMESPACE}"
  return 1
}

# --- Argument parsing --------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template)  TEMPLATE="$2";      shift 2 ;;
    --domain)    DOMAIN="$2";        shift 2 ;;
    --service)   SERVICE_NAME="$2";  shift 2 ;;
    --namespace) NAMESPACE="$2";     shift 2 ;;
    --port)      SERVICE_PORT="$2";  shift 2 ;;
    --webroot)   WEBROOT="$2";       shift 2 ;;
    --remove)    REMOVE=true;        shift   ;;
    --help|-h)   usage ;;
    *) echo "[!] Unknown argument: $1"; usage ;;
  esac
done

[[ -z "${DOMAIN}" ]] && { echo "[!] --domain is required."; usage; }

SLUG=$(slug "${DOMAIN}")
SITE_NAME=$(sitename "${DOMAIN}")

STAGING_CERT="${SLUG}-staging"
STAGING_SECRET="${SLUG}-staging-tls"
PROD_CERT="${SLUG}"
PROD_SECRET="${SLUG}-tls"

# =============================================================================
# REMOVE
# =============================================================================

if [[ "${REMOVE}" == "true" ]]; then
  echo ""
  echo "=============================================="
  echo " Removing: ${DOMAIN}"
  echo "=============================================="

  # Remove site config from nginx-sites ConfigMap
  ${SSH} "bash -s" << EOF
set -euo pipefail

# Remove key from nginx-sites ConfigMap
if kubectl get configmap nginx-sites -n ${INGRESS_NAMESPACE} &>/dev/null; then
  kubectl patch configmap nginx-sites -n ${INGRESS_NAMESPACE} \
    --type=json \
    -p='[{"op":"remove","path":"/data/${SITE_NAME}.conf"}]' 2>/dev/null || true
  echo "[+] Removed ${SITE_NAME}.conf from nginx-sites ConfigMap."
fi

# Remove cert volume + volumeMount from DaemonSet
PATCH=\$(cat << 'JSONEOF'
[
  {"op":"remove","path":"/spec/template/spec/volumes/$(
    kubectl get daemonset nginx-ingress -n ingress \
      -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' \
      | grep -n "^cert-${SLUG}$" | cut -d: -f1 | awk '{print \$1-1}'
  )"},
  {"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts/$(
    kubectl get daemonset nginx-ingress -n ingress \
      -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}{"\n"}{end}' \
      | grep -n "^cert-${SLUG}$" | cut -d: -f1 | awk '{print \$1-1}'
  )"}
]
JSONEOF
)
kubectl patch daemonset nginx-ingress -n ${INGRESS_NAMESPACE} \
  --type=json -p="\${PATCH}" 2>/dev/null || true
echo "[+] Cert volume removed from DaemonSet."

# Delete cert and secret
kubectl delete certificate ${PROD_CERT}    -n ${CERT_NAMESPACE} --ignore-not-found
kubectl delete certificate ${STAGING_CERT} -n ${CERT_NAMESPACE} --ignore-not-found
kubectl delete secret      ${PROD_SECRET}  -n ${CERT_NAMESPACE} --ignore-not-found
echo "[+] Certificate and Secret deleted."

# Reload nginx
POD=\$(kubectl get pod -n ${INGRESS_NAMESPACE} -l app=nginx-ingress \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ${INGRESS_NAMESPACE} \${POD} -- nginx -s reload
echo "[+] nginx reloaded."
EOF

  echo "[+] Site ${DOMAIN} removed."
  exit 0
fi

# =============================================================================
# CREATE
# =============================================================================

[[ -z "${TEMPLATE}" ]] && { echo "[!] --template is required."; usage; }

TPL_FILE="${TEMPLATES_DIR}/${TEMPLATE}.conf.tpl"
[[ ! -f "${TPL_FILE}" ]] && { echo "[!] Template not found: ${TPL_FILE}"; exit 1; }

if [[ "${TEMPLATE}" == "proxy-pass" ]]; then
  [[ -z "${SERVICE_NAME}" ]] && { echo "[!] --service required for proxy-pass."; exit 1; }
fi
if [[ "${TEMPLATE}" == "static-files" ]]; then
  [[ -z "${WEBROOT}" ]] && { echo "[!] --webroot required for static-files."; exit 1; }
fi

echo ""
echo "=============================================="
echo " new-site.sh"
echo "=============================================="
echo " Template  : ${TEMPLATE}"
echo " Domain    : ${DOMAIN}"
echo " Slug      : ${SLUG}"
if [[ "${TEMPLATE}" == "proxy-pass" ]]; then
echo " Upstream  : ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:${SERVICE_PORT}"
fi
if [[ "${TEMPLATE}" == "static-files" ]]; then
echo " Webroot   : ${WEBROOT} (on ingress node)"
fi
echo " Cert flow : staging → production → volume mount → nginx live"
echo "=============================================="
echo ""

# --- Step 1: Staging cert ----------------------------------------------------

echo "[1/6] Requesting STAGING cert for ${DOMAIN}..."

${SSH} "bash -s" << EOF
set -euo pipefail
cat << YAML | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${STAGING_CERT}
  namespace: ${CERT_NAMESPACE}
spec:
  secretName: ${STAGING_SECRET}
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
  dnsNames:
    - ${DOMAIN}
YAML
echo "[+] Staging Certificate created."
EOF

# --- Step 2: Wait for staging ------------------------------------------------

echo ""
echo "[2/6] Waiting for staging cert..."
if ! wait_for_cert "${STAGING_CERT}" "${STAGING_SECRET}" "staging"; then
  echo "[!] Staging failed — aborting. Production cert NOT requested."
  ${SSH} "kubectl delete certificate ${STAGING_CERT} -n ${CERT_NAMESPACE} --ignore-not-found || true"
  ${SSH} "kubectl delete secret ${STAGING_SECRET} -n ${CERT_NAMESPACE} --ignore-not-found || true"
  exit 1
fi

# --- Step 3: Delete staging --------------------------------------------------

echo ""
echo "[3/6] Staging succeeded — deleting staging resources..."
${SSH} "bash -s" << EOF
kubectl delete certificate ${STAGING_CERT} -n ${CERT_NAMESPACE} --ignore-not-found
kubectl delete secret      ${STAGING_SECRET} -n ${CERT_NAMESPACE} --ignore-not-found
echo "[+] Staging resources deleted."
EOF

# --- Step 4: Production cert -------------------------------------------------

echo ""
echo "[4/6] Requesting PRODUCTION cert for ${DOMAIN}..."
${SSH} "bash -s" << EOF
set -euo pipefail
cat << YAML | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${PROD_CERT}
  namespace: ${CERT_NAMESPACE}
spec:
  secretName: ${PROD_SECRET}
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - ${DOMAIN}
YAML
echo "[+] Production Certificate created."
EOF

echo ""
echo "[4/6] Waiting for production cert..."
if ! wait_for_cert "${PROD_CERT}" "${PROD_SECRET}" "production"; then
  echo "[!] Production cert failed."
  echo "    Staging worked so ACME plumbing is confirmed good."
  echo "    Most likely: Let's Encrypt rate limit. Wait 1h and rerun."
  exit 1
fi

# --- Step 5: Mount cert into DaemonSet ---------------------------------------

echo ""
echo "[5/6] Mounting cert Secret into nginx DaemonSet..."

${SSH} "bash -s" << EOF
set -euo pipefail

# Check if volume already mounted (idempotent)
EXISTING=\$(kubectl get daemonset nginx-ingress -n ${INGRESS_NAMESPACE} \
  -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null || echo "")

if echo "\${EXISTING}" | grep -qw "cert-${SLUG}"; then
  echo "[=] Volume cert-${SLUG} already mounted — skipping patch."
else
  # Add volume (cert Secret) and volumeMount to the DaemonSet
  kubectl patch daemonset nginx-ingress -n ${INGRESS_NAMESPACE} \
    --type=json -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/volumes/-",
        "value": {
          "name": "cert-${SLUG}",
          "secret": {
            "secretName": "${PROD_SECRET}"
          }
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "name": "cert-${SLUG}",
          "mountPath": "/etc/nginx/certs/${DOMAIN}",
          "readOnly": true
        }
      }
    ]'
  echo "[+] Cert volume mounted at /etc/nginx/certs/${DOMAIN}"
fi

echo "[+] Waiting for DaemonSet rollout..."
kubectl rollout status daemonset/nginx-ingress -n ${INGRESS_NAMESPACE} --timeout=120s
EOF

# --- Step 6: Add site config + reload ----------------------------------------

echo ""
echo "[6/6] Adding site config and reloading nginx..."

# Render template locally to a temp file
RENDERED_CONF="${TMP_DIR}/${SITE_NAME}.conf"
export DOMAIN SITE_NAME SERVICE_NAME NAMESPACE SERVICE_PORT WEBROOT
envsubst \
  '${DOMAIN} ${SITE_NAME} ${SERVICE_NAME} ${NAMESPACE} ${SERVICE_PORT} ${WEBROOT}' \
  < "${TPL_FILE}" > "${RENDERED_CONF}"

# SCP rendered config to control-plane
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
  "${RENDERED_CONF}" \
  "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/${SITE_NAME}.conf"

# Apply to nginx-sites ConfigMap using --from-file (safe for all nginx special chars)
${SSH} "kubectl create configmap nginx-sites -n ${INGRESS_NAMESPACE} \
  --from-file=${SITE_NAME}.conf=/tmp/${SITE_NAME}.conf \
  --dry-run=client -o yaml | kubectl apply -f - && \
  rm -f /tmp/${SITE_NAME}.conf"
echo "[+] ${SITE_NAME}.conf added to nginx-sites ConfigMap."

# Wait for ConfigMap volume to sync into the pod (~10-15s)
echo "[+] Waiting 15s for ConfigMap volume sync..."
sleep 15

# nginx -t then reload
POD=$(${SSH} "kubectl get pod -n ${INGRESS_NAMESPACE} -l app=nginx-ingress \
  -o jsonpath='{.items[0].metadata.name}'")
${SSH} "kubectl exec -n ${INGRESS_NAMESPACE} ${POD} -- nginx -t"
${SSH} "kubectl exec -n ${INGRESS_NAMESPACE} ${POD} -- nginx -s reload"
echo "[+] nginx reloaded."

# --- Done --------------------------------------------------------------------

echo ""
echo "=============================================="
echo " Site Live"
echo "=============================================="
echo " https://${DOMAIN}"
if [[ "${TEMPLATE}" == "proxy-pass" ]]; then
echo " → ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:${SERVICE_PORT}"
fi
if [[ "${TEMPLATE}" == "static-files" ]]; then
echo " → ${WEBROOT} on ingress node"
echo ""
echo " Deploy files:"
echo "   rsync -av --delete ./dist/ adminuser@10.0.0.36:${WEBROOT}/"
fi
echo ""
echo " Cert auto-renews via cert-manager."
echo " nginx picks up renewed certs every 12h via nginx-reload CronJob."
echo "=============================================="