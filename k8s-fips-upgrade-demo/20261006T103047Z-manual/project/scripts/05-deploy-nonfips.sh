#!/usr/bin/env bash
# 05-deploy-nonfips.sh - deploys version 1 (blue, NON-FIPS) of the app and sends all visitors to it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init deploy-nonfips "$@"
need kubectl openssl curl
load_ipa_env
for f in ca.crt app.keytab tls-v1.key tls-v1.crt; do [ -s "$WORK_DIR/ipa/$f" ] || die "work/ipa/$f is missing. Run scripts/02-start-ipa.sh"; done

step "Namespace, service, mesh security and the locked way out to FreeIPA ($IPA_IP)"
apply_base

step "Secrets and settings for the blue (non-FIPS) pods"
new_session_key "$WORK_DIR/session-v1.key"
apply_secret "$APP_NS" fipsdemo-keytab-v1 "app.keytab=$WORK_DIR/ipa/app.keytab"
apply_secret "$APP_NS" fipsdemo-session-v1 "session.key=$WORK_DIR/session-v1.key"
apply_krb5_configmap legacy
apply_secret "$INGRESS_NS" fipsdemo-tls-v1 "tls.key=$WORK_DIR/ipa/tls-v1.key" "tls.crt=$WORK_DIR/ipa/tls-v1.crt" "ca.crt=$WORK_DIR/ipa/ca.crt"

step "Start the blue pods ($APP_IMAGE_NONFIPS)"
deploy_track blue "v1 non-FIPS first deploy"

step "Open the front door: all visitors -> blue"
apply_routing blue fipsdemo-tls-v1
k -n "$APP_NS" get pods -o wide

step "Test"
sleep 5
run_script 06-test.sh nonfips
log "Open in a browser:  $SITE_URL   (first add '127.0.0.1 $APP_HOSTNAME' to your hosts file and trust work/ipa/ca.crt)"
log "Login: $DEMO_USER / the DEMO_USER_PASSWORD from config.env"
