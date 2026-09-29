# 12 · Troubleshooting (when a door is stuck)

Golden rule: **read the pod's log first.** `kubectl -n <ns> logs <pod>` tells you 90% of the story.
To look inside a pod use `tools/shell.sh <target>`; to open Keycloak/Postgres/LDAP on your desktop use `tools/forward.sh` (doc 13).

## Finding things

```bash
scripts/10-status.sh                                   # everything at a glance
kubectl get pods -A | grep -v Running                  # who is unhappy?
kubectl -n apps describe pod -l app=java-store         # events at the bottom: image pull? probe failing? OOM?
kubectl -n apps logs deploy/java-store --tail=200
kubectl -n identity logs deploy/keycloak --tail=200
kubectl -n testing logs job/go-client-tests
```

## Symptoms → causes → fixes

### A script says `'BASE_DOMAIN' is not known yet`
You skipped a script. Values are discovered in order and saved in `scripts/.generated.env`. Run the earlier one.

### `ImagePullBackOff` on java-store / python-deli / go-client
* Script 07 did not run (or failed) → `scripts/07-build-images.sh`.
* `IMAGE_TAG` changed but images were not rebuilt → rebuild, then `08`.
* Registry not attached → `az aks update -n freshmart-aks -g freshmart-rg --attach-acr <acr>`.

### Keycloak pod restarts forever / `startupProbe failed`
* First start takes up to ~5 minutes on small VMs — patience (`failureThreshold: 90` × 5 s).
* Log says `Failed to obtain JDBC connection` → Postgres not ready or wrong password: `kubectl -n data get pods`,
  compare `KC_DB_PASSWORD` in `00-config.sh` with `values-generated.yaml` (delete the latter and re-run 05 with
  `REGENERATE_VALUES=true` after fixing).
* Log says `Realm 'grocery' already exists` → harmless (import is skipped after the first start).
* Log says `Hostname ... not valid` → `hostname` must be a full URL in `values-generated.yaml` (`http://keycloak.<domain>`).

### Browser login loops or "Invalid parameter: redirect_uri"
The redirect URI the app sends must match the client's `redirectUris` in Keycloak.
* Domain changed (new ingress IP after recreating the cluster) → `tools/reimport-realm.sh` re-renders the URIs.
* `http` vs `https` mismatch → set `ENABLE_TLS`, re-run 05, 08 and the re-import.
* Check what Keycloak has: `tools/kcadm.sh get clients -r grocery --fields clientId,redirectUris`.

### `Missing parameter: code_challenge_method`
The client requires PKCE (`pkce.code.challenge.method=S256`) but the app did not send it. Both included apps do;
a new app must too (or remove that attribute from its client).

### Everything is 403 for everyone
The token has no `roles` claim.
* The client is missing the `roles` protocol mapper → compare with `grocery-java-app` in the realm JSON.
* The app reads a different claim → `freshmart.roles-claim` (Java) / `ROLES_CLAIM` (Python) must be `roles`.
* Decode a token (doc 05, "Reading a badge yourself") and look.

### `401` from the API even with a token
* Token expired (5 minutes) — get a new one.
* Wrong issuer: the token's `iss` must equal the app's `OIDC_ISSUER` exactly (scheme, host, no trailing slash).
  Keycloak's `KC_HOSTNAME` decides `iss`; the app's env decides what it expects. Both come from `BASE_DOMAIN`+`PROTO`.
* Clock skew between pods — rare on AKS.

### Java app: `POST` from the browser returns 403 "CSRF"
The `XSRF-TOKEN` cookie must be echoed as the `X-XSRF-TOKEN` header. `js/app.js` does it; if you wrote your own
fetch, add the header. Bearer calls are exempt.

### LDAP users cannot log in
* `kubectl -n identity logs deploy/openldap` — did the seed load? (`ldap_add: Already exists` is fine.)
* Keycloak → Admin console → User federation → freshmart-ldap → *Test authentication*.
* Re-run `scripts/06-configure-realm.sh` (it syncs again).
* Passwords are checked *against LDAP*; the demo password is set in `seed.ldif` from `DEMO_USER_PASSWORD`.

### LDAP user logs in but has no cashier role
The group mapper did not sync or the LDAP group name differs from the Keycloak group name.
`tools/kcadm.sh get users -r grocery -q username=jordan.ldap` → then `.../groups`. Re-run 06.

### Playwright job fails with `Timeout ... #kc-login`
The robot never reached the login page: usually the app is not up (`kubectl -n apps get pods`) or the URL in
`test-config` is stale. `scripts/09-run-tests.sh` re-applies the Secret from the current config.

### `helm upgrade` says `another operation is in progress`
A previous install was interrupted: `helm -n identity rollback keycloak` or `helm -n identity uninstall keycloak` then re-run 05.

### Let's Encrypt certificate never appears
* `kubectl get certificate -A`, `kubectl describe challenge -A` — the HTTP challenge must reach your ingress on port 80.
* Rate limit hit (5 per host per week) — wait, or use the staging issuer while experimenting.

### Costs keep coming
`scripts/99-destroy.sh` removes everything in reverse order and ends by deleting the resource group; run it again if
a step failed (already-deleted things are skipped). Check with `az group list -o table` and
`az resource list -g freshmart-rg -o table`. `az aks stop` pauses a cluster you want to keep (the load balancer IP
is kept; VMs stop billing).

### `99-destroy.sh` hangs on "delete namespace …"
A namespace with a stuck finalizer (usually a cert-manager Challenge). Wait for the 3-minute timeout — the script
continues — then `kubectl get ns <name> -o json | jq '.spec.finalizers=[]' | kubectl replace --raw /api/v1/namespaces/<name>/finalize -f -`,
or simply let `az group delete` (the last step) remove the whole cluster.

## Reset buttons

| Problem area | Reset |
|--------------|-------|
| Keycloak realm | `tools/reimport-realm.sh` (overwrite) or delete the realm in the console and restart the pod (`kubectl -n identity rollout restart deploy/keycloak`) to re-import |
| Apps | `kubectl -n apps rollout restart deploy/java-store deploy/python-deli` |
| Notebook | `kubectl -n data exec -it postgres-0 -- psql -U grocery -d grocery -c 'TRUNCATE activity_log'` |
| Cluster contents only | `scripts/99-destroy.sh --keep-cluster` then start again from 02 |
| Everything | `scripts/99-destroy.sh` then start again from 01 |
