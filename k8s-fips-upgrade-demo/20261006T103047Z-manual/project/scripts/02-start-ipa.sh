#!/usr/bin/env bash
# 02-start-ipa.sh - starts FreeIPA (the domain controller) next to the cluster and creates the demo accounts, keytab and certificates.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init start-ipa "$@"
need docker openssl
mkdir -p "$WORK_DIR/ipa"; chmod 700 "$WORK_DIR/ipa"
step "Start the FreeIPA container ($IPA_HOSTNAME, realm $IPA_REALM)"
ipa_start
ipa_wait_ready
IPA_IP="$(ipa_ip)"
[ -n "$IPA_IP" ] || die "could not read the IP address of $IPA_CONTAINER on Docker network 'kind'"
printf 'IPA_IP=%s\n' "$IPA_IP" > "$WORK_DIR/ipa/ipa.env"
ok "FreeIPA address inside the kind network: $IPA_IP"

step "Demo user, group and the app's Kerberos service"
ipa_bootstrap
ipa_ca_cert "$WORK_DIR/ipa/ca.crt"
ok "saved FreeIPA's CA certificate: work/ipa/ca.crt"

step "Keytab for $SPN (the app's own Kerberos keys)"
if [ -s "$WORK_DIR/ipa/app.keytab" ]; then
  log "work/ipa/app.keytab exists. NOT asking again: a new request would make new keys and break the old file."
else
  ipa_new_service_keytab "$WORK_DIR/ipa/app.keytab"
fi

step "Certificates from FreeIPA's CA (RSA $TLS_KEY_BITS_NONFIPS bits, signed with SHA-256)"
if [ ! -s "$WORK_DIR/ipa/tls-v1.crt" ]; then ipa_issue_cert "$SPN" "$APP_HOSTNAME" "$TLS_KEY_BITS_NONFIPS" "$WORK_DIR/ipa/tls-v1"; fi
if [ ! -s "$WORK_DIR/ipa/client.crt" ]; then ipa_issue_cert "host/$CLIENT_HOSTNAME" "$CLIENT_HOSTNAME" "$TLS_KEY_BITS_NONFIPS" "$WORK_DIR/ipa/client"; fi
ok "server certificate: work/ipa/tls-v1.crt    client certificate (for the mutual TLS test): work/ipa/client.crt"

step "Do the accounts already have SHA-2 Kerberos keys? (needed later for FIPS)"
for p in "$DEMO_USER" "$SPN"; do
  if ipa_principal_has_sha2 "$p"; then ok "$p has an aes256-cts-hmac-sha384-192 key"; else warn "$p has NO SHA-2 key yet"; fi
done
