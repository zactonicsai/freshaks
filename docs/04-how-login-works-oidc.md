# 04 · How login works (OIDC and OAuth 2.0, slowly)

## Background: why not just a password box in each app?

If every shop kept its own list of passwords, you would need a password per shop, each shop could leak it, and no
shop would know your job at the other shop. The fix that the whole internet agreed on:

* **OAuth 2.0** — a way for an app to get a *key* (access token) that opens some doors, without ever seeing your password.
* **OpenID Connect (OIDC)** — OAuth 2.0 plus a standard way to say *who you are* (the ID token) and to discover the
  front office's addresses automatically.

## The badge, up close: what is a token?

A token is a **JWT** (JSON Web Token): three parts separated by dots — `header.payload.signature`.
The payload is plain JSON, base64-encoded (anyone can read it — it is *not* secret, it is *signed*):

```json
{
  "iss": "http://keycloak.20.1.2.3.nip.io/realms/grocery",   ← who issued it (the front office)
  "sub": "3f0c…",                                              ← a permanent id for the person
  "preferred_username": "casey.cashier",
  "name": "Casey Cashier",
  "email": "casey.cashier@freshmart.local",
  "roles": ["cashier", "default-roles-grocery", "offline_access", "uma_authorization"],
  "aud": "account", "azp": "grocery-java-app",                 ← which door it was issued for
  "exp": 1790000300, "iat": 1790000000                         ← valid for 5 minutes (accessTokenLifespan)
}
```

The **signature** is made with Keycloak's private key. Anyone can fetch the matching *public* key from
`…/realms/grocery/protocol/openid-connect/certs` and verify the badge was not forged or edited. That is why the
store trusts the badge without calling the front office each time.

Two kinds of badge appear in this project:

| Token | Who reads it | Where it lives |
|-------|--------------|----------------|
| **ID token** | the app, to learn who logged in | Java: the HTTP session; Python: the Flask session cookie |
| **Access token** | APIs, sent as `Authorization: Bearer …` | the Go/curl inspectors hold it in memory |

## Flow 1 — browser login (Authorization Code + PKCE)

This is what happens when you click **Log in** in the Java store. Follow the numbers in the server log if you like.

```
Browser                       Java store                         Keycloak
  |-- GET /app/shop.html -------->|                                  |
  |<-- 302 to /oauth2/authorization/keycloak                          |
  |-- GET /oauth2/authorization/keycloak                              |
  |<-- 302 to keycloak/…/auth?client_id=grocery-java-app&redirect_uri=…/login/oauth2/code/keycloak
  |                              |    &state=abc&code_challenge=XYZ  (1)
  |-- GET …/auth?… -----------------------------------------------------→|
  |<-- login page ----------------------------------------------------- |
  |-- POST username+password -------------------------------------------→|  (2)
  |<-- 302 to …/login/oauth2/code/keycloak?code=ONE-TIME&state=abc ---- |  (3)
  |-- GET /login/oauth2/code/keycloak?code=… ->|                        |
  |                              |-- POST /token  code + client_secret + code_verifier -→|  (4)
  |                              |<-- {id_token, access_token, refresh_token} ---------- |
  |                              |-- GET /userinfo (Bearer access_token) ----------------→|  (5)
  |<-- 302 /app/shop.html + session cookie                              |
```

1. The store sends the browser to Keycloak with a random `state` (anti-forgery) and a **PKCE** `code_challenge`
   (a hash of a secret the store just invented).
2. Keycloak shows *its* login page. The store never sees the password.
3. Keycloak sends the browser back with a **one-time code**.
4. The store trades the code for tokens in a server-to-server call, proving it is the real store with its
   `client_secret` **and** the PKCE `code_verifier` (the secret behind the hash). A thief who steals the code cannot
   use it.
5. The store may also ask `/userinfo` for extra claims. It then stores "this session belongs to casey, roles […]".

Where it is configured: Java → `application.yml` (`spring.security.oauth2.client.*`) and `SecurityConfig.java`;
Python → `auth.py` (`oauth.register(...)`, `/login`, `/auth/callback`).

**Discovery** makes this painless: both apps only know the *issuer* URL
`http://keycloak.<domain>/realms/grocery`. They fetch `<issuer>/.well-known/openid-configuration` and learn every other
address (auth, token, userinfo, certs, logout) from it.

## Flow 2 — API call with a Bearer token

Programs (and our inspectors) have no browser. They get a token some other way and put it in a header:

```bash
TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/grocery/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=grocery-test-client -d username=casey.cashier -d password=password123 \
  | jq -r .access_token)

curl -H "Authorization: Bearer $TOKEN" "$JAVA_URL/api/orders"      # 200 for a cashier
curl -H "Authorization: Bearer $TOKEN" "$JAVA_URL/api/reports/sales"  # 403 — wrong badge
curl "$JAVA_URL/api/orders"                                        # 401 — no badge at all
```

The app checks the signature with Keycloak's public keys (cached), checks `exp` and `iss`, reads `roles`, done.
Java: `oauth2ResourceServer` in `SecurityConfig.java`. Python: `verify_bearer()` in `auth.py` (PyJWT + JWKS).

The *password grant* used above is deliberately old-school and is only enabled on the public `grocery-test-client`.
Real machine-to-machine callers should use the **client credentials** grant (a service account) instead.

## 401 vs 403 — two different "no"

| Status | Meaning | Store analogy |
|--------|---------|---------------|
| **401 Unauthorized** | we don't know who you are | "please go get a badge first" |
| **403 Forbidden** | we know you, and the answer is no | "your badge does not open this door" |

Browsers get redirects (to Keycloak for 401, to the *forbidden* page for 403); API callers get JSON with the same numbers.

## Logout

Logging out of the store's session is not enough — the front office would silently log you back in. Both apps use
**RP-initiated logout**: they redirect the browser to Keycloak's `…/protocol/openid-connect/logout` with
`id_token_hint` and `post_logout_redirect_uri`, Keycloak ends its own session and sends you back to the front page.

## Best practices you can see in the code

* HTTPS in production (`ENABLE_TLS=true`) — tokens travel in headers and cookies.
* Short access tokens (5 min) and refresh handled by the library, never by hand.
* PKCE on every browser login; `state` checked by the library.
* The apps validate `iss` and the signature and **never** decode tokens without verifying.
* Sessions are `HttpOnly`; CSRF tokens on state-changing browser calls (Java: `X-XSRF-TOKEN` header).

## Common alternatives (and why we did not use them here)

* **Implicit flow** — tokens in the URL bar; deprecated, do not use.
* **Keycloak adapters / gateways** (e.g. oauth2-proxy in front of every app) — great in production, but they hide the
  flow we want to learn.
* **Session sharing between apps** — no; each app keeps its own session and both trust the same issuer. That *is* SSO.
