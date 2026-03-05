#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Worker Node Bootstrap Script
# Installs containerd, CNI plugins, and kubelet on both worker nodes.
# Runs on the VPS host, executes remotely via SSH.
#
# Usage: ./bootstrap-workers.sh
# =============================================================================

# --- Environment -----------------------------------------------------------

WORKER_1_HOST="worker-node-1"
WORKER_1_IP="10.0.0.36"
WORKER_2_HOST="worker-node-2"
WORKER_2_IP="10.0.0.37"

K8S_VERSION="v1.35.1"
CONTAINERD_VERSION="2.2.1"
CNI_VERSION="v1.9.0"
RUNC_VERSION="v1.2.5"

SSH_USER="adminuser"
SSH_KEY="$HOME/.ssh/id_rsa_k8s_vm"
SCP="scp -i ${SSH_KEY} -o StrictHostKeyChecking=no"

CONFIGS_DIR="$(dirname "$0")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=============================================="
echo " Worker Node Bootstrap"
echo "=============================================="
echo " Workers       : ${WORKER_1_HOST} (${WORKER_1_IP})"
echo "               : ${WORKER_2_HOST} (${WORKER_2_IP})"
echo " K8s version   : ${K8S_VERSION}"
echo " containerd    : ${CONTAINERD_VERSION}"
echo " CNI plugins   : ${CNI_VERSION}"
echo "=============================================="
echo ""

# --- Helper: run on a single node -----------------------------------------

bootstrap_worker() {
  local NODE_NAME="$1"
  local NODE_IP="$2"
  local SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${SSH_USER}@${NODE_IP}"

  echo ""
  echo "----------------------------------------------"
  echo " Bootstrapping ${NODE_NAME} (${NODE_IP})"
  echo "----------------------------------------------"

  # --- Render configs for this node ---------------------------------------

  echo "[+] Rendering configs for ${NODE_NAME}..."

  export NODE_NAME NODE_IP INTERNAL_IP="${NODE_IP}"
  # Pod CIDR is assigned by controller-manager — kubelet discovers it
  # via the Node object after registration. We leave it empty here and
  # let the controller-manager populate it.
  export POD_CIDR=""

  envsubst < "${CONFIGS_DIR}/kubelet-config.yaml.tpl" \
    > "${TMP_DIR}/${NODE_NAME}-kubelet-config.yaml"

  envsubst < "${CONFIGS_DIR}/kubelet.service.tpl" \
    > "${TMP_DIR}/${NODE_NAME}-kubelet.service"

  # --- Upload configs -----------------------------------------------------

  echo "[+] Uploading configs to ${NODE_NAME}..."

  $SCP "${TMP_DIR}/${NODE_NAME}-kubelet-config.yaml" \
    "${SSH_USER}@${NODE_IP}:/tmp/kubelet-config.yaml"

  $SCP "${TMP_DIR}/${NODE_NAME}-kubelet.service" \
    "${SSH_USER}@${NODE_IP}:/tmp/kubelet.service"

  $SCP "${CONFIGS_DIR}/containerd-config.toml" \
    "${SSH_USER}@${NODE_IP}:/tmp/containerd-config.toml"

  # --- Install containerd -------------------------------------------------

  echo "[+] Installing containerd ${CONTAINERD_VERSION}..."

  $SSH "bash -s" << EOF
set -euo pipefail

echo "[+] Downloading containerd..."
curl -fsSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" \
  -o /tmp/containerd.tar.gz

sudo tar -xzf /tmp/containerd.tar.gz -C /usr/local
rm /tmp/containerd.tar.gz

echo "[+] Installing containerd systemd service..."
curl -fsSL "https://raw.githubusercontent.com/containerd/containerd/main/containerd.service" \
  -o /tmp/containerd.service
sudo mv /tmp/containerd.service /etc/systemd/system/containerd.service

echo "[+] Applying containerd config..."
sudo mkdir -p /etc/containerd
sudo mv /tmp/containerd-config.toml /etc/containerd/config.toml

echo "[+] Installing runc..."
curl -fsSL "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" \
  -o /tmp/runc
sudo install -m 755 /tmp/runc /usr/local/sbin/runc

echo "[+] Enabling and starting containerd..."
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd

sudo systemctl is-active --quiet containerd \
  && echo "[+] containerd is running." \
  || { echo "[!] containerd failed."; sudo journalctl -u containerd --no-pager -n 20; exit 1; }
EOF

  # --- Install CNI plugins ------------------------------------------------

  echo "[+] Installing CNI plugins ${CNI_VERSION}..."

  $SSH "bash -s" << EOF
set -euo pipefail

sudo mkdir -p /opt/cni/bin

curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" \
  -o /tmp/cni-plugins.tgz

sudo tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin
rm /tmp/cni-plugins.tgz

echo "[+] CNI plugins installed:"
ls /opt/cni/bin/
EOF

  # --- Install kubelet ----------------------------------------------------

  echo "[+] Installing kubelet ${K8S_VERSION}..."

  $SSH "bash -s" << EOF
set -euo pipefail

curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubelet" \
  -o /tmp/kubelet
sudo install -m 755 /tmp/kubelet /usr/local/bin/kubelet
echo "[+] kubelet version: \$(kubelet --version)"
EOF

  # --- Install certs and kubeconfig ---------------------------------------

  echo "[+] Installing PKI and kubeconfig for ${NODE_NAME}..."

  $SSH "bash -s" << EOF
set -euo pipefail

sudo mkdir -p /etc/kubernetes/pki

sudo cp ~/ca.pem                       /etc/kubernetes/pki/
sudo cp ~/${NODE_NAME}.pem             /etc/kubernetes/pki/
sudo cp ~/${NODE_NAME}-key.pem         /etc/kubernetes/pki/

sudo chmod 644 /etc/kubernetes/pki/ca.pem /etc/kubernetes/pki/${NODE_NAME}.pem
sudo chmod 600 /etc/kubernetes/pki/${NODE_NAME}-key.pem

# Install kubeconfig — kubelet expects it at a fixed path
sudo cp ~/${NODE_NAME}.kubeconfig /etc/kubernetes/kubelet.kubeconfig

# Install kubelet config
sudo mv /tmp/kubelet-config.yaml /etc/kubernetes/kubelet-config.yaml

echo "[+] PKI and kubeconfig installed."
EOF

  # --- Install and start kubelet ------------------------------------------

  echo "[+] Starting kubelet on ${NODE_NAME}..."

  $SSH "bash -s" << 'EOF'
set -euo pipefail

sudo mv /tmp/kubelet.service /etc/systemd/system/kubelet.service
sudo systemctl daemon-reload
sudo systemctl enable kubelet
sudo systemctl start kubelet

sleep 5

sudo systemctl is-active --quiet kubelet \
  && echo "[+] kubelet is running." \
  || { echo "[!] kubelet failed."; sudo journalctl -u kubelet --no-pager -n 30; exit 1; }
EOF

  echo "[+] ${NODE_NAME} bootstrap complete."
}

