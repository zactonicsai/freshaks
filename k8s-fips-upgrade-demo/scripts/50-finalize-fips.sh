#!/usr/bin/env bash
# 50-finalize-fips.sh [--yes] [--keep-blue-nodes] - CONTRACT: remove the old non-FIPS side for good and rotate the keys. No quick way back after this.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init finalize-fips "$@"
need kubectl jq
DRAIN=1
while [ $# -gt 0 ]; do
  case "$1" in --yes) ASSUME_YES=1; shift ;; --keep-blue-nodes) DRAIN=0; shift ;; *) die "usage: 50-finalize-fips.sh [--yes] [--keep-blue-nodes]" ;; esac
done
[ "$(live_track)" = green ] || die "visitors are not on green (live side: '$(live_track)'). Finish scripts/20-upgrade-to-fips.sh first."
run_script 06-test.sh fips || die "the FIPS side does not pass its tests. Not finalizing."
confirm "FINALIZE removes the blue (non-FIPS) pods, empties the blue nodes and makes NEW Kerberos keys.
After this, going back needs a full restore from a snapshot (and FreeIPA data from --with-ipa-data)." FINALIZE

step "1. Last safe point"
run_script 10-save-state.sh --label pre-finalize

step "2. Remove the blue side and its old-style secrets"
k -n "$APP_NS" delete deployment fipsdemo-blue --ignore-not-found
k -n "$APP_NS" delete secret fipsdemo-keytab-v1 fipsdemo-session-v1 --ignore-not-found
k -n "$APP_NS" delete configmap fipsdemo-krb5-legacy --ignore-not-found
k -n "$INGRESS_NS" delete secret fipsdemo-tls-v1 --ignore-not-found
log "the old certificate should also be revoked in FreeIPA:  ipa cert-revoke <serial> --revocation-reason=4"

step "3. Empty the blue (non-FIPS) nodes so that EVERYTHING, also Istio itself, runs on green nodes"
if [ "$DRAIN" = 1 ] && [ "$BLUE_NODE_SELECTOR" != "$GREEN_NODE_SELECTOR" ]; then
  for n in $(nodes_of_selector "$BLUE_NODE_SELECTOR"); do
    if node_has_label "$n" "$GREEN_NODE_SELECTOR"; then warn "node $n is blue AND green, not draining it"; continue; fi
    k cordon "$n"
    k drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout=300s
    ok "node $n is empty. In a real cluster you now delete this node pool."
  done
  rollout_wait "$ISTIO_NS" deployment/istiod
  rollout_wait "$INGRESS_NS" deployment/istio-ingressgateway
else
  warn "skipping the node drain"
fi

step "4. Rotate the app's Kerberos keys: brand-new keys, SHA-2 types only"
log "FreeIPA makes new keys now. Every older keytab (also the one inside old snapshots) stops working."
ipa_new_service_keytab "$WORK_DIR/ipa/app-sha2-rotated.keytab" "aes256-sha2,aes128-sha2"
apply_secret "$APP_NS" fipsdemo-keytab-v2 "app.keytab=$WORK_DIR/ipa/app-sha2-rotated.keytab"
k -n "$APP_NS" rollout restart deployment/fipsdemo-green >/dev/null
rollout_wait "$APP_NS" deployment/fipsdemo-green

step "5. Test and save the final state"
sleep 5
run_script 06-test.sh fips
run_script 10-save-state.sh --label post-finalize
ok "FINALIZED. Only the FIPS (green) side is left."
