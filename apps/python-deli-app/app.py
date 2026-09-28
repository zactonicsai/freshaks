"""
Fresh Mart Python Deli — a small Flask app that logs people in with Keycloak (OIDC),
opens pages by role (RBAC) and writes every activity into the shared Postgres notebook.

Pages                                   Who
  /                 menu                everyone
  /order            place a deli ticket any logged-in person
  /tickets          the kitchen board   cashier, manager
  /admin            activity notebook   manager
  /me               my badge            any logged-in person
API (Bearer token or session cookie)
  GET  /api/me
  GET  /api/tickets                     cashier, manager
  POST /api/tickets                     any logged-in person
  POST /api/tickets/<id>/done           cashier, manager
"""
import os

from flask import Blueprint, Flask, jsonify, redirect, render_template, request, url_for
from werkzeug.middleware.proxy_fix import ProxyFix

import db
from auth import bp as auth_bp, current_user, get_identity, has_role, init_oauth, login_required, roles_required

main = Blueprint("main", __name__)


def create_app(config=None):
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=os.environ.get("SECRET_KEY", "dev-only-change-me"),
        DATABASE_URL=os.environ.get("DATABASE_URL", "sqlite:///deli.db"),
        OIDC_ISSUER=os.environ.get("OIDC_ISSUER", "http://localhost:8180/realms/grocery"),
        OIDC_CLIENT_ID=os.environ.get("OIDC_CLIENT_ID", "grocery-python-app"),
        OIDC_CLIENT_SECRET=os.environ.get("OIDC_CLIENT_SECRET", "change-me"),
        PUBLIC_URL=os.environ.get("PUBLIC_URL", "http://localhost:5000"),
        PREFERRED_URL_SCHEME=os.environ.get("PREFERRED_URL_SCHEME", "http"),
        SERVICE_NAME=os.environ.get("SERVICE_NAME", "python-deli"),
        ROLES_CLAIM=os.environ.get("ROLES_CLAIM", "roles"),
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SECURE=os.environ.get("PREFERRED_URL_SCHEME", "http") == "https",
    )
    if config:
        app.config.update(config)

    # We sit behind ingress-nginx: trust X-Forwarded-Proto/Host so redirect URLs are right.
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

    init_oauth(app)
    app.register_blueprint(auth_bp)
    app.register_blueprint(main)
    app.teardown_appcontext(db.close_conn)

    with app.app_context():
        db.init_schema()

    @app.context_processor
    def inject_user():
        return {"user": current_user(), "has_role": has_role, "service_name": app.config["SERVICE_NAME"]}

    @app.after_request
    def write_notebook(response):
        """Every page and API call becomes one line in activity_log."""
        path = request.path
        if path in ("/healthz", "/favicon.ico") or path.startswith("/static/") or path.startswith("/api/activity"):
            return response
        ident = getattr(request, "identity", None) or get_identity()
        actor = ident["username"] if ident else "anonymous"
        action = "API_CALL" if path.startswith("/api/") else "PAGE_VIEW"
        details = ("query=" + request.query_string.decode()) if request.query_string else None
        db.log_activity(actor, action, request.method, path, response.status_code, details)
        return response

    return app


# ---- pages ------------------------------------------------------------------------
@main.route("/")
def index():
    return render_template("index.html", menu=db.MENU)


@main.route("/healthz")
def healthz():
    return jsonify({"status": "ok"})


@main.route("/order", methods=["GET", "POST"])
@login_required
def order():
    ident = request.identity
    if request.method == "POST":
        item = request.form.get("item", "").strip()
        notes = request.form.get("notes", "").strip()[:500]
        if item not in [m["item"] for m in db.MENU]:
            return render_template("order.html", menu=db.MENU, error="Please pick something from the menu."), 400
        ticket_id = db.create_ticket(ident["username"], item, notes)
        db.log_activity(ident["username"], "TICKET_CREATED", details="ticket=%s item=%s" % (ticket_id, item))
        return redirect(url_for("main.order", placed=ticket_id))
    mine = [db.to_dict(t) for t in db.list_tickets(ident["username"])]
    return render_template("order.html", menu=db.MENU, tickets=mine, placed=request.args.get("placed"))


@main.route("/tickets")
@roles_required("cashier", "manager")
def tickets():
    rows = [db.to_dict(t) for t in db.list_tickets()]
    return render_template("tickets.html", tickets=rows)


@main.route("/tickets/<int:ticket_id>/done", methods=["POST"])
@roles_required("cashier", "manager")
def ticket_done(ticket_id):
    _finish(ticket_id, request.identity["username"])
    return redirect(url_for("main.tickets"))


@main.route("/admin")
@roles_required("manager")
def admin():
    rows = [db.to_dict(a) for a in db.recent_activity(200)]
    return render_template("admin.html", activity=rows)


@main.route("/me")
@login_required
def me():
    return render_template("me.html", ident=request.identity)


@main.route("/forbidden")
def forbidden():
    return render_template("forbidden.html"), 403


# ---- API ----------------------------------------------------------------------------
@main.route("/api/me")
@login_required
def api_me():
    ident = dict(request.identity)
    ident["service"] = "python-deli"
    return jsonify(ident)


@main.route("/api/tickets", methods=["GET"])
@roles_required("cashier", "manager")
def api_tickets():
    return jsonify([db.to_dict(t) for t in db.list_tickets()])


@main.route("/api/tickets/mine", methods=["GET"])
@login_required
def api_my_tickets():
    return jsonify([db.to_dict(t) for t in db.list_tickets(request.identity["username"])])


@main.route("/api/tickets", methods=["POST"])
@login_required
def api_create_ticket():
    body = request.get_json(silent=True) or {}
    item = str(body.get("item", "")).strip()
    if item not in [m["item"] for m in db.MENU]:
        return jsonify({"status": 400, "message": "Unknown menu item"}), 400
    ident = request.identity
    ticket_id = db.create_ticket(ident["username"], item, str(body.get("notes", ""))[:500])
    db.log_activity(ident["username"], "TICKET_CREATED", details="ticket=%s item=%s" % (ticket_id, item))
    return jsonify(db.to_dict(db.get_ticket(ticket_id))), 201


@main.route("/api/tickets/<int:ticket_id>/done", methods=["POST"])
@roles_required("cashier", "manager")
def api_ticket_done(ticket_id):
    ticket = _finish(ticket_id, request.identity["username"])
    if ticket is None:
        return jsonify({"status": 404, "message": "No ticket %s" % ticket_id}), 404
    return jsonify(db.to_dict(ticket))


@main.route("/api/activity")
@roles_required("manager")
def api_activity():
    return jsonify([db.to_dict(a) for a in db.recent_activity(200)])


@main.route("/api/public/menu")
def api_menu():
    return jsonify(db.MENU)


def _finish(ticket_id, worker):
    ticket = db.get_ticket(ticket_id)
    if ticket is None:
        return None
    if ticket["status"] != "DONE":
        db.mark_done(ticket_id, worker)
        db.log_activity(worker, "TICKET_DONE", details="ticket=%s customer=%s" % (ticket_id, ticket["customer"]))
    return db.get_ticket(ticket_id)


if __name__ == "__main__":  # local run: python app.py
    create_app().run(host="0.0.0.0", port=5000, debug=True)
