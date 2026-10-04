#!/usr/bin/env bash
# =============================================================================
# 18-create-secrets.sh — generate all passwords once and store them as
# Kubernetes secrets.
# The passwords are written to .state/secrets.env (readable only by you) so
# that later runs reuse them. They are never printed and never logged.
# Usage: ./scripts/install/18-create-secrets.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster

# Announce the step.
step "Generate passwords that do not exist yet"
# Password of the PostgreSQL superuser "postgres".
secret_ensure POSTGRES_PASSWORD
# Password of the database role "keycloak".
secret_ensure KEYCLOAK_DB_PASSWORD
# Password of the Keycloak administrator "admin".
secret_ensure KEYCLOAK_ADMIN_PASSWORD
# OIDC client secret of application 1.
secret_ensure APP1_CLIENT_SECRET
# OIDC client secret of application 2.
secret_ensure APP2_CLIENT_SECRET
# Password of the test users alice, bob and carol ("Demo-" + random part).
secret_ensure TEST_USER_PASSWORD "Demo-"
# Report without showing any value.
ok "passwords are stored in ${SECRETS_FILE}"

# Announce the step.
step "Create the Kubernetes secrets"
# The manifests are piped into kubectl, so no password ever appears on a
# command line (where other users of this machine could see it) or in the log.
# "kubectl apply" creates each secret the first time and updates it afterwards.
# Note: PostgreSQL reads its passwords only when the data folder is created.
kubectl apply -f - <<YAML
# Passwords for the PostgreSQL pods.
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: postgres
type: Opaque
stringData:
  postgres-password: "${POSTGRES_PASSWORD}"
  keycloak-db-password: "${KEYCLOAK_DB_PASSWORD}"
---
# Admin login and database password for Keycloak.
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-credentials
  namespace: keycloak
type: Opaque
stringData:
  admin-username: "admin"
  admin-password: "${KEYCLOAK_ADMIN_PASSWORD}"
  db-password: "${KEYCLOAK_DB_PASSWORD}"
---
# OIDC client secret of application 1.
apiVersion: v1
kind: Secret
metadata:
  name: app1-oidc
  namespace: apps
type: Opaque
stringData:
  client-secret: "${APP1_CLIENT_SECRET}"
---
# OIDC client secret of application 2.
apiVersion: v1
kind: Secret
metadata:
  name: app2-oidc
  namespace: apps
type: Opaque
stringData:
  client-secret: "${APP2_CLIENT_SECRET}"
YAML

# Announce the step.
step "Show the secrets (names only)"
# Lists the secrets without their content.
run kubectl get secrets --namespace postgres postgres-credentials
# Same for Keycloak.
run kubectl get secrets --namespace keycloak keycloak-credentials
# Same for the two applications.
run kubectl get secrets --namespace apps app1-oidc app2-oidc
