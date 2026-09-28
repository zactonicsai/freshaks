"""
The front-office desk of the Python deli: logging in through Keycloak (OIDC) and
checking badges (roles).

Two ways to prove who you are:
  1. Browser: /login sends you to Keycloak, /auth/callback brings you back with an ID token.
     We keep username + roles in the Flask session cookie.
  2. API client: send "Authorization: Bearer <access token>". We check the token's
     signature against Keycloak's public keys (JWKS) — no session needed.
"""
from functools import wraps

import jwt
from authlib.integrations.flask_client import OAuth
from flask import Blueprint, current_app, jsonify, redirect, render_template, request, session, url_for

oauth = OAuth()
bp = Blueprint("auth", __name__)

_jwks_clients = {}


def init_oauth(app):
    """Register Keycloak as the OpenID Connect provider. The discovery document tells Authlib all URLs."""
    oauth.init_app(app)
    oauth.register(
        name="keycloak",
        client_id=app.config["OIDC_CLIENT_ID"],
        client_secret=app.config["OIDC_CLIENT_SECRET"],
        server_metadata_url=app.config["OIDC_ISSUER"].rstrip("/") + "/.well-known/openid-configuration",
        client_kwargs={"scope": "openid profile email", "code_challenge_method": "S256"},
    )


# ---- browser login -------------------------------------------------------------
@bp.route("/login")
def login():
    session["next"] = request.args.get("next") or url_for("main.index")
    redirect_uri = current_app.config["PUBLIC_URL"].rstrip("/") + url_for("auth.callback")
    return oauth.keycloak.authorize_redirect(redirect_uri)


@bp.route("/auth/callback")
def callback():
    token = oauth.keycloak.authorize_access_token()  # exchanges the code, verifies the ID token
    claims = token.get("userinfo") or {}
    session["user"] = {
        "username": claims.get("preferred_username") or claims.get("sub"),
        "name": claims.get("name", ""),
        "email": claims.get("email", ""),
        "roles": _roles_from(claims),
        "id_token": token.get("id_token"),
    }
    from db import log_activity  # local import avoids a circular import

    log_activity(session["user"]["username"], "LOGIN", details="roles=%s via=keycloak" % session["user"]["roles"])
    return redirect(session.pop("next", None) or url_for("main.index"))


@bp.route("/logout")
def logout():
    user = session.pop("user", None)
    session.clear()
    if not user:
        return redirect(url_for("main.index"))
    from db import log_activity

    log_activity(user["username"], "LOGOUT")
    # RP-initiated logout: tell Keycloak too, then come back to the deli's front page
    end_session = current_app.config["OIDC_ISSUER"].rstrip("/") + "/protocol/openid-connect/logout"
    back = current_app.config["PUBLIC_URL"].rstrip("/") + "/"
    url = "%s?post_logout_redirect_uri=%s&client_id=%s" % (end_session, back, current_app.config["OIDC_CLIENT_ID"])
    if user.get("id_token"):
        url += "&id_token_hint=" + user["id_token"]
    return redirect(url)


# ---- who is asking? -------------------------------------------------------------
def _roles_from(claims):
    roles = claims.get(current_app.config.get("ROLES_CLAIM", "roles")) or []
    if isinstance(roles, str):
        roles = [r for r in roles.replace(",", " ").split() if r]
    return sorted(set(str(r) for r in roles))


def _jwks_client():
    issuer = current_app.config["OIDC_ISSUER"].rstrip("/")
    if issuer not in _jwks_clients:
        _jwks_clients[issuer] = jwt.PyJWKClient(issuer + "/protocol/openid-connect/certs", cache_keys=True)
    return _jwks_clients[issuer]


def verify_bearer(token):
    """Check a Keycloak access token: signature, expiry and issuer. Returns the claims or None."""
    try:
        signing_key = _jwks_client().get_signing_key_from_jwt(token)
        return jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            issuer=current_app.config["OIDC_ISSUER"].rstrip("/"),
            options={"verify_aud": False},   # Keycloak puts "account" in aud by default
            leeway=30,
        )
    except Exception as exc:
        current_app.logger.info("bearer token rejected: %s", exc)
        return None


def get_identity():
    """The current person: from a Bearer token first, otherwise from the session cookie."""
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        claims = verify_bearer(header[len("Bearer "):].strip())
        if not claims:
            return None
        return {
            "username": claims.get("preferred_username") or claims.get("sub"),
            "name": claims.get("name", ""),
            "email": claims.get("email", ""),
            "roles": _roles_from(claims),
            "token_type": "bearer",
        }
    user = session.get("user")
    if user:
        ident = dict(user)
        ident.pop("id_token", None)
        ident["token_type"] = "session"
        return ident
    return None


def _deny(status, ident=None):
    """API callers get JSON; browsers get a redirect (401) or the friendly page (403)."""
    wants_json = request.path.startswith("/api/") or request.headers.get("Authorization", "").startswith("Bearer ")
    if wants_json:
        msg = "Please log in (send a Bearer token)" if status == 401 else "Your badge does not open this door"
        return jsonify({"status": status, "message": msg}), status
    if status == 401:
        return redirect(url_for("auth.login", next=request.path))
    return render_template("forbidden.html", user=ident), 403


def login_required(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        ident = get_identity()
        if not ident:
            return _deny(401)
        request.identity = ident
        return view(*args, **kwargs)

    return wrapper


def roles_required(*allowed):
    """@roles_required("cashier", "manager") — any ONE of the listed badges opens the door."""

    def decorator(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            ident = get_identity()
            if not ident:
                return _deny(401)
            if not set(ident["roles"]) & set(allowed):
                return _deny(403, ident)
            request.identity = ident
            return view(*args, **kwargs)

        return wrapper

    return decorator


def current_user():
    """For templates: the session user (or None). Bearer callers never render templates."""
    ident = get_identity()
    return ident


def has_role(ident, *names):
    return bool(ident) and bool(set(ident.get("roles", [])) & set(names))
