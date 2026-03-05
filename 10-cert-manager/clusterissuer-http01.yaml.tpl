# ClusterIssuer using HTTP-01 challenge.
#
# cert-manager spins up a temporary solver pod with a ClusterIP Service.
# nginx (running inside the cluster with hostNetwork:true) proxies
# /.well-known/acme-challenge/ to the solver via the fixed 'acme-solver'
# Service — no NodePort, no VPS involvement in the ACME flow.
#
# Works for single domains. Does NOT support wildcards.
# Switch to dns01-cloudflare.yaml.tpl when you need wildcards.
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
    - http01:
        ingress:
          serviceType: ClusterIP
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-production-account-key
    solvers:
    - http01:
        ingress:
          serviceType: ClusterIP
