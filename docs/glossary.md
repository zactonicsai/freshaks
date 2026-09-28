# Glossary (store words ↔ computer words)

| Word | Plain meaning | In Fresh Mart |
|------|---------------|---------------|
| **Access token** | a short-lived key for APIs, sent as `Authorization: Bearer …` | what the Go/curl inspectors carry |
| **ACR** | Azure Container Registry — where images are stored | the supply closet |
| **AKS** | Azure Kubernetes Service — a managed cluster | the school building |
| **Audit log** | a record of who did what | table `activity_log` |
| **Authorization code flow** | the browser login dance: redirect → login → one-time code → tokens | doc 04 |
| **Bearer token** | "whoever bears this token may enter" | API calls |
| **cert-manager** | gets TLS certificates automatically | `ENABLE_TLS=true` |
| **Claim** | one field in a token (`preferred_username`, `roles`, `exp`) | what the apps read |
| **Client** (Keycloak) | an app registered with the front office | `grocery-java-app` … |
| **Client secret** | the app's own password to the front office | `JAVA_CLIENT_SECRET` |
| **ConfigMap** | Kubernetes object holding plain files/settings | realm JSON, test scripts |
| **CSRF** | Cross-Site Request Forgery; a token proves the browser meant to send the form | `X-XSRF-TOKEN` |
| **Deployment** | "keep N copies of this pod running" | the apps, Keycloak |
| **Discovery** | `/.well-known/openid-configuration` — the front office's address book | how apps find Keycloak endpoints |
| **envsubst** | replaces `${VARIABLES}` in a text file | how manifests are filled in |
| **Federation** | trusting another user list | OpenLDAP |
| **Group** | a team that carries roles | `cashiers` → `cashier` |
| **Helm / chart / values** | package manager for Kubernetes / a package / its settings | `helm/keycloak` |
| **ID token** | "who is this person" token | browser sessions |
| **Idempotent** | running it twice does the same as once | every script |
| **Ingress** | routes host names to services | ingress-nginx |
| **Issuer (`iss`)** | who signed the token | `http://keycloak.<domain>/realms/grocery` |
| **JWT** | JSON Web Token — signed JSON in three base64 parts | every token here |
| **JWKS** | the issuer's public keys, for verifying signatures | `/protocol/openid-connect/certs` |
| **kcadm** | Keycloak's command-line admin tool | `tools/kcadm.sh` |
| **LDAP** | phone-book protocol | OpenLDAP |
| **Namespace** | a named hallway grouping objects | `identity`, `data`, `apps`, `testing` |
| **nip.io** | free wildcard DNS: `x.1.2.3.4.nip.io` → `1.2.3.4` | our host names |
| **Node / node pool** | a VM / a set of same-size VMs | system + apps pools |
| **OAuth 2.0** | rules for handing out access tokens | |
| **OIDC** | OpenID Connect — OAuth 2.0 + identity | login |
| **PKCE** | "pixie"; a one-time secret that protects the login code | both apps |
| **Pod** | one running program (container) | |
| **Protocol mapper** | copies data onto tokens | the `roles` mapper |
| **RBAC** | access decided by role, not by person | doc 05 |
| **Realm** | one isolated set of users/roles/clients | `grocery` |
| **Refresh token** | gets a new access token without logging in again | handled by libraries |
| **Role** | a job title on the badge | shopper, cashier, manager |
| **RP-initiated logout** | the app asks the front office to end the session too | Log out buttons |
| **Secret** (Kubernetes) | like a ConfigMap, for passwords | `app-db-secret`… |
| **Service** (Kubernetes) | a stable name for a set of pods | `java-store.apps.svc` |
| **StatefulSet** | a deployment with a persistent disk | Postgres |
| **TLS** | https encryption | cert-manager |
| **userinfo** | endpoint returning claims for a valid access token | extra roles source |
