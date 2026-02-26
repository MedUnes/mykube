#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Kubernetes PKI Generator using cfssl
# All IPs and hostnames are detected dynamically, nothing hardcoded.
# Run this on the VPS host (not inside a VM).
# =============================================================================

# --- Detect environment dynamically ---------------------------------------

VPS_PUBLIC_IP=$(curl -s ifconfig.me)
BRIDGE_IP=$(ip addr show virbr2 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

CONTROL_PLANE_IP="10.0.0.4"
WORKER_1_IP="10.0.0.36"
WORKER_2_IP="10.0.0.37"

CONTROL_PLANE_HOST="control-plane-1"
WORKER_1_HOST="worker-node-1"
WORKER_2_HOST="worker-node-2"

SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
SSH_USER="adminuser"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"

CERT_DIR="$HOME/k8s-pki"
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

echo "=============================================="
echo " Kubernetes PKI Generator"
echo "=============================================="
echo " VPS Public IP   : $VPS_PUBLIC_IP"
echo " Bridge IP       : $BRIDGE_IP"
echo " Control Plane   : $CONTROL_PLANE_IP ($CONTROL_PLANE_HOST)"
echo " Worker 1        : $WORKER_1_IP ($WORKER_1_HOST)"
echo " Worker 2        : $WORKER_2_IP ($WORKER_2_HOST)"
echo " Output dir      : $CERT_DIR"
echo "=============================================="
echo ""

# --- Install cfssl --------------------------------------------------------

install_cfssl() {
  if command -v cfssl &>/dev/null && command -v cfssljson &>/dev/null; then
    echo "[+] cfssl already installed, skipping."
    return
  fi
  echo "[+] Installing cfssl and cfssljson..."
  CFSSL_VERSION="1.6.4"
  curl -fsSL "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_linux_amd64" \
    -o /usr/local/bin/cfssl
  curl -fsSL "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_linux_amd64" \
    -o /usr/local/bin/cfssljson
  chmod +x /usr/local/bin/cfssl /usr/local/bin/cfssljson
  echo "[+] cfssl $(cfssl version | head -1) installed."
}

# --- Write shared cfssl config --------------------------------------------

write_cfssl_config() {
  echo "[+] Writing cfssl signing config..."
  cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ],
        "expiry": "8760h"
      }
    }
  }
}
EOF
}

# --- 1. Certificate Authority ---------------------------------------------

generate_ca() {
  echo "[+] Generating Certificate Authority..."
  cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "EU", "L": "Frankfurt", "O": "Kubernetes", "OU": "CA", "ST": "Hesse" }]
}
EOF
  cfssl gencert -initca ca-csr.json | cfssljson -bare ca
  echo "[+] CA generated: ca.pem ca-key.pem"
}

# --- 2. Admin Client Certificate ------------------------------------------

generate_admin() {
  echo "[+] Generating admin certificate..."
  cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "EU", "L": "Frankfurt", "O": "system:masters", "OU": "Kubernetes The Hard Way", "ST": "Hesse" }]
}
EOF
  cfssl gencert \
    -ca=ca.pem -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    admin-csr.json | cfssljson -bare admin
  echo "[+] Admin cert generated."
}

# --- 3. Kubelet Certificates (one per node) --------------------------------

generate_kubelet_certs() {
  for i in \
    "$WORKER_1_HOST:$WORKER_1_IP" \
    "$WORKER_2_HOST:$WORKER_2_IP"; do

    HOST="${i%%:*}"
    IP="${i##*:}"

    echo "[+] Generating kubelet cert for $HOST ($IP)..."
    cat > "${HOST}-csr.json" <<EOF
{
  "CN": "system:node:${HOST}",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "EU", "L": "Frankfurt", "O": "system:nodes", "OU": "Kubernetes The Hard Way", "ST": "Hesse" }]
}
EOF
    cfssl gencert \
      -ca=ca.pem -ca-key=ca-key.pem \
      -config=ca-config.json \
      -hostname="${HOST},${IP}" \
      -profile=kubernetes \
      "${HOST}-csr.json" | cfssljson -bare "${HOST}"
    echo "[+] Kubelet cert for $HOST generated."
  done
}

# --- 4. kube-controller-manager Certificate --------------------------------

generate_controller_manager() {
  echo "[+] Generating kube-controller-manager certificate..."
  cat > kube-controller-manager-csr.json <<EOF
{
  "CN": "system:kube-controller-manager",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "EU", "L": "Frankfurt", "O": "system:kube-controller-manager", "OU": "Kubernetes The Hard Way", "ST": "Hesse" }]
}
EOF
  cfssl gencert \
    -ca=ca.pem -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager
  echo "[+] kube-controller-manager cert generated."
}

# --- 5. kube-scheduler Certificate -----------------------------------------

generate_kube_scheduler() {
  echo "[+] Generating kube-scheduler certificate..."
  cat > kube-scheduler-csr.json <<EOF
{
  "CN": "system:kube-scheduler",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "EU", "L": "Frankfurt", "O": "system:kube-scheduler", "OU": "Kubernetes The Hard Way", "ST": "Hesse" }]
}
EOF
  cfssl gencert \
    -ca=ca.pem -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    kube-scheduler-csr.json | cfssljson -bare kube-scheduler
  echo "[+] kube-scheduler cert generated."
}

