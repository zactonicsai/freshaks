# 09 · Adding a new service (a new door that trusts the same front office)

Say Fresh Mart opens a **bakery** — a new web app, maybe in a third language. It must: let people log in with the
same badge, respect the same roles, and write to the same notebook. Here is the recipe, then the details.

## Step by step

```bash
# 1. register the door in Keycloak + create k8s manifests + add it to the realm file
tools/add-service.sh bakery 'bakery-secret-123'
#    -> Keycloak client grocery-bakery-app (confidential, PKCE, roles mapper)
#    -> k8s/apps/bakery/{deployment,service,ingress}.yaml (from k8s/_templates/new-service)
#    -> helm/keycloak/realms/grocery-realm.json gets the client (secret as a placeholder)

# 2. write the app
cp -r apps/python-deli-app apps/bakery          # easiest start: copy the deli and change the routes
#    it must read OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, DATABASE_URL and answer /healthz

# 3. build the image in the cloud
source scripts/00-config.sh; source scripts/.generated.env
az acr build --registry "$ACR_NAME" --image "freshmart/bakery:$IMAGE_TAG" apps/bakery

# 4. deploy (fills in the manifests and waits for the pod)
tools/add-service.sh --deploy bakery 'bakery-secret-123'
#    -> http://bakery.<INGRESS_IP>.nip.io
```

Log in as `casey.cashier` in the bakery and you are already logged in: same Keycloak session, same roles.

## What `add-service.sh` really does (so you could do it by hand)

1. **Keycloak client** — via `kcadm create clients -r grocery -f -` with JSON like the two existing clients:
   `publicClient: false`, a `secret`, `redirectUris: ["<proto>://bakery.<domain>/*"]`, `post.logout.redirect.uris: "+"`,
   `pkce.code.challenge.method: "S256"` and the **`roles` protocol mapper** (without it the badge has no `roles` claim
   and every door says 403).
2. **Manifests** — `k8s/_templates/new-service/` uses `${SERVICE_NAME}`, `${CLIENT_ID}`, `${CLIENT_SECRET}`,
   `${REGISTRY}`, `${IMAGE_TAG}`, plus the usual `${NS_APPS}` and ingress variables. `--deploy` exports those and runs
   `envsubst | kubectl apply`. Edit the container port / probes / env to match your app.
3. **Realm file** — the client is appended with the secret replaced by `__BAKERY_CLIENT_SECRET__`. If you want a
   *fresh* install to know that secret, add one more `| replace "__BAKERY_CLIENT_SECRET__" $.Values.realm.bakeryClientSecret`
   line to `helm/keycloak/templates/configmap-realms.yaml` and the value to `values.yaml`.

## Checklist for the app itself

* Read the issuer from `OIDC_ISSUER` and use **discovery**; never hard-code Keycloak URLs.
* Use the Authorization Code flow **with PKCE** for browsers; accept `Authorization: Bearer` for APIs.
* Read roles from the `roles` claim. Turn them into your framework's idea of roles.
* Decide doors by role, default to "must be logged in".
* Write to `activity_log` (same columns — copy the DDL from `db.py` or `schema.sql`) with `service = "bakery"`.
* Answer `/healthz` (or set the probe path in the deployment).
* Log out through Keycloak's end-session endpoint.

## Adding a role at the same time?

`tools/add-role.sh baker "Bakes bread"` creates role `baker` + group `bakers`. Then protect bakery doors with it.
See the [stocker tutorial](tutorials/tutorial-add-a-stocker-role.md).

## Pros and cons of "one realm, many clients"

| | One realm, one client per app (what we do) | One realm per app |
|-|--------------------------------------------|-------------------|
| Single sign-on | yes — one login, every shop | no |
| Roles | shared vocabulary | duplicated |
| Blast radius | a bad client config affects one door | fully isolated |
| When to prefer | apps of one organisation | separate customers / tenants |
