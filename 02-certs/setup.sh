#!/usr/bin/env bash
set -euo pipefail
# --- Install cfssl if not exists --------------------------------------------------------
if ! command -v cfssl &>/dev/null ; then
  echo "[+] Installing cfssl and cfssljson..."
  CFSSL_VERSION="1.6.5"
  curl -fsSL "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_linux_amd64" \
    -o /usr/local/bin/cfssl
  chmod +x /usr/local/bin/cfssl
  echo "[+] cfssl $(cfssl version | head -1) installed."
fi
# --- Install cfssljson_ if not exists --------------------------------------------------------
if ! command -v cfssljson &>/dev/null; then
  curl -fsSL "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_linux_amd64" \
    -o /usr/local/bin/cfssljson
  chmod +x /usr/local/bin/cfssljson
  echo "[+] cfssljson_$(cfssljson -version | head -1) installed."
fi




