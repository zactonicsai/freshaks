# 03 · Keycloak, the front office (Helm chart + realm)

## Background

**Keycloak** is an open-source *identity provider*: a program whose only job is to know who people are and to hand
out badges (tokens) other programs can trust. It speaks the standard languages **OpenID Connect (OIDC)** and
**OAuth 2.0**, so the Java store, the Python deli and any future app can use it the same way.

Keycloak vocabulary, in store language:

| Keycloak word | Store meaning |
|---------------|---------------|
| **Realm** | one whole store with its own staff list, doors and rules. We have one realm: `grocery`. (The built-in `master` realm is the landlord's office: it only manages other realms.) |
| **Client** | a *door* that trusts the front office. `grocery-java-app`, `grocery-python-app`, `grocery-test-client`. |
| **User** | a person. |
| **Role** | a job title stamped on the badge: `shopper`, `cashier`, `manager`. |
| **Group** | a team. Joining `cashiers` gives you the `cashier` role. Groups make "give this person a job" a one-click task. |
| **User federation** | "also trust this other list of people" — our OpenLDAP phone book. |
| **Protocol mapper** | the rule that copies information (like roles) onto the badge. |

## The Helm chart (the recipe card)

**Helm** packages Kubernetes manifests as templates. The chart lives in `helm/keycloak/`:

```
helm/keycloak/
├── Chart.yaml               name/version of the recipe
├── values.yaml              the ingredients with sensible defaults (what you may change)
├── values-generated.yaml    written by scripts/05 from 00-config.sh (git-ignored)
├── realms/grocery-realm.json  the whole store: roles, groups, users, clients
└── templates/
    ├── _helpers.tpl         small reusable snippets (labels, names)
    ├── secret.yaml          admin + database passwords
    ├── configmap-realms.yaml  the realm file, with __PLACEHOLDERS__ filled in
    ├── deployment.yaml      the Keycloak pod itself
    ├── service.yaml         a stable name inside the cluster
    ├── ingress.yaml         the public door keycloak.<domain>
    └── NOTES.txt            what Helm prints after install
```

The pod runs the official image `quay.io/keycloak/keycloak:26.3` with `start --import-realm`. Important settings
(all in `values.yaml` → environment variables in `deployment.yaml`):

| values.yaml | env var | why |
|-------------|---------|-----|
| `hostname` | `KC_HOSTNAME` | the public URL; it becomes the **issuer** written into every token |
| `httpEnabled: true`, `proxyHeaders: xforwarded` | `KC_HTTP_ENABLED`, `KC_PROXY_HEADERS` | we sit behind ingress-nginx which talks plain http to the pod |
| `database.*` | `KC_DB`, `KC_DB_URL`, `KC_DB_USERNAME/PASSWORD` | Postgres in the `data` namespace |
| `admin.*` | `KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD` | the first admin (Keycloak 26 naming) |
| `realm.import: true` | `--import-realm` + a mounted ConfigMap | load `realms/*.json` on first start |
| `realm.sslRequired` | inside the realm JSON | `none` for http demos, `external` with TLS |

`KC_HEALTH_ENABLED=true` opens `/health/*` on the management port 9000 — the probes in `deployment.yaml` use it.
`KC_CACHE=local` keeps things simple with one replica (clustering is a topic for another day).

### Placeholders: how the realm file learns your domain

`realms/grocery-realm.json` contains tokens like `__BASE_DOMAIN__`, `__PROTO__`, `__JAVA_CLIENT_SECRET__`.
`templates/configmap-realms.yaml` replaces them with Helm's `replace` function using values from `values.yaml`:

```yaml
{{ $.Files.Get $path | replace "__BASE_DOMAIN__" $.Values.realm.baseDomain | replace "__PROTO__" $.Values.realm.proto ... }}
```

So the same file works for `http://java.20.1.2.3.nip.io` and for `https://java.example.com`.

### Realm import happens ONCE

`--import-realm` only creates a realm that does not exist yet. After that, Keycloak keeps its own copy in Postgres.
If you edit the JSON later:

```bash
tools/reimport-realm.sh          # partial import with OVERWRITE into the running Keycloak
```

or change things in the admin console (`http://keycloak.<domain>/admin/`, user `admin`). Both are fine; the JSON file
is the version you can put in git.

## Changing the chart from a script (sed)

`values.yaml` is plain YAML with top-level keys, so a one-line sed does the job:

```bash
tools/set-config.sh --yaml helm/keycloak/values.yaml logLevel debug      # sed 's|^logLevel:.*|logLevel: debug|'
helm upgrade --install keycloak helm/keycloak -n identity \
  -f helm/keycloak/values.yaml -f helm/keycloak/values-generated.yaml
```

For nested keys use `--set` (Helm's own override): `helm upgrade ... --set image.tag=26.3.1 --reuse-values`.
More sed examples in [doc 10](10-changing-settings.md).

## The realm file, section by section

Open `helm/keycloak/realms/grocery-realm.json` next to this text.

* **`roles.realm`** — `shopper`, `cashier`, `manager`, plus Keycloak's built-ins. `default-roles-grocery` is a
  *composite* role every new user gets; we added `shopper` to it, so an LDAP person with no group still gets a shopper badge.
* **`groups`** — `shoppers`→shopper, `cashiers`→cashier, `managers`→manager **and** cashier (a manager can work the register).
* **`users`** — the three local demo people with `groups: ["/shoppers"]` etc. and a password.
* **`clients`** — three doors:
  * `grocery-java-app` and `grocery-python-app`: *confidential* (they have a secret) and use the browser login flow
    (`standardFlowEnabled`). `redirectUris` say where Keycloak may send people back. `pkce.code.challenge.method: S256`
    forces PKCE. `post.logout.redirect.uris: "+"` allows logout to return to the app.
  * `grocery-test-client`: *public* (no secret), `directAccessGrantsEnabled: true` — lets the Go/curl inspectors trade a
    username+password for a token in one call (the *password grant*). Handy for tests, **not** for real apps.
* **`protocolMappers` named `roles`** on each client — copies the user's realm roles into the claim `roles` of the ID
  token, access token and userinfo. Both apps read exactly that claim.

## Pros and cons of the choices here

| Option | We chose | Alternative |
|--------|----------|-------------|
| Import realm from JSON | reproducible, reviewable in git | click in the admin console (fast, but not repeatable) |
| Roles in a custom `roles` claim | simple, identical in both apps | Keycloak's default `realm_access.roles` (nested; needs more parsing) |
| Confidential clients + PKCE | strongest browser login | public clients (no secret) — fine for pure JavaScript apps |
| One replica, `KC_CACHE=local` | simplest | multiple replicas need the `ispn` cache and DNS discovery |
| Bootstrap admin from a Secret | quick | in production create a personal admin and delete the bootstrap one |

## Useful kcadm commands

`tools/kcadm.sh` runs Keycloak's admin CLI inside the pod and logs in for you:

```bash
tools/kcadm.sh get users -r grocery --fields username,email,federationLink
tools/kcadm.sh get clients -r grocery --fields clientId,redirectUris
tools/kcadm.sh get roles -r grocery --fields name
tools/kcadm.sh get groups -r grocery
tools/kcadm.sh create users -r grocery -s username=pat.new -s enabled=true
tools/kcadm.sh set-password -r grocery --username pat.new --new-password 'Secret123!'
tools/kcadm.sh add-roles -r grocery --uusername pat.new --rolename cashier
```
