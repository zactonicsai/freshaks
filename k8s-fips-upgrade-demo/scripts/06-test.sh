#!/usr/bin/env bash
# 06-test.sh [nonfips|fips|auto] - tests the running app.   TRACK=green peeks at one side.   TEST_MODE=direct skips the mesh.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Results:  PASS / FAIL (something is broken -> exit code 1) / WARN (worth a look, does not stop an upgrade)
init test "$@"
need kubectl curl openssl jq
EXPECT="${1:-auto}"; TRACK="${TRACK:-}"; MODE="${TEST_MODE:-gateway}"
PASSES=0; FAILS=0; WARNS=0; PF_PID=""; TMP="$(mktemp -d)"
t_pass() { PASSES=$((PASSES + 1)); printf '%s [PASS ] %s\n' "$(ts)" "$*"; }
t_fail() { FAILS=$((FAILS + 1)); printf '%s [FAIL ] %s\n' "$(ts)" "$*"; }
t_warn() { WARNS=$((WARNS + 1)); printf '%s [WARN ] %s\n' "$(ts)" "$*"; }
cleanup_hook() { if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; fi; rm -rf "$TMP"; }

live="$(live_track)"; target="${TRACK:-$live}"
[ -n "$target" ] || die "cannot tell which side is live. Is the app deployed? (scripts/05-deploy-nonfips.sh)"
if [ "$EXPECT" = auto ]; then if [ "$target" = green ]; then EXPECT=fips; else EXPECT=nonfips; fi; fi
case "$EXPECT" in
  nonfips) W_PROFILE=legacy; W_MAC=HmacSHA1;   W_ETYPE=aes256-cts-hmac-sha1-96;    W_POLICY=DEFAULT ;;
  fips)    W_PROFILE=fips;   W_MAC=HmacSHA256; W_ETYPE=aes256-cts-hmac-sha384-192; W_POLICY=FIPS ;;
  *) die "usage: 06-test.sh [nonfips|fips|auto]" ;;
esac
track_settings "$target"
step "Testing side '$target' (live side: '${live:-none}'), expecting $EXPECT, mode $MODE"

if [ "$MODE" = direct ]; then     # straight to one pod with kubectl port-forward: no gateway, no TLS, no mesh
  port="${DIRECT_PORT:-18090}"
  # kubectl is started directly (not through the k helper) so that PF_PID is kubectl itself and can be stopped
  kubectl --context "$KUBE_CONTEXT" -n "$APP_NS" port-forward "deployment/fipsdemo-$target" "$port:8080" >"$TMP/port-forward.log" 2>&1 &
  PF_PID=$!
  sleep 2
  kill -0 "$PF_PID" 2>/dev/null || die "kubectl port-forward stopped at once (is port $port already in use?): $(cat "$TMP/port-forward.log")"
  BASE="http://127.0.0.1:$port"
  req() { curl -sS --max-time 20 "$@"; }
  wait_until "port-forward to fipsdemo-$target" 60 0.5 curl -fs "$BASE/healthz" || die "port-forward failed"
else                              # the real way in: HTTPS through the Istio gateway
  BASE="$SITE_URL"
  HDR=(); if [ -n "$TRACK" ]; then HDR=(-H "x-fipsdemo-track: $TRACK"); fi
  req() { site_curl ${HDR[@]+"${HDR[@]}"} "$@"; }
fi
code_of() { req -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }
body_of() { req "$@" 2>/dev/null || true; }
login_as() { # USER PASSWORD -> L_CODE, L_COOKIE
  L_CODE="$(req -o /dev/null -D "$TMP/headers" -w '%{http_code}' --data-urlencode "username=$1" --data-urlencode "password=$2" "$BASE/login" 2>/dev/null || true)"
  L_COOKIE="$(grep -i '^set-cookie:' "$TMP/headers" 2>/dev/null | sed -E 's/^[^:]+: *([^;]+);.*/\1/' | tr -d '\r' | head -1 || true)"
}

step "1. Pages"
body="$(body_of "$BASE/")"
if grep -q 'PUBLIC-PAGE-OK' <<<"$body"; then t_pass "public page opens without login"; else t_fail "public page did not open"; fi
c="$(code_of "$BASE/secure")"
if [ "$c" = 303 ]; then t_pass "secure page without login -> sent to the login page (HTTP 303)"; else t_fail "secure page without login gave HTTP $c (wanted 303)"; fi
login_as "$DEMO_USER" "certainly-the-wrong-password"
if [ "$L_CODE" = 401 ] && [ -z "$L_COOKIE" ]; then t_pass "wrong password is refused (HTTP 401)"; else t_fail "wrong password gave HTTP $L_CODE"; fi
login_as "$DEMO_USER" "$DEMO_USER_PASSWORD"
if [ "$L_CODE" = 303 ] && [ -n "$L_COOKIE" ]; then t_pass "FreeIPA Kerberos login of '$DEMO_USER' works"; else t_fail "login of '$DEMO_USER' gave HTTP $L_CODE"; fi
body="$(body_of -H "Cookie: $L_COOKIE" "$BASE/secure")"
if grep -q "SECURE-PAGE-OK: hello $DEMO_USER@$IPA_REALM" <<<"$body"; then t_pass "secure page greets $DEMO_USER@$IPA_REALM"; else t_fail "secure page did not open after login"; fi
if grep -q "<td>$W_ETYPE</td>" <<<"$body"; then t_pass "Kerberos ticket key type is $W_ETYPE"
else t_fail "Kerberos ticket key type is not $W_ETYPE (page says: $(grep -o 'aes[0-9]*-cts-hmac-[a-z0-9-]*' <<<"$body" | head -1 || true))"; fi

step "2. Crypto facts reported by the app (/status)"
status="$(body_of "$BASE/status")"
log "status: $status"
if grep -q "\"cryptoProfile\":\"$W_PROFILE\"" <<<"$status"; then t_pass "app crypto profile is '$W_PROFILE'"; else t_fail "app crypto profile is not '$W_PROFILE'"; fi
if grep -q "\"sessionMac\":\"$W_MAC\"" <<<"$status"; then t_pass "login cookies are signed with $W_MAC"; else t_fail "login cookies are not signed with $W_MAC"; fi
if grep -q '"selfTest":"passed"' <<<"$status"; then t_pass "start-up crypto self-test passed"; else t_fail "start-up crypto self-test did not pass"; fi
if grep -q "\"osCryptoPolicy\":\"$W_POLICY\"" <<<"$status"; then t_pass "Linux crypto policy inside the pod is $W_POLICY"; else t_warn "Linux crypto policy inside the pod is not $W_POLICY"; fi
keytab_types="$(grep -o '"keytabEnctypes":[^]]*]' <<<"$status" || true)"
if [ "$EXPECT" = fips ]; then
  if grep -q 'sha384-192' <<<"$keytab_types" && ! grep -q 'sha1' <<<"$keytab_types"; then t_pass "the pod's keytab holds SHA-2 keys only"; else t_fail "the pod's keytab is not SHA-2 only: $keytab_types"; fi
  if grep -q '"kernelFipsEnabled":"1"' <<<"$status"; then t_pass "node kernel is in FIPS mode (real FIPS)"
  elif [ "$REQUIRE_KERNEL_FIPS" = true ]; then t_fail "node kernel is NOT in FIPS mode but REQUIRE_KERNEL_FIPS=true"
  else t_warn "PRACTICE MODE: node kernel is not in FIPS mode. Everything else is set up the FIPS way, but this is not real FIPS."; fi
fi

step "3. Kubernetes facts"
ready="$(k -n "$APP_NS" get deployment "fipsdemo-$target" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
if [ "${ready:-0}" -ge 1 ]; then t_pass "deployment fipsdemo-$target has ${ready} ready pod(s)"; else t_fail "deployment fipsdemo-$target has no ready pods"; fi
pods_json="$(k -n "$APP_NS" get pods -l "app=fipsdemo,track=$target" -o json)"
wrong=0
for n in $(jq -r '.items[].spec.nodeName' <<<"$pods_json" | sort -u); do
  if ! node_has_label "$n" "$T_SELECTOR"; then wrong=1; fi
done
if [ "$wrong" = 0 ]; then t_pass "all $target pods run on nodes labelled $T_SELECTOR"; else t_fail "a $target pod runs on a node without label $T_SELECTOR"; fi
if [ "$MODE" = gateway ]; then
  proxies="$(jq -r '[.items[].spec | ((.containers // []) + (.initContainers // []))[] | select(.name == "istio-proxy")] | length' <<<"$pods_json")"
  if [ "${proxies:-0}" -ge 1 ]; then t_pass "app pods have an Istio sidecar proxy"; else t_fail "app pods have no Istio sidecar proxy"; fi
  mode_now="$(k -n "$APP_NS" get peerauthentication default -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || true)"
  if [ "$mode_now" = STRICT ]; then t_pass "mesh mutual TLS is STRICT in namespace $APP_NS"; else t_fail "mesh mutual TLS is '$mode_now', wanted STRICT"; fi
  if [ "$EXPECT" = fips ]; then
    if [ "$(mesh_policy_now)" = "$ISTIO_COMPLIANCE_POLICY" ]; then t_pass "istiod runs with COMPLIANCE_POLICY=$ISTIO_COMPLIANCE_POLICY"; else t_fail "istiod COMPLIANCE_POLICY is '$(mesh_policy_now)'"; fi
    if [ "$(gateway_policy_now)" = "$ISTIO_COMPLIANCE_POLICY" ]; then t_pass "ingress gateway runs with COMPLIANCE_POLICY=$ISTIO_COMPLIANCE_POLICY"; else t_fail "ingress gateway COMPLIANCE_POLICY is '$(gateway_policy_now)'"; fi
    side="$(jq -r '[.items[].spec | ((.containers // []) + (.initContainers // []))[] | select(.name == "istio-proxy") | (.env // [])[] | select(.name == "COMPLIANCE_POLICY") | .value] | unique | join(",")' <<<"$pods_json")"
    if [ "$side" = "$ISTIO_COMPLIANCE_POLICY" ]; then t_pass "app sidecars run with COMPLIANCE_POLICY=$ISTIO_COMPLIANCE_POLICY"; else t_fail "app sidecar COMPLIANCE_POLICY is '$side'"; fi
  fi
fi

