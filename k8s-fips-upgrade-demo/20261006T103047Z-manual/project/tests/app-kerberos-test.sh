#!/usr/bin/env bash
# Tests the Java app for real against a throw-away MIT Kerberos KDC on this machine.
# FreeIPA's Kerberos server IS MIT Kerberos, so the login behaviour is the same.
# Needs: a JDK (javac), krb5-kdc + krb5-admin-server + krb5-user, curl.  No Docker needed.
#   Ubuntu/Debian:  sudo apt-get install -y openjdk-25-jdk-headless krb5-kdc krb5-admin-server krb5-user curl
# Run as root (the KDC tools want that):  sudo tests/app-kerberos-test.sh
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="$PATH:/usr/sbin:/sbin"
for c in javac java krb5kdc kdb5_util kadmin.local ktutil klist curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "SKIP: '$c' is not installed (see the top of this file)"; exit 77; }
done

T="$(mktemp -d)"; PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; [ "${KEEP_TMP:-}" = 1 ] || rm -rf "$T"; }
trap cleanup EXIT
REALM=FIPSDEMO.TEST; DOMAIN=fipsdemo.test; SPN="HTTP/app.$DOMAIN"
KDC_TCP=18088; KDC_UDP_UNUSED=18099
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
expect_code() { local name="$1" want="$2"; shift 2; local got; got="$(curl -s -o /dev/null -w '%{http_code}' "$@")" || true
  if [ "$got" = "$want" ]; then ok "$name (HTTP $got)"; else bad "$name (wanted HTTP $want, got $got)"; fi; }

echo "== 1. Build a throw-away Kerberos realm $REALM in $T"
cat > "$T/kdc.conf" <<KDC
[kdcdefaults]
  kdc_listen = 127.0.0.1:$KDC_UDP_UNUSED
  kdc_tcp_listen = 127.0.0.1:$KDC_TCP
[realms]
  $REALM = {
    database_name = $T/principal
    key_stash_file = $T/stash
    acl_file = $T/kadm5.acl
    master_key_type = aes256-sha2
    supported_enctypes = aes256-sha2:normal aes128-sha2:normal aes256-cts:normal aes128-cts:normal
    default_principal_flags = +preauth
  }
[logging]
  kdc = FILE:$T/kdc.log
KDC
cat > "$T/krb5-admin.conf" <<ADM
[libdefaults]
  default_realm = $REALM
  dns_lookup_kdc = false
[realms]
  $REALM = {
    kdc = 127.0.0.1:$KDC_TCP
  }
ADM
export KRB5_KDC_PROFILE="$T/kdc.conf" KRB5_CONFIG="$T/krb5-admin.conf"
ALICE_PW='Alice-Passw0rd!'; BOB_PW='Bob-Passw0rd!'
kdb5_util create -s -r "$REALM" -P master-secret >/dev/null 2>&1
kadmin.local -q "addprinc -pw $ALICE_PW alice" >/dev/null                     # has SHA-1 and SHA-2 keys, like a FreeIPA user
kadmin.local -q "addprinc -pw $BOB_PW -e aes256-cts:normal,aes128-cts:normal bob" >/dev/null   # ONLY old SHA-1 keys
kadmin.local -q "addprinc -randkey $SPN" >/dev/null
kadmin.local -q "ktadd -k $T/app.keytab $SPN" >/dev/null
krb5kdc -n >"$T/kdc.out" 2>&1 & PIDS+=($!)
sleep 1
check "KDC is running (TCP $KDC_TCP only, so a pass means TCP was used)" kill -0 "${PIDS[0]}"
klist -kte "$T/app.keytab" | sed 's/^/        /'

echo "== 2. Render the SAME krb5.conf templates that the Kubernetes ConfigMaps use"
for p in legacy fips; do
  sed -e "s/__REALM__/$REALM/g" -e "s/__DOMAIN__/$DOMAIN/g" -e "s/__KDC_ADDR__/127.0.0.1:$KDC_TCP/g" \
      "$ROOT/k8s/app/krb5-$p.conf.tmpl" > "$T/krb5-$p.conf"
