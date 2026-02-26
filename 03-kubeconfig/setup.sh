#!/usr/bin/env bash
set -euo pipefail

# --- Install kubectl if not exists -------------------------------------------
if ! command -v kubectl &>/dev/null; then
  echo "[!] kubectl not found. Installing..."
  K8S_VERSION="v1.35.1"
  curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
  echo "[+] kubectl installed."
fi

