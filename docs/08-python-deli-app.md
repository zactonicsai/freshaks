# 08 · The Python deli (Flask)

## Background

The deli exists to prove one thing: **the front office does not care what language a shop is written in.**
Same Keycloak, same realm, same roles, same notebook — a completely different code base. **Flask** is a tiny Python
web framework; **Authlib** handles the OIDC browser flow; **PyJWT** verifies Bearer tokens; **psycopg** talks to Postgres.

## Map of the code (`apps/python-deli-app/`)

| File | What it is |
|------|------------|
| `app.py` | `create_app()`, every page and API route, the `after_request` notebook writer |
| `auth.py` | `/login`, `/auth/callback`, `/logout`, `get_identity()`, `@login_required`, `@roles_required(...)`, `verify_bearer()` |
| `db.py` | tables (`deli_tickets` + the shared `activity_log`), tiny SQL helpers, the menu |
| `templates/*.html` | Jinja pages (base with role-aware nav, index, order, tickets, admin, me, forbidden) |
| `wsgi.py`, `Dockerfile`, `requirements.txt` | how it runs in the container (gunicorn, 2 workers) |
| `tests/` | pytest suite — sqlite + a fake login, no Keycloak needed |

## Login in 20 lines (`auth.py`)

```python
oauth.register(name="keycloak",
    client_id=..., client_secret=...,
    server_metadata_url=issuer + "/.well-known/openid-configuration",     # discovery
    client_kwargs={"scope": "openid profile email", "code_challenge_method": "S256"})  # PKCE

@bp.route("/login")
def login():
    return oauth.keycloak.authorize_redirect(PUBLIC_URL + "/auth/callback")   # step 1: go to the front office

@bp.route("/auth/callback")
def callback():
    token = oauth.keycloak.authorize_access_token()   # step 4: code -> tokens, ID token verified
    claims = token["userinfo"]
    session["user"] = {"username": claims["preferred_username"], "roles": claims["roles"], ...}
```

Bearer tokens (`verify_bearer`) are checked with the realm's public keys: `PyJWKClient(issuer + "/protocol/openid-connect/certs")`,
`jwt.decode(token, key, algorithms=["RS256"], issuer=issuer)`. Audience is not checked because Keycloak puts
`account` there by default; if you add an audience mapper, turn `verify_aud` on — that is the stricter setting.

## Doors (`app.py`)

```python
@main.route("/tickets")
@roles_required("cashier", "manager")
def tickets(): ...

@main.route("/api/tickets", methods=["POST"])
@login_required
def api_create_ticket(): ...
```

`_deny()` in `auth.py` decides how to say no: JSON `{"status": 401|403}` for `/api/*` or Bearer callers, a redirect
to `/login` (401) or the friendly `forbidden.html` (403) for browsers. Same numbers, same meaning as the Java store.

## The notebook

`@app.after_request` writes one line per request (`PAGE_VIEW` or `API_CALL`, actor or `anonymous`, status).
Business events add `LOGIN`, `LOGOUT`, `TICKET_CREATED`, `TICKET_DONE`. Same table, same columns as Java — open
the Java office page and you will see `python-deli` lines mixed in.

`db.py` works with **two databases**: Postgres in the cluster (`DATABASE_URL=postgresql://…`) and **sqlite** for
tests and laptops (`sqlite:///deli.db`). The only differences are `%s` vs `?` placeholders and the id column type.

## Tests (run them now, they need nothing)

```bash
cd apps/python-deli-app
pip install -r requirements-dev.txt
pytest -v
```

`tests/conftest.py` fakes a login by writing the session the callback would write, and patches `verify_bearer` so
`Authorization: Bearer casey.cashier:cashier` counts as a valid token. `tests/test_app.py` then walks every door with
every badge, including the notebook check.

## Run it on your laptop

```bash
export OIDC_ISSUER=http://keycloak.<domain>/realms/grocery OIDC_CLIENT_ID=grocery-python-app OIDC_CLIENT_SECRET=...
export PUBLIC_URL=http://localhost:5000 DATABASE_URL=sqlite:///deli.db
python app.py           # the realm allows http://localhost:5000/* as a redirect URI
```

## Pros and cons vs the Java store

| | Java + Spring Security | Python + Flask + Authlib |
|-|------------------------|--------------------------|
| Security code | mostly configuration | small, explicit decorators |
| Startup | slower, more memory (~600 MB) | fast, ~60 MB |
| Type safety / tooling | strong | lighter |
| Best for | big teams, long-lived services | small services, quick experiments |
