#!/usr/bin/env bash
# =============================================================================
# 05-apply-mesh-rules.sh — everything Istio needs to know about OUR traffic:
#   1. a private certificate authority and a certificate for the three hosts
#   2. strict mutual TLS and "who may call whom" (plain kubectl manifests)
#   3. the one external host that may be called, through the egress gateway
#   4. the public gateway, the routes and the sticky sessions
# Run it again at any time to renew the certificate (valid for 90 days).
# For production use a real certificate (for example cert-manager).
# Usage: ./scripts/install/05-apply-mesh-rules.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the cluster is not running.
require_cluster

# Create the CA only once; a new CA would force everybody to trust it again.
if [[ ! -s "${TLS_DIR}/ca.crt" || ! -s "${TLS_DIR}/ca.key" ]]; then
  # Announce the step.
  step "Create a private certificate authority (valid for 2 years)"
  # OpenSSL settings for the CA, written to a file.
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
O = Kubernetes HA Upgrade Example
# Name of the certificate authority.
CN = Kubernetes HA Upgrade Example Local CA
[v3_ca]
# This certificate may sign other certificates.
basicConstraints = critical,CA:TRUE
# Allowed uses: signing certificates and revocation lists.
keyUsage = critical,keyCertSign,cRLSign
# Standard identifier derived from the public key.
subjectKeyIdentifier = hash
CONF
  # -x509 = self-signed, -newkey rsa:2048 = new 2048-bit key, -nodes = key
  # without password, -days 730 = two years. (openssl runs in the tools container.)
  run openssl req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 730 -config "${TLS_DIR}/ca.cnf" -keyout "${TLS_DIR}/ca.key" -out "${TLS_DIR}/ca.crt"
  # The CA key can sign certificates for any name: keep it private.
  chmod 600 "${TLS_DIR}/ca.key"
fi

# Announce the step.
step "Create the server certificate for app1, app2 and keycloak (valid for 90 days)"
# OpenSSL settings for the server certificate. The three names are listed one
# by one: browsers do not accept a wildcard like *.localhost.
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
CN = app1.${BASE_DOMAIN}
[v3_req]
# This certificate may not sign other certificates.
basicConstraints = CA:FALSE
# Allowed uses of the key.
keyUsage = critical,digitalSignature,keyEncipherment
# Only valid as a TLS server certificate.
extendedKeyUsage = serverAuth
# The host names the certificate is valid for.
subjectAltName = DNS:app1.${BASE_DOMAIN},DNS:app2.${BASE_DOMAIN},DNS:keycloak.${BASE_DOMAIN}
CONF
# Create a new private key and a signing request (CSR).
run openssl req -new -newkey rsa:2048 -nodes -sha256 -config "${TLS_DIR}/server.cnf" -keyout "${TLS_DIR}/server.key" -out "${TLS_DIR}/server.csr"
# The server key must stay private too.
chmod 600 "${TLS_DIR}/server.key"
# Let the CA sign the request. -copy_extensions is not used on purpose: the
# extensions are read again from the same file, which works with every
# OpenSSL version.
run openssl x509 -req -sha256 -days 90 -in "${TLS_DIR}/server.csr" -CA "${TLS_DIR}/ca.crt" -CAkey "${TLS_DIR}/ca.key" -CAcreateserial -extfile "${TLS_DIR}/server.cnf" -extensions v3_req -out "${TLS_DIR}/server.crt"
# Check that the certificate really chains to our CA.
run openssl verify -CAfile "${TLS_DIR}/ca.crt" "${TLS_DIR}/server.crt"

# Announce the step.
step "Store the certificate as secret 'public-tls' next to the ingress gateway"
# "create --dry-run=client -o yaml" only prints the secret; "apply" then
# creates it the first time and replaces it on renewals. The gateway picks up
# a new certificate without a restart.
kubectl --namespace istio-ingress create secret tls public-tls --cert="${TLS_DIR}/server.crt" --key="${TLS_DIR}/server.key" --dry-run=client --output yaml | kubectl_stdin apply -f -

# Announce the step.
step "Mesh security: strict mutual TLS and who may call whom"
# Every pod-to-pod connection in the mesh must use mutual TLS.
kapply k8s/istio/peer-authentication.yaml
# gateway -> apps, gateway and apps -> Keycloak, Keycloak -> PostgreSQL.
kapply k8s/istio/authorization-policies.yaml

# Announce the step.
step "Egress: allow ${EGRESS_TEST_HOST} through the egress gateway"
# Everything else is blocked (outboundTrafficPolicy REGISTRY_ONLY in helm/values/istiod.yaml).
kapply k8s/istio/egress.yaml

# Announce the step.
step "Ingress: gateway, routes and sticky sessions"
# What the ingress gateway listens on (https with the certificate above).
kapply k8s/istio/gateway.yaml
# Which host name goes to which Service, with retries.
kapply k8s/istio/virtualservices.yaml
# Sticky sessions and removal of unhealthy pods from rotation.
kapply k8s/istio/destinationrules.yaml
# Show the Istio objects.
run kubectl get gateways.networking.istio.io,virtualservices.networking.istio.io,destinationrules.networking.istio.io,serviceentries.networking.istio.io,peerauthentications.security.istio.io,authorizationpolicies.security.istio.io --all-namespaces
# Final message.
ok "mesh rules applied. To avoid browser warnings, import ${TLS_DIR}/ca.crt as a trusted authority."
