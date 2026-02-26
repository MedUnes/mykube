#!/usr/bin/env bash
set -euo pipefail

if command -v cfssl &>/dev/null && command -v cfssljson &>/dev/null; then
  echo "[+] cfssl already installed, skipping."
  return
fi
echo "[+] Installing cfssl and cfssljson..."
CFSSL_VERSION="1.6.5"
curl -fsSL "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_linux_amd64" \
  -o /usr/local/bin/cfssl
curl -fsSL "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_linux_amd64" \
  -o /usr/local/bin/cfssljson
chmod +x /usr/local/bin/cfssl /usr/local/bin/cfssljson
echo "[+] cfssl $(cfssl version | head -1) installed."