if [ "$MODE" = gateway ]; then
  step "4. TLS at the front door (certificate from FreeIPA's CA)"
  tls_try() { openssl s_client -connect "127.0.0.1:$HOST_HTTPS_PORT" -servername "$APP_HOSTNAME" -CAfile "$WORK_DIR/ipa/ca.crt" "$@" </dev/null >"$TMP/tls.out" 2>&1 && grep -q 'Verify return code: 0' "$TMP/tls.out"; }
  if tls_try -tls1_2; then t_pass "TLS 1.2 works and the certificate chains to FreeIPA's CA"; else t_fail "TLS 1.2 handshake or certificate check failed"; fi
  cert_text="$(openssl x509 -noout -text < "$TMP/tls.out" 2>/dev/null || true)"
  bits="$(grep -o 'Public-Key: ([0-9]* bit)' <<<"$cert_text" | grep -o '[0-9]*' | head -1 || true)"
  if grep -q 'Signature Algorithm: sha\(256\|384\|512\)' <<<"$cert_text"; then t_pass "certificate is signed with a SHA-2 hash"; else t_fail "certificate is not signed with SHA-2"; fi
  if [ -z "$TRACK" ]; then
    want_bits="$TLS_KEY_BITS_NONFIPS"; if [ "$EXPECT" = fips ]; then want_bits="$TLS_KEY_BITS_FIPS"; fi
    if [ "${bits:-0}" -ge "$want_bits" ]; then t_pass "certificate key is RSA $bits bits (wanted $want_bits or more)"; else t_fail "certificate key is RSA ${bits:-?} bits, wanted $want_bits or more"; fi
  fi
  if tls_try -tls1_1; then t_warn "old TLS 1.1 was accepted"; else t_pass "old TLS 1.1 is refused"; fi
  if [ "$EXPECT" = fips ]; then
    if tls_try -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256; then t_warn "ChaCha20 (not FIPS approved) was accepted by the gateway"; else t_pass "ChaCha20 (not FIPS approved) is refused"; fi
    if tls_try -groups X25519; then t_warn "X25519 key exchange (not FIPS approved) was accepted by the gateway"; else t_pass "X25519 key exchange (not FIPS approved) is refused"; fi
    if tls_try -groups P-256; then t_pass "P-256 key exchange (FIPS approved) works"; else t_warn "P-256 key exchange did not work"; fi
  else
    if tls_try -groups X25519; then log "note: before the FIPS upgrade the gateway still accepts X25519 (fine for non-FIPS)"; fi
  fi

  step "5. Mutual TLS: the certificate page"
  c="$(code_of "$BASE/mtls")"
  if [ "$c" = 403 ]; then t_pass "certificate page without a client certificate is refused (HTTP 403)"; else t_fail "certificate page without a client certificate gave HTTP $c"; fi
  body="$(body_of --cert "$WORK_DIR/ipa/client.crt" --key "$WORK_DIR/ipa/client.key" "$BASE/mtls")"
  if grep -q 'MTLS-PAGE-OK' <<<"$body" && grep -q "CN=$CLIENT_HOSTNAME" <<<"$body"; then t_pass "certificate page opens with the FreeIPA client certificate (CN=$CLIENT_HOSTNAME)"; else t_fail "certificate page did not accept the FreeIPA client certificate"; fi
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/fake.key" -out "$TMP/fake.crt" -days 1 -subj "/CN=$CLIENT_HOSTNAME" >/dev/null 2>&1 || true
  c="$(code_of --cert "$TMP/fake.crt" --key "$TMP/fake.key" "$BASE/mtls")"
  if [ "$c" = 200 ]; then t_warn "a home-made client certificate was accepted (it must not be)"; else t_pass "a home-made client certificate (not from FreeIPA) is refused (HTTP ${c:-none})"; fi

  step "6. The way out of the pod (Istio REGISTRY_ONLY)"
  pod="$(jq -r '.items[0].metadata.name // empty' <<<"$pods_json")"
  # exit 0 = connection stays open (reachable), 7 = closed at once (blocked by the mesh), 9 = could not connect
  probe='exec 3<>"/dev/tcp/$0/$1" || exit 9; read -r -t 3 -n 1 _ <&3; if [ $? -gt 128 ]; then exit 0; else exit 7; fi'
  if [ -n "$pod" ]; then
    if k -n "$APP_NS" exec "$pod" -c app -- bash -c "$probe" "$IPA_HOSTNAME" 88 >/dev/null 2>&1; then t_pass "pod can reach FreeIPA Kerberos ($IPA_HOSTNAME:88)"; else t_warn "probe to $IPA_HOSTNAME:88 did not stay open (login works, so this is only a note)"; fi
    if k -n "$APP_NS" exec "$pod" -c app -- bash -c "$probe" "$IPA_HOSTNAME" 389 >/dev/null 2>&1; then t_warn "pod can reach $IPA_HOSTNAME:389, a port we did NOT allow"; else t_pass "pod can not use $IPA_HOSTNAME:389 (only port 88 is allowed out)"; fi
  fi
fi

step "RESULT for side '$target' ($EXPECT): $PASSES passed, $FAILS failed, $WARNS warnings"
if [ "$FAILS" -ne 0 ]; then exit 1; fi
