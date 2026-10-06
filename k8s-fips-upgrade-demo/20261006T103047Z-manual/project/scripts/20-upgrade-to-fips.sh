#!/usr/bin/env bash
# 20-upgrade-to-fips.sh - the safe upgrade: check, save, build green (FIPS, SHA-2), test it, switch visitors, test again. Undoes itself if a check fails.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init upgrade-to-fips "$@"
need kubectl jq openssl curl
T0=$SECONDS
PRE_SNAPSHOT=""

# ------------------------------------------------------------------ Phase 0
step "PHASE 0 - look before you leap (nothing is changed in this phase)"
load_ipa_env
[ "$(live_track)" = blue ] || die "visitors are not on the blue side (live side: '$(live_track)'). Already upgraded? To go back: scripts/30-rollback.sh"
run_script 06-test.sh nonfips || die "the current system does not pass its own tests. Fix that first: never upgrade something that is already broken."
green_nodes="$(nodes_of_selector "$GREEN_NODE_SELECTOR")"
[ -n "$green_nodes" ] || die "no node carries the label $GREEN_NODE_SELECTOR (the green, FIPS node pool)"
all_fips=1
for n in $green_nodes; do
  if [ "$(node_kernel_fips "$n")" = 1 ]; then ok "green node $n: kernel FIPS mode is ON"; else all_fips=0; warn "green node $n: kernel FIPS mode is OFF"; fi
done
if [ "$all_fips" = 0 ]; then
  [ "$REQUIRE_KERNEL_FIPS" != true ] || die "REQUIRE_KERNEL_FIPS=true, and a green node is not booted in FIPS mode. Stopping before any change."
  warn "################################################################################"
  warn "#  PRACTICE MODE: the green nodes do not run a FIPS-mode kernel.               #"
  warn "#  You will practise every step of the upgrade, and all the SHA-2 settings     #"
  warn "#  are real, but the result is NOT a real FIPS system.                         #"
  warn "#  For a real one: nodes booted with fips=1 + validated crypto modules,        #"
  warn "#  and set REQUIRE_KERNEL_FIPS=true in config.env.                             #"
  warn "################################################################################"
fi
for p in "$DEMO_USER" "$SPN"; do
  ipa_principal_has_sha2 "$p" || die "FreeIPA has no SHA-2 Kerberos key for '$p'. A FIPS pod could not log that account in. Fix: let the user change the password once (that makes the new keys)."
  ok "FreeIPA holds a SHA-2 key for $p"
done

# ------------------------------------------------------------------ Phase 1
step "PHASE 1 - save the current state (this is the place we can always come back to)"
run_script 10-save-state.sh --label pre-fips
PRE_SNAPSHOT="$(cat "$STATE_DIR/LATEST")"
printf 'PRE_SNAPSHOT=%s\nSTARTED_UTC=%s\n' "$PRE_SNAPSHOT" "$(ts)" > "$WORK_DIR/last-upgrade.env"
ok "safe point: $PRE_SNAPSHOT"

fail_and_rollback() {
  err "$1"
  if [ "$AUTO_ROLLBACK" = true ]; then
    warn "AUTO_ROLLBACK is on: putting everything back the way snapshot $PRE_SNAPSHOT says"
    if ASSUME_YES=1 run_script 30-rollback.sh --full --snapshot "$PRE_SNAPSHOT" --no-snapshot; then
      warn "the upgrade was UNDONE. You are back on the non-FIPS (blue) system, which passed its tests."
    else
      err "the automatic rollback had a problem too. Read the log, then run: scripts/30-rollback.sh --full --snapshot $PRE_SNAPSHOT"
    fi
  else
    warn "AUTO_ROLLBACK=false, so nothing was undone. Fix the problem and run this script again, or run scripts/30-rollback.sh"
  fi
  exit 1
}

