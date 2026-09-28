#!/usr/bin/env bash
# =============================================================================
#  00-config.sh  —  THE ONE FILE YOU EDIT
#
#  Every other script reads its settings from here (they "source" this file).
#  Think of it as the shopping list taped to the fridge: change the list here,
#  and every helper in the store reads the same list.
#
#  Change a value with your editor, or with the sed helper:
#      tools/set-config.sh LOCATION westeurope
# =============================================================================

# ---- Azure -----------------------------------------------------------------
export PROJECT="freshmart"                 # short name used for everything (lowercase, letters+digits)
export LOCATION="eastus"                   # Azure region, e.g. eastus, westeurope
export RESOURCE_GROUP="${PROJECT}-rg"      # the "box" that holds all Azure things
export CLUSTER_NAME="${PROJECT}-aks"       # the Kubernetes cluster (the school building)
export ACR_NAME=""                         # container registry name; leave empty = auto-generate a unique one
export KUBERNETES_VERSION=""               # empty = Azure default; or e.g. "1.31"

# ---- Nodes (the classrooms) --------------------------------------------------
export SYSTEM_NODE_COUNT=1
export SYSTEM_NODE_VM_SIZE="Standard_D2s_v3"
export APPS_NODE_COUNT=2
export APPS_NODE_VM_SIZE="Standard_D2s_v3"

# ---- Web addresses -----------------------------------------------------------
# We use nip.io so you do not need to buy a domain: keycloak.<INGRESS-IP>.nip.io
# Set ENABLE_TLS=true (plus LETSENCRYPT_EMAIL) to get real https certificates
# from Let's Encrypt through cert-manager. false = plain http (fine for learning).
export ENABLE_TLS="false"
export LETSENCRYPT_EMAIL="you@example.com"

# ---- Keycloak (the front office) --------------------------------------------
export KC_REALM="grocery"
export KC_ADMIN_USER="admin"
export KC_ADMIN_PASSWORD="Admin-ChangeMe-123!"
export KC_IMAGE_TAG="26.3"

# Demo users (sam.shopper / casey.cashier / morgan.manager and the LDAP users) all share this password
export DEMO_USER_PASSWORD="password123"

# Secrets each app uses to prove to Keycloak "I really am the Java app"
export JAVA_CLIENT_SECRET="java-app-secret-change-me"
export PYTHON_CLIENT_SECRET="python-app-secret-change-me"

# ---- Postgres (the notebook in the back office) ------------------------------
export PG_ADMIN_PASSWORD="Postgres-ChangeMe-123!"
export KC_DB_PASSWORD="keycloak-db-change-me"
export APP_DB_PASSWORD="grocery-db-change-me"

# ---- OpenLDAP (the phone book) ------------------------------------------------
export LDAP_ORGANISATION="Fresh Mart"
export LDAP_DOMAIN="freshmart.local"
export LDAP_BASE_DN="dc=freshmart,dc=local"
export LDAP_ADMIN_PASSWORD="Ldap-ChangeMe-123!"

# ---- Images / tests ----------------------------------------------------------
export IMAGE_TAG="v1"                      # bump this when you rebuild the apps
export PLAYWRIGHT_VERSION="1.47.2"         # must match the mcr.microsoft.com/playwright image tag

# ---- Kubernetes namespaces (the hallways) ------------------------------------
export NS_IDENTITY="identity"              # keycloak + openldap
export NS_DATA="data"                      # postgres
export NS_APPS="apps"                      # java store + python deli
export NS_TESTS="testing"                  # go / curl / playwright inspectors
