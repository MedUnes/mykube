#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# vps-cleanup.sh — Remove VPS-based nginx ingress layer
#
# Removes everything that was part of the old architecture where nginx ran
# on the VPS host as a proxy. Leaves the VPS as a clean DNAT forwarder.
#
# What gets removed:
#   - nginx (uninstalled)
#   - cert-sync systemd timer and all its files
#   - /etc/nginx/ directory
#   - /etc/cert-sync/ directory
#   - /usr/local/bin/cert-sync.sh
#   - /usr/local/bin/acme-update-proxy.sh
#   - stale ip routes to cluster CIDRs (10.96.0.0/12, 10.244.0.0/16)
#   - ~/.kube/cert-sync.kubeconfig
#
# Safe to run multiple times — all removals are idempotent.
# =============================================================================

echo ""
echo "=============================================="
echo " VPS Cleanup — removing old nginx ingress"
echo "=============================================="
echo ""

# --- Stop and remove cert-sync timer ----------------------------------------

if systemctl is-active --quiet cert-sync.timer 2>/dev/null; then
  sudo systemctl stop cert-sync.timer
  echo "[+] cert-sync.timer stopped."
fi
if systemctl is-enabled --quiet cert-sync.timer 2>/dev/null; then
  sudo systemctl disable cert-sync.timer
  echo "[+] cert-sync.timer disabled."
fi

sudo rm -f /etc/systemd/system/cert-sync.timer
sudo rm -f /etc/systemd/system/cert-sync.service
sudo systemctl daemon-reload
echo "[+] cert-sync systemd units removed."

# --- Remove cert-sync scripts -----------------------------------------------

sudo rm -f /usr/local/bin/cert-sync.sh
sudo rm -f /usr/local/bin/acme-update-proxy.sh
echo "[+] cert-sync scripts removed."

# --- Remove cert-sync kubeconfig --------------------------------------------

rm -f "$HOME/.kube/cert-sync.kubeconfig"
echo "[+] cert-sync kubeconfig removed."

# --- Remove cert-sync config dir --------------------------------------------

sudo rm -rf /etc/cert-sync
echo "[+] /etc/cert-sync removed."

# --- Remove stale routes to cluster CIDRs -----------------------------------
# These routes were added during debugging — cluster CIDRs are not directly
# routable from the VPS. The DNAT approach does not require them.

if ip route show | grep -q "10.96.0.0/12"; then
  sudo ip route del 10.96.0.0/12 2>/dev/null || true
  echo "[+] Removed route: 10.96.0.0/12"
fi
if ip route show | grep -q "10.244.0.0/16"; then
  sudo ip route del 10.244.0.0/16 2>/dev/null || true
  echo "[+] Removed route: 10.244.0.0/16"
fi

# --- Stop and remove nginx --------------------------------------------------

if systemctl is-active --quiet nginx 2>/dev/null; then
  sudo systemctl stop nginx
  echo "[+] nginx stopped."
fi
if systemctl is-enabled --quiet nginx 2>/dev/null; then
  sudo systemctl disable nginx
  echo "[+] nginx disabled."
fi

if command -v nginx &>/dev/null; then
  sudo apt-get remove -y nginx nginx-common nginx-full 2>/dev/null || \
  sudo apt-get remove -y nginx nginx-common 2>/dev/null || true
  echo "[+] nginx uninstalled."
fi

# Remove nginx config and ssl dirs
sudo rm -rf /etc/nginx
echo "[+] /etc/nginx removed."

# Remove leftover ssl certs (they now live as Kubernetes Secrets)
sudo rm -rf /etc/nginx/ssl 2>/dev/null || true

echo ""
echo "=============================================="
echo " Cleanup complete."
echo " VPS is clean. Run bootstrap-ingress.sh next"
echo " to configure DNAT forwarding."
echo "=============================================="