done
"$ROOT/scripts/helpers/filter-keytab-sha2.sh" "$T/app.keytab" "$T/app-sha2.keytab" | sed 's/^/        /'
head -c 48 /dev/urandom > "$T/session-v1.key"; head -c 48 /dev/urandom > "$T/session-v2.key"

echo "== 3. Compile the app"
mkdir -p "$T/classes"; javac -Xlint:all -Werror -d "$T/classes" "$ROOT"/app/src/demo/*.java && ok "javac (no warnings)"

start_app() { # name port profile krb5conf keytab sessionkey
  APP_PORT="$2" APP_CRYPTO_PROFILE="$3" APP_VERSION="test-$1" KRB_REALM="$REALM" KRB_SERVICE_PRINCIPAL="$SPN@$REALM" \
  KRB_KEYTAB="$5" SESSION_KEY_FILE="$6" COOKIE_SECURE=false APP_WEB_DIR="$ROOT/app/web" POD_NAME="pod-$1" NODE_NAME=testnode \
    java -Djava.security.krb5.conf="$4" -cp "$T/classes" demo.Main >"$T/app-$1.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 40); do curl -fs "http://127.0.0.1:$2/healthz" >/dev/null 2>&1 && return 0; sleep 0.25; done
  echo "app $1 did not start:"; cat "$T/app-$1.log"; return 1
}
start_app legacy 18080 legacy "$T/krb5-legacy.conf" "$T/app.keytab"      "$T/session-v1.key"
start_app fips   18081 fips   "$T/krb5-fips.conf"   "$T/app-sha2.keytab" "$T/session-v2.key"

login() { # port user password  -> prints "code cookie"
  curl -s -o /dev/null -D "$T/h" -w '%{http_code}' --data-urlencode "username=$2" --data-urlencode "password=$3" "http://127.0.0.1:$1/login" > "$T/code" || true
  printf '%s %s\n' "$(cat "$T/code")" "$(grep -i '^set-cookie:' "$T/h" | sed -E 's/^[^:]+: *([^;]+);.*/\1/' | tr -d '\r' | head -1)"
}
run_suite() { # name port mac enctype
  local name="$1" port="$2" mac="$3" etype="$4" base="http://127.0.0.1:$2" out code cookie
  echo "== 4. Page tests: $name app"
  check "$name: /healthz" curl -fs "$base/healthz"
  check "$name: public page shows the marker" bash -c "curl -fs $base/ | grep -q PUBLIC-PAGE-OK"
  expect_code "$name: secure page without login sends you to /login" 303 "$base/secure"
  check "$name: ...and the redirect points at /login" bash -c "curl -s -D - -o /dev/null $base/secure | grep -qi '^location: /login'"
  read -r code cookie <<<"$(login "$port" alice wrong-password)"
  [ "$code" = 401 ] && [ -z "$cookie" ] && ok "$name: wrong password is refused (HTTP 401, no cookie)" || bad "$name: wrong password gave HTTP $code"
  read -r code cookie <<<"$(login "$port" 'alice@EVIL.TEST' "$ALICE_PW")"
  [ "$code" = 401 ] && ok "$name: user name with @ is refused" || bad "$name: user name with @ gave HTTP $code"
  read -r code cookie <<<"$(login "$port" alice "$ALICE_PW")"
  [ "$code" = 303 ] && [ -n "$cookie" ] && ok "$name: correct password logs in (HTTP 303 + cookie)" || bad "$name: login gave HTTP $code"
  out="$(curl -s -H "Cookie: $cookie" "$base/secure")"
  grep -q "SECURE-PAGE-OK: hello alice@$REALM" <<<"$out" && ok "$name: secure page greets alice@$REALM" || bad "$name: secure page did not open"
  grep -q "<td>$etype</td>" <<<"$out" && ok "$name: Kerberos ticket key type is $etype" || bad "$name: wrong ticket key type: $(grep -o 'aes[0-9a-z-]*' <<<"$out" | head -1)"
  out="$(curl -s "$base/status")"
  grep -q "\"sessionMac\":\"$mac\"" <<<"$out" && ok "$name: session cookies are signed with $mac" || bad "$name: wrong MAC in $out"
  grep -q '"selfTest":"passed"' <<<"$out" && ok "$name: start-up crypto self-test passed" || bad "$name: self-test: $out"
  expect_code "$name: a changed cookie is refused" 303 -H "Cookie: ${cookie}x" "$base/secure"
  expect_code "$name: certificate page without a certificate" 403 "$base/mtls"
  local xfcc='By=spiffe://cluster.local/ns/istio-ingress/sa/istio-ingressgateway;Hash=468ed33be74eee6556d90c0149c1309e9ba61d6425303443c0748a02dd8de688;Cert="-----BEGIN%20CERTIFICATE-----%0AMIIB%0A-----END%20CERTIFICATE-----%0A";Subject="CN=tester.fipsdemo.test,O=FIPSDEMO.TEST";URI=;DNS=tester.fipsdemo.test,By=spiffe://cluster.local/ns/fipsdemo/sa/fipsdemo;Hash=abc;Subject="";URI=spiffe://cluster.local/ns/istio-ingress/sa/istio-ingressgateway'
  check "$name: certificate page shows the subject from the gateway header" bash -c "curl -fs -H 'X-Forwarded-Client-Cert: $xfcc' $base/mtls | grep -q 'CN=tester.fipsdemo.test,O=FIPSDEMO.TEST'"
  expect_code "$name: mesh-only header (empty Subject) is NOT a client certificate" 403 -H 'X-Forwarded-Client-Cert: By=spiffe://a;Hash=abc;Subject="";URI=spiffe://b' "$base/mtls"
  expect_code "$name: unknown page" 404 "$base/nope"
  eval "COOKIE_$name=\$cookie"
}
run_suite legacy 18080 HmacSHA1   aes256-cts-hmac-sha1-96
run_suite fips   18081 HmacSHA256 aes256-cts-hmac-sha384-192

