#!/bin/sh
# =============================================================================
#  The curl inspector — the same checklist as the Go inspector, written with
#  nothing but curl and sed, so you can read every single HTTP call.
#
#  Runs inside the curlimages/curl image (plain POSIX sh, no bash).
#  Needs: KEYCLOAK_URL KC_REALM TEST_CLIENT_ID JAVA_URL PYTHON_URL DEMO_USER_PASSWORD
#  Run it from your laptop too:
#     source scripts/00-config.sh; source scripts/.generated.env
#     KEYCLOAK_URL=$KEYCLOAK_PUBLIC_URL TEST_CLIENT_ID=grocery-test-client sh tests/curl-client/run-tests.sh
# =============================================================================
set -u

: "${KC_REALM:=grocery}"
: "${TEST_CLIENT_ID:=grocery-test-client}"
for v in KEYCLOAK_URL JAVA_URL PYTHON_URL DEMO_USER_PASSWORD; do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then echo "error: $v is not set"; exit 2; fi
done
KEYCLOAK_URL=${KEYCLOAK_URL%/}; JAVA_URL=${JAVA_URL%/}; PYTHON_URL=${PYTHON_URL%/}
TOKEN_URL="$KEYCLOAK_URL/realms/$KC_REALM/protocol/openid-connect/token"

PASS=0; FAIL=0

# token USER  -> prints the access token (password grant on the public test client)
token() {
  curl -sS --fail-with-body -X POST "$TOKEN_URL" \
    -d grant_type=password -d "client_id=$TEST_CLIENT_ID" -d scope=openid \
    -d "username=$1" -d "password=$DEMO_USER_PASSWORD" \
  | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# check NAME USER METHOD URL WANT [BODY]   ("-" as USER means: no token)
check() {
  name=$1; user=$2; method=$3; url=$4; want=$5; body=${6:-}
  auth=""
  if [ "$user" != "-" ]; then
    tok=$(token "$user")
    if [ -z "$tok" ]; then echo "FAIL  $name (could not get a token for $user)"; FAIL=$((FAIL+1)); return; fi
    auth="Authorization: Bearer $tok"
  fi
  if [ -n "$body" ]; then
    got=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$url" -H "Accept: application/json" \
          -H "Content-Type: application/json" -H "$auth" -d "$body")
  else
    got=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$url" -H "Accept: application/json" -H "$auth")
  fi
  if [ "$got" = "$want" ]; then
    echo "PASS  $name  ($method $url -> $got)"; PASS=$((PASS+1))
  else
    echo "FAIL  $name  ($method $url -> got $got, wanted $want)"; FAIL=$((FAIL+1))
  fi
}

echo "curl inspector: keycloak=$KEYCLOAK_URL realm=$KC_REALM java=$JAVA_URL python=$PYTHON_URL"
echo

echo "--- Java store ---"
check "no badge -> 401"                    -               GET  "$JAVA_URL/api/products"        401
check "public store-info"                  -               GET  "$JAVA_URL/api/public/store-info" 200
check "shopper sees products"              sam.shopper     GET  "$JAVA_URL/api/products"        200
check "shopper places an order"            sam.shopper     POST "$JAVA_URL/api/orders"          201 '{"items":[{"productId":2,"quantity":2}]}'
check "shopper sees own receipts"          sam.shopper     GET  "$JAVA_URL/api/orders/mine"     200
check "shopper cannot open the register"   sam.shopper     GET  "$JAVA_URL/api/orders"          403
check "shopper cannot read reports"        sam.shopper     GET  "$JAVA_URL/api/reports/sales"   403
check "cashier opens the register"         casey.cashier   GET  "$JAVA_URL/api/orders"          200
check "cashier cannot read reports"        casey.cashier   GET  "$JAVA_URL/api/reports/sales"   403
check "manager reads reports"              morgan.manager  GET  "$JAVA_URL/api/reports/sales"   200
check "manager reads the notebook"         morgan.manager  GET  "$JAVA_URL/api/activity"        200
check "LDAP manager riley reads reports"   riley.ldap      GET  "$JAVA_URL/api/reports/sales"   200
check "LDAP cashier jordan opens register" jordan.ldap     GET  "$JAVA_URL/api/orders"          200
check "LDAP shopper alex cannot"           alex.ldap       GET  "$JAVA_URL/api/orders"          403

echo
echo "--- Python deli ---"
check "no badge -> 401"                    -               GET  "$PYTHON_URL/api/tickets"       401
check "public menu"                        -               GET  "$PYTHON_URL/api/public/menu"   200
check "shopper creates a ticket"           sam.shopper     POST "$PYTHON_URL/api/tickets"       201 '{"item":"Turkey sandwich","notes":"from curl"}'
check "shopper cannot see the board"       sam.shopper     GET  "$PYTHON_URL/api/tickets"       403
check "cashier sees the board"             casey.cashier   GET  "$PYTHON_URL/api/tickets"       200
check "cashier cannot read the notebook"   casey.cashier   GET  "$PYTHON_URL/api/activity"      403
check "manager reads the notebook"         morgan.manager  GET  "$PYTHON_URL/api/activity"      200
check "LDAP cashier jordan sees the board" jordan.ldap     GET  "$PYTHON_URL/api/tickets"       200
check "LDAP shopper alex cannot"           alex.ldap       GET  "$PYTHON_URL/api/tickets"       403

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
