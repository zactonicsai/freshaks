#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
#  lib/deploy.sh - the Kubernetes objects of the app. Used by deploy, upgrade and rollback.
#  "blue"  = the old, non-FIPS side      "green" = the new, FIPS side
# ============================================================================

load_ipa_env() {
  [ -f "$WORK_DIR/ipa/ipa.env" ] || die "no $WORK_DIR/ipa/ipa.env. Run scripts/02-start-ipa.sh first."
  # shellcheck disable=SC1091
  source "$WORK_DIR/ipa/ipa.env"
  [ -n "${IPA_IP:-}" ] || die "IPA_IP is empty in $WORK_DIR/ipa/ipa.env"
}
# Sets T_* for one side.
track_settings() {
  case "$1" in
    blue)  T_IMAGE="$APP_IMAGE_NONFIPS"; T_PROFILE=legacy; T_KEYTAB=fipsdemo-keytab-v1; T_SESSION=fipsdemo-session-v1; T_SELECTOR="$BLUE_NODE_SELECTOR" ;;
    green) T_IMAGE="$APP_IMAGE_FIPS";    T_PROFILE=fips;   T_KEYTAB=fipsdemo-keytab-v2; T_SESSION=fipsdemo-session-v2; T_SELECTOR="$GREEN_NODE_SELECTOR" ;;
    *) die "unknown track '$1' (use blue or green)" ;;
  esac
}
apply_krb5_configmap() { # legacy|fips
  local file="$WORK_DIR/krb5-$1.conf"
  render "$ROOT_DIR/k8s/app/krb5-$1.conf.tmpl" "REALM=$IPA_REALM" "DOMAIN=$IPA_DOMAIN" "KDC_ADDR=$IPA_HOSTNAME:88" > "$file"
  apply_configmap "$APP_NS" "fipsdemo-krb5-$1" "krb5.conf=$file"
}
new_session_key() { # FILE : 48 random bytes for signing login cookies
  [ -s "$1" ] || { openssl rand -out "$1" 48; chmod 600 "$1"; }
}
# Namespace, service account, service, mesh security rules and the "way out" to FreeIPA.
apply_base() {
  load_ipa_env
  render "$ROOT_DIR/k8s/app/base.tmpl.yaml" "APP_NS=$APP_NS" "INGRESS_NS=$INGRESS_NS" \
    "IPA_IP=$IPA_IP" "IPA_HOSTNAME=$IPA_HOSTNAME" | k apply -f -
}
deploy_track() { # blue|green "why"
  local color="$1" cause="$2"
  load_ipa_env; track_settings "$color"
  render "$ROOT_DIR/k8s/app/deployment.tmpl.yaml" "COLOR=$color" "APP_NS=$APP_NS" "IMAGE=$T_IMAGE" \
    "VERSION=${T_IMAGE##*:}" "PROFILE=$T_PROFILE" "KEYTAB_SECRET=$T_KEYTAB" "SESSION_SECRET=$T_SESSION" \
    "NODE_KEY=$(sel_key "$T_SELECTOR")" "NODE_VALUE=$(sel_val "$T_SELECTOR")" "REPLICAS=$APP_REPLICAS" \
    "IPA_IP=$IPA_IP" "IPA_HOSTNAME=$IPA_HOSTNAME" "REALM=$IPA_REALM" "SPN=$SPN@$IPA_REALM" "CHANGE_CAUSE=$cause" | k apply -f -
  rollout_wait "$APP_NS" "deployment/fipsdemo-$color"
}
# Who gets the visitors (LIVE_TRACK) and which certificate the gateway shows (TLS_SECRET).
apply_routing() { # blue|green TLS_SECRET
  render "$ROOT_DIR/k8s/app/routing.tmpl.yaml" "APP_NS=$APP_NS" "INGRESS_NS=$INGRESS_NS" \
    "APP_HOSTNAME=$APP_HOSTNAME" "LIVE_TRACK=$1" "TLS_SECRET=$2" | k apply -f -
  ok "visitors now go to: $1    gateway certificate: $2"
}
tls_secret_now() { k -n "$INGRESS_NS" get gateways.networking.istio.io fipsdemo-gateway -o jsonpath='{.spec.servers[0].tls.credentialName}' 2>/dev/null || true; }