# --- Bootstrap both workers -----------------------------------------------

bootstrap_worker "${WORKER_1_HOST}" "${WORKER_1_IP}"
bootstrap_worker "${WORKER_2_HOST}" "${WORKER_2_IP}"


# --- Install kubectl on control-plane and install admin kubeconfig --------
# We use the admin kubeconfig (system:masters) not the controller-manager one.
# The controller-manager identity lacks RBAC permissions to manage ClusterRoles
# which is required by Cilium and other cluster-wide tools.
# The admin kubeconfig points to 127.0.0.1:6443 (tunnel) — we patch it to
# the internal IP so it works directly on the control plane without a tunnel.

echo ""
echo "[+] Installing kubectl on control-plane-1 and installing admin kubeconfig..."

# Hardcoded path — same convention as bootstrap-nodes.sh.
# No guessing, no silent fallthrough.
KUBECONFIG_DIR="$HOME/k8s-kubeconfigs"

if [[ ! -f "${KUBECONFIG_DIR}/admin.kubeconfig" ]]; then
  echo "[!] Cannot find admin.kubeconfig at ${KUBECONFIG_DIR}/admin.kubeconfig"
  echo "    Run the PKI bootstrap phase first."
  exit 1
fi

sed 's|https://127.0.0.1:6443|https://10.0.0.4:6443|g' \
  "${KUBECONFIG_DIR}/admin.kubeconfig" > /tmp/admin-internal.kubeconfig

echo "[+] Uploading admin kubeconfig (internal) to control-plane-1..."
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
  /tmp/admin-internal.kubeconfig \
  "${SSH_USER}@10.0.0.4:/tmp/admin-internal.kubeconfig"

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@10.0.0.4" "bash -s" << EOF
set -euo pipefail

# Install kubectl if not present
if ! command -v kubectl &>/dev/null; then
  echo "[+] Installing kubectl ${K8S_VERSION}..."
  curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
    -o /tmp/kubectl
  sudo install -m 755 /tmp/kubectl /usr/local/bin/kubectl
  echo "[+] kubectl version: \$(kubectl version --client)"
fi

# Install admin kubeconfig — full cluster-admin access
mkdir -p ~/.kube
mv /tmp/admin-internal.kubeconfig ~/.kube/config
chmod 600 ~/.kube/config

echo "[+] Verifying admin access..."
WHOAMI=\$(kubectl auth whoami --output=jsonpath='{.status.userInfo.username}' 2>/dev/null || echo "")
if [[ "\${WHOAMI}" != "kubernetes-admin" && "\${WHOAMI}" != "admin" ]]; then
  echo "[!] kubeconfig identity check FAILED."
  echo "    Expected: kubernetes-admin or admin (system:masters)"
  echo "    Got:      \${WHOAMI}"
  echo "    The wrong kubeconfig was installed. Check PKI phase output."
  exit 1
