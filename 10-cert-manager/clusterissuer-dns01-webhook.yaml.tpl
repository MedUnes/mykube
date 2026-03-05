# ClusterIssuer using DNS-01 challenge via a third-party webhook provider.
# Use this for providers not natively supported by cert-manager:
# IONOS, OVH, Gandi, Myra Security, etc.
#
# Steps to use this template:
# 1. Find or write a cert-manager webhook for your DNS provider.
#    Community webhooks: https://cert-manager.io/docs/configuration/acme/dns01/#webhook
# 2. Install the webhook into your cluster (usually: kubectl apply -f webhook.yaml)
# 3. Replace ALL_CAPS values below with your provider's specifics.
# 4. Set CHALLENGE_TYPE=dns01-webhook and ACME_EMAIL before running bootstrap.
#
# Example community webhooks:
#   IONOS  : https://github.com/fabmade/cert-manager-webhook-ionos
#   OVH    : https://github.com/baarde/cert-manager-webhook-ovh
#   Gandi  : https://github.com/bwolf/cert-manager-webhook-gandi
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
      - dns01:
          webhook:
            # The groupName is defined by the webhook provider.
            # Check the webhook's README for the correct value.
            groupName: REPLACE_WITH_WEBHOOK_GROUP_NAME
            solverName: REPLACE_WITH_SOLVER_NAME
            config:
              # Provider-specific config — check webhook README.
              # Example for IONOS:
              # apiKeySecretRef:
              #   name: ionos-api-key
              #   key: api-key
              REPLACE_WITH_PROVIDER_CONFIG: ""
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
      - dns01:
          webhook:
            groupName: REPLACE_WITH_WEBHOOK_GROUP_NAME
            solverName: REPLACE_WITH_SOLVER_NAME
            config:
              REPLACE_WITH_PROVIDER_CONFIG: ""
