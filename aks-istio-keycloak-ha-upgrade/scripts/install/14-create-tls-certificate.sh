#!/usr/bin/env bash
# =============================================================================
# 14-create-tls-certificate.sh — create a private certificate authority (CA)
# and a wildcard certificate for *.<BASE_DOMAIN>, then store the certificate
# as a Kubernetes secret for the ingress gateway.
# For production use a real certificate (for example cert-manager with
# Let's Encrypt); this script keeps the example free of external dependencies.
# Run it again at any time to renew the certificate (valid for 90 days).
# Usage: ./scripts/install/14-create-tls-certificate.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The host names must be known.
require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"

# Create the CA only once; a new CA would force everybody to trust it again.
if [[ ! -s "${TLS_DIR}/ca.crt" || ! -s "${TLS_DIR}/ca.key" ]]; then
  # Announce the step.
  step "Create a private certificate authority (valid for 2 years)"
  # OpenSSL settings for the CA, written to a file because the old LibreSSL
  # on macOS does not know the newer command-line shortcuts.
  cat > "${TLS_DIR}/ca.cnf" <<CONF
# Settings for the "openssl req" command.
[req]
# Section that holds the name of the certificate.
distinguished_name = dn
# Section with the extensions of a self-signed certificate.
x509_extensions = v3_ca
# Do not ask questions, take everything from this file.
prompt = no
[dn]
# Organisation shown in the browser's certificate viewer.
O = AKS HA Upgrade Example
# Name of the certificate authority.
CN = AKS HA Upgrade Example Local CA
[v3_ca]
# This certificate may sign other certificates.
basicConstraints = critical,CA:TRUE
# Allowed uses: signing certificates and revocation lists.
keyUsage = critical,keyCertSign,cRLSign
# Standard identifier derived from the public key.
subjectKeyIdentifier = hash
CONF
  # -x509 = self-signed, -newkey rsa:2048 = new 2048-bit key, -nodes = key
  # without password, -days 730 = two years.
  run openssl req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 730 -config "${TLS_DIR}/ca.cnf" -keyout "${TLS_DIR}/ca.key" -out "${TLS_DIR}/ca.crt"
  # The CA key can sign certificates for any name: keep it private.
  chmod 600 "${TLS_DIR}/ca.key"
fi

# Announce the step.
step "Create the wildcard certificate for *.${BASE_DOMAIN} (valid for 90 days)"
# OpenSSL settings for the server certificate.
cat > "${TLS_DIR}/server.cnf" <<CONF
# Settings for the "openssl req" command.
[req]
# Section that holds the name of the certificate.
distinguished_name = dn
# Section with the extensions to request.
req_extensions = v3_req
# Do not ask questions, take everything from this file.
prompt = no
[dn]
# Common name (browsers ignore it and read subjectAltName instead).
CN = *.${BASE_DOMAIN}
[v3_req]
# This certificate may not sign other certificates.
basicConstraints = CA:FALSE
# Allowed uses of the key.
keyUsage = critical,digitalSignature,keyEncipherment
# Only valid as a TLS server certificate.
extendedKeyUsage = serverAuth
# The host names the certificate is valid for: app1, app2 and keycloak.
subjectAltName = DNS:*.${BASE_DOMAIN}
CONF
# Create a new private key and a signing request (CSR).
run openssl req -new -newkey rsa:2048 -nodes -config "${TLS_DIR}/server.cnf" -keyout "${TLS_DIR}/tls.key" -out "${TLS_DIR}/tls.csr"
# Let our CA sign the request. -extfile/-extensions copy the host names into
# the certificate; -CAcreateserial creates the serial-number file when needed.
run openssl x509 -req -in "${TLS_DIR}/tls.csr" -CA "${TLS_DIR}/ca.crt" -CAkey "${TLS_DIR}/ca.key" -CAcreateserial -sha256 -days 90 -extfile "${TLS_DIR}/server.cnf" -extensions v3_req -out "${TLS_DIR}/tls.crt"
# Keep the server key private.
chmod 600 "${TLS_DIR}/tls.key"

# Announce the step.
step "Store the certificate as secret 'wildcard-tls' in namespace istio-ingress"
# "--dry-run=client -o yaml | kubectl apply" creates the secret the first time
# and replaces it on every later run. The gateway picks up a new certificate
# within seconds, without a restart.
kubectl --namespace istio-ingress create secret tls wildcard-tls --cert "${TLS_DIR}/tls.crt" --key "${TLS_DIR}/tls.key" --dry-run=client --output yaml | kubectl apply -f -

# Announce the step.
step "Show the certificate"
# Prints the names and the validity period.
run openssl x509 -in "${TLS_DIR}/tls.crt" -noout -subject -issuer -dates
# Tell the user how to make browsers trust the private CA.
info "to avoid browser warnings, import ${TLS_DIR}/ca.crt as a trusted root certificate"