fi
echo "[+] Identity confirmed: \${WHOAMI}"

GROUPS=\$(kubectl auth whoami --output=jsonpath='{.status.userInfo.groups}' 2>/dev/null || echo "")
if [[ "\${GROUPS}" != *"system:masters"* ]]; then
  echo "[!] kubeconfig is NOT cluster-admin — system:masters group missing."
  echo "    Groups: \${GROUPS}"
  exit 1
fi
echo "[+] Group confirmed: system:masters — cluster-admin access verified."
EOF

# --- Fix /etc/hosts on control-plane-1 ------------------------------------
# kubectl logs / kubectl exec / kubectl port-forward all route through
# the node kubelet API via the nodes/proxy subresource. The apiserver
# connects to worker nodes by hostname. If control-plane-1 cannot resolve
# worker hostnames, every kubectl logs call fails with:
#   "dial tcp: lookup worker-node-2 on 127.0.0.53:53: server misbehaving"
#
# Fix: add all node hostnames to /etc/hosts on control-plane-1.
# Idempotent — grep prevents duplicate entries.

echo ""
echo "[+] Fixing /etc/hosts on all nodes for kubectl logs/exec support..."
echo "    kubectl logs/exec routes through the node kubelet API by hostname."
echo "    Without entries on every node, logs fail with 'server misbehaving'."

# The add_hosts_on function runs on a target node via SSH and idempotently
# adds all cluster node entries. Running on every node ensures kubectl logs
# works regardless of which node a pod lands on.

add_hosts_on() {
  local TARGET_IP="$1"
  local TARGET_LABEL="$2"
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${TARGET_IP}" "bash -s" << HOSTSEOF
set -euo pipefail
add_host() {
  local IP="\$1"
  local HN="\$2"
  if grep -qE "\s+\${HN}\s*$" /etc/hosts 2>/dev/null; then
    echo "[=] \${HN} already in /etc/hosts — skipping."
  else
    echo "\${IP}  \${HN}" | sudo tee -a /etc/hosts > /dev/null
    echo "[+] Added: \${IP}  \${HN}"
  fi
}
add_host "10.0.0.4"         "control-plane-1"
add_host "${WORKER_1_IP}"   "${WORKER_1_HOST}"
add_host "${WORKER_2_IP}"   "${WORKER_2_HOST}"
echo "[+] /etc/hosts cluster entries on ${TARGET_LABEL}:"
grep -E "control-plane|worker-node" /etc/hosts
HOSTSEOF
}

add_hosts_on "10.0.0.4"         "control-plane-1"
add_hosts_on "${WORKER_1_IP}"   "${WORKER_1_HOST}"
add_hosts_on "${WORKER_2_IP}"   "${WORKER_2_HOST}"


# --- Apply kubelet-api-admin ClusterRoleBinding ----------------------------
# The apiserver proxies kubectl logs/exec/port-forward to kubelets using
# its own identity (CN=kubernetes). Without this binding the kubelet
# rejects the connection:
#   Forbidden (user=kubernetes, verb=get, resource=nodes, subresource=proxy)
# Applied here (post worker join) so the cluster is already up.

echo ""
echo "[+] Applying kubelet-api-admin ClusterRoleBinding..."

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@10.0.0.4" "bash -s" << 'RBACEOF'
set -euo pipefail
cat << YAML | kubectl apply -f -
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
YAML
echo "[+] kube-apiserver-kubelet-admin binding applied."
echo "[+] kubectl logs / kubectl exec now work for all pods."
RBACEOF

# --- Verify nodes registered with apiserver --------------------------------

echo ""
echo "[+] Waiting 10s for nodes to register with apiserver..."
sleep 10

echo "[+] Checking node registration from control-plane..."
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
  "${SSH_USER}@10.0.0.4" \
  "kubectl get nodes -o wide"

# --- Summary ---------------------------------------------------------------

echo ""
echo "=============================================="
echo " Worker Node Bootstrap Complete"
echo "=============================================="
echo " Nodes bootstrapped:"
echo "   ${WORKER_1_HOST} : ${WORKER_1_IP}"
echo "   ${WORKER_2_HOST} : ${WORKER_2_IP}"
echo ""
echo " Installed on each worker:"
echo "   containerd  ${CONTAINERD_VERSION}"
echo "   runc        ${RUNC_VERSION}"
echo "   CNI plugins ${CNI_VERSION}"
echo "   kubelet     ${K8S_VERSION}"
echo ""
echo " Nodes may show NotReady — expected until Cilium CNI is installed."
echo " Next step: Install Cilium"
echo "=============================================="