echo "== 5. Upgrade lessons, proven"
expect_code "a cookie from the old (legacy) pod is refused by the FIPS pod (users log in again at cut-over)" 303 -H "Cookie: $COOKIE_legacy" http://127.0.0.1:18081/secure
st="$(curl -s http://127.0.0.1:18081/status | grep -o '"keytabEnctypes":[^]]*]')"
if grep -q sha384-192 <<<"$st" && grep -q sha256-128 <<<"$st" && ! grep -q sha1 <<<"$st"; then
  ok "FIPS pod keytab holds only the two SHA-2 keys"; else bad "FIPS keytab content: $st"; fi
read -r code cookie <<<"$(login 18080 bob "$BOB_PW")"
[ "$code" = 303 ] && ok "bob (only SHA-1 keys in the KDC) can log in to the legacy pod" || bad "bob legacy login gave HTTP $code"
read -r code cookie <<<"$(login 18081 bob "$BOB_PW")"
[ "$code" = 401 ] && ok "bob can NOT log in to the FIPS pod -> this is why the upgrade checks every account for SHA-2 keys first" || bad "bob FIPS login gave HTTP $code"
grep -q 'FAILED user=bob' "$T/app-fips.log" && echo "        app log: $(grep 'FAILED user=bob' "$T/app-fips.log" | tail -1 | cut -c1-160)"

echo "== 6. The rollback trap: making NEW service keys breaks every OLD keytab"
cp "$T/app.keytab" "$T/app-before-rotation.keytab"
kadmin.local -q "ktadd -k $T/app-rotated.keytab -e aes256-sha2:normal,aes128-sha2:normal $SPN" >/dev/null
start_app oldkey 18082 legacy "$T/krb5-legacy.conf" "$T/app-before-rotation.keytab" "$T/session-v1.key"
start_app newkey 18083 fips   "$T/krb5-fips.conf"   "$T/app-rotated.keytab"         "$T/session-v2.key"
read -r code cookie <<<"$(login 18082 alice "$ALICE_PW")"
[ "$code" = 401 ] && ok "after key rotation the OLD keytab no longer works (so rotate only in the finalize step)" || bad "old keytab after rotation gave HTTP $code"
read -r code cookie <<<"$(login 18083 alice "$ALICE_PW")"
[ "$code" = 303 ] && ok "the NEW SHA-2-only keytab works" || bad "new keytab gave HTTP $code"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
