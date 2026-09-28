# Tutorial · Add a person to the LDAP phone book

**Goal:** a new employee, `pat.ldap`, joins the `cashiers` team in LDAP and can immediately work the register in
both shops — without touching Keycloak by hand. About 10 minutes.

## Step 1 — add the entry to LDAP (3 min)

Create `pat.ldif` (replace the base DN if you changed `LDAP_BASE_DN`):

```ldif
dn: uid=pat.ldap,ou=people,dc=freshmart,dc=local
objectClass: inetOrgPerson
uid: pat.ldap
cn: Pat Ldap
sn: Ldap
givenName: Pat
mail: pat.ldap@freshmart.local
userPassword: password123

dn: cn=cashiers,ou=groups,dc=freshmart,dc=local
changetype: modify
add: member
member: uid=pat.ldap,ou=people,dc=freshmart,dc=local
```

Load it into the running OpenLDAP pod:

```bash
source scripts/00-config.sh
kubectl -n identity cp pat.ldif "$(kubectl -n identity get pod -l app=openldap -o jsonpath='{.items[0].metadata.name}')":/tmp/pat.ldif
kubectl -n identity exec deploy/openldap -- ldapmodify -a -x -H ldap://localhost \
  -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_ADMIN_PASSWORD" -f /tmp/pat.ldif
```

(`ldapmodify -a` adds the new entry and applies the `modify` on the group in one go.)

To make it permanent for fresh installs, append the same two blocks to `k8s/openldap/seed.ldif`
(use `${LDAP_BASE_DN}` and `${DEMO_USER_PASSWORD}` there, like the existing entries).

## Step 2 — let the front office notice (1 min)

```bash
scripts/06-configure-realm.sh        # re-runs the group sync + full user sync
tools/kcadm.sh get users -r grocery -q username=pat.ldap --fields username,federationLink
```

Pat appears with `federationLink` set (from LDAP) and, because LDAP group `cashiers` maps to Keycloak group
`cashiers`, already has the `cashier` role. Without the sync, Pat would still be imported at first login — the sync
just makes it visible now.

## Step 3 — try the doors (2 min)

* Java store → Log in as `pat.ldap` / `password123` → **Register** link is there; **Office** is not.
* Python deli → `/tickets` opens; `/admin` shows the "different badge" page.

Or with the API:

```bash
source scripts/.generated.env
TOKEN=$(curl -s -X POST "$PROTO://keycloak.$BASE_DOMAIN/realms/grocery/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=grocery-test-client -d username=pat.ldap -d "password=$DEMO_USER_PASSWORD" | jq -r .access_token)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" "$PROTO://java.$BASE_DOMAIN/api/orders"        # 200
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" "$PROTO://java.$BASE_DOMAIN/api/reports/sales" # 403
```

## Step 4 — add Pat to the inspectors (optional)

Add two rows (200 on `/api/orders`, 403 on `/api/reports/sales`) to `Checklist()` in `tests/go-client/main.go`
and to `tests/curl-client/run-tests.sh`, then `scripts/07-build-images.sh go && scripts/09-run-tests.sh`.

## What you learned

* The phone book is the source of truth for federated people; Keycloak only mirrors it.
* Passwords never leave LDAP — Keycloak asks LDAP "is this password right?".
* Group names are the glue: same name in LDAP and Keycloak → same team → same badge.