# --- 6. kube-apiserver Certificate -----------------------------------------
# This is the most important one,  SANs must cover every way the API
# server will be addressed: internal IPs, public IP, hostnames, and
# the kubernetes.default service IP (always first IP in service CIDR).

generate_apiserver() {
  echo "[+] Generating kube-apiserver certificate..."

  # First IP of service CIDR (10.96.0.0/24) is always 10.96.0.1
  K8S_SERVICE_IP="10.96.0.1"

  APISERVER_HOSTNAMES="${CONTROL_PLANE_IP},${CONTROL_PLANE_HOST}"
  APISERVER_HOSTNAMES+=",${VPS_PUBLIC_IP}"
  APISERVER_HOSTNAMES+=",${BRIDGE_IP}"
  APISERVER_HOSTNAMES+=",${K8S_SERVICE_IP}"
  APISERVER_HOSTNAMES+=",127.0.0.1"
  APISERVER_HOSTNAMES+=",kubernetes"
  APISERVER_HOSTNAMES+=",kubernetes.default"
  APISERVER_HOSTNAMES+=",kubernetes.default.svc"
  APISERVER_HOSTNAMES+=",kubernetes.default.svc.cluster.local"

  cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "EU", "L": "Frankfurt", "O": "Kubernetes", "OU": "Kubernetes The Hard Way", "ST": "Hesse" }]
}
EOF
  cfssl gencert \
    -ca=ca.pem -ca-key=ca-key.pem \
    -config=ca-config.json \
    -hostname="$APISERVER_HOSTNAMES" \
    -profile=kubernetes \
    kubernetes-csr.json | cfssljson -bare kubernetes
  echo "[+] kube-apiserver cert generated with SANs: $APISERVER_HOSTNAMES"
}

# --- 7. etcd Certificate ---------------------------------------------------

generate_etcd() {
  echo "[+] Generating etcd certificate..."
  cat > etcd-csr.json <<EOF
{
  "CN": "etcd",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "EU", "L": "Frankfurt", "O": "Kubernetes", "OU": "Kubernetes The Hard Way", "ST": "Hesse" }]
}
EOF
  cfssl gencert \
    -ca=ca.pem -ca-key=ca-key.pem \
    -config=ca-config.json \
    -hostname="${CONTROL_PLANE_IP},${CONTROL_PLANE_HOST},127.0.0.1" \
    -profile=kubernetes \
    etcd-csr.json | cfssljson -bare etcd
  echo "[+] etcd cert generated."
}

# --- 8. Service Account Key Pair -------------------------------------------

generate_service_account() {
  echo "[+] Generating service account key pair..."
  cat > service-account-csr.json <<EOF
{
  "CN": "service-accounts",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "EU", "L": "Frankfurt", "O": "Kubernetes", "OU": "Kubernetes The Hard Way", "ST": "Hesse" }]
}
EOF
  cfssl gencert \
    -ca=ca.pem -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    service-account-csr.json | cfssljson -bare service-account
  echo "[+] Service account key pair generated."
}

# --- 9. Distribute Certificates to Nodes ----------------------------------

distribute_certs() {
  echo ""
  echo "[+] Distributing certificates to nodes..."

  # Worker nodes need: CA, their kubelet cert
  for i in \
    "$WORKER_1_HOST:$WORKER_1_IP" \
    "$WORKER_2_HOST:$WORKER_2_IP"; do

    HOST="${i%%:*}"
    IP="${i##*:}"

    echo "[+] Copying certs to $HOST ($IP)..."
    scp $SSH_OPTS \
      ca.pem \
      "${HOST}.pem" \
      "${HOST}-key.pem" \
      "${SSH_USER}@${IP}:~/"
  done

  # Control plane needs: CA, apiserver, etcd, service-account, controller-manager, scheduler certs
  echo "[+] Copying certs to control-plane ($CONTROL_PLANE_IP)..."
  scp $SSH_OPTS \
    ca.pem ca-key.pem \
    kubernetes.pem kubernetes-key.pem \
    etcd.pem etcd-key.pem \
    service-account.pem service-account-key.pem \
    kube-controller-manager.pem kube-controller-manager-key.pem \
    kube-scheduler.pem kube-scheduler-key.pem \
    "${SSH_USER}@${CONTROL_PLANE_IP}:~/"

  echo "[+] Certificate distribution complete."
}

# --- Summary --------------------------------------------------------------

print_summary() {
  echo ""
  echo "=============================================="
  echo " PKI Generation Complete"
  echo "=============================================="
  echo " Generated certificates:"
  ls -1 "$CERT_DIR"/*.pem | xargs -I{} basename {}
  echo ""
  echo " Next step: Generate kubeconfigs"
  echo "=============================================="
}

# --- Main -----------------------------------------------------------------

install_cfssl
write_cfssl_config
generate_ca
generate_admin
generate_kubelet_certs
generate_controller_manager
generate_kube_scheduler
generate_apiserver
generate_etcd
generate_service_account
distribute_certs
print_summary