# From here on a failed command or failed check ends the sub-shell below, and we roll back.
set +e
(
  set -e
  # ---------------------------------------------------------------- Phase 2
  step "PHASE 2 - build the FIPS image"
  build_and_load_image fips

  # ---------------------------------------------------------------- Phase 3
  step "PHASE 3 - EXPAND: add the new FIPS things next to the old ones (the old ones keep working)"
  log "keytab: a copy with only the SHA-2 keys. The keys in FreeIPA are NOT changed, so blue keeps working."
  ipa_filter_keytab "$WORK_DIR/ipa/app.keytab" "$WORK_DIR/ipa/app-sha2.keytab"
  new_session_key "$WORK_DIR/session-v2.key"
  apply_secret "$APP_NS" fipsdemo-keytab-v2 "app.keytab=$WORK_DIR/ipa/app-sha2.keytab"
  apply_secret "$APP_NS" fipsdemo-session-v2 "session.key=$WORK_DIR/session-v2.key"
  apply_krb5_configmap fips
  if [ ! -s "$WORK_DIR/ipa/tls-v2.crt" ]; then
    log "new TLS key (RSA $TLS_KEY_BITS_FIPS bits) and a new certificate from FreeIPA's CA"
    ipa_issue_cert "$SPN" "$APP_HOSTNAME" "$TLS_KEY_BITS_FIPS" "$WORK_DIR/ipa/tls-v2"
  fi
  apply_secret "$INGRESS_NS" fipsdemo-tls-v2 "tls.key=$WORK_DIR/ipa/tls-v2.key" "tls.crt=$WORK_DIR/ipa/tls-v2.crt" "ca.crt=$WORK_DIR/ipa/ca.crt"

  # ---------------------------------------------------------------- Phase 4
  step "PHASE 4 - mesh: switch Istio to the FIPS TLS rules ($ISTIO_COMPLIANCE_POLICY)"
  mesh_install "$ISTIO_COMPLIANCE_POLICY"
  [ "$(mesh_policy_now)" = "$ISTIO_COMPLIANCE_POLICY" ] || { err "istiod did not take the policy"; exit 1; }
  gateway_restart
  log "GATE: do the old blue pods still work behind the FIPS-policy gateway?"
  run_script 06-test.sh nonfips
  ok "GATE passed: blue still works"

  # ---------------------------------------------------------------- Phase 5
  step "PHASE 5 - start the green (FIPS) pods on the green nodes. Visitors still go to blue."
  deploy_track green "v2 FIPS, SHA-2 only"
  k -n "$APP_NS" get pods -o wide

  # ---------------------------------------------------------------- Phase 6
  step "PHASE 6 - GATE: test green through the real front door, using the secret preview header"
  TRACK=green run_script 06-test.sh fips
  ok "GATE passed: green is healthy and FIPS-configured"

  # ---------------------------------------------------------------- Phase 7
  step "PHASE 7 - CUT-OVER: send all visitors to green and show the new certificate"
  apply_routing green fipsdemo-tls-v2
  sleep 8        # give the proxies a moment to receive the new rules
  log "GATE: the full test again, now as a normal visitor"
  run_script 06-test.sh fips
  ok "GATE passed: visitors are served by the FIPS side"
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail_and_rollback "the upgrade stopped in the phase shown above"

# ------------------------------------------------------------------ Phase 8
step "PHASE 8 - save the new state"
run_script 10-save-state.sh --label post-fips || warn "could not save the post-upgrade snapshot (the upgrade itself is fine)"
printf 'FINISHED_UTC=%s\nPOST_SNAPSHOT=%s\n' "$(ts)" "$(cat "$STATE_DIR/LATEST")" >> "$WORK_DIR/last-upgrade.env"
step "UPGRADE DONE in $((SECONDS - T0)) seconds"
log "Visitors are on green (FIPS, SHA-2). Blue is still running, untouched, as your safety net."
log "  - changed your mind?  scripts/30-rollback.sh          (seconds: just flips the traffic back)"
log "  - undo everything?    scripts/30-rollback.sh --full    (back to snapshot $PRE_SNAPSHOT)"
log "  - happy after a few days of watching?  scripts/50-finalize-fips.sh   (removes blue; that step can NOT be undone quickly)"
