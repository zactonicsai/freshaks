"""Inspectors for the Python deli: every door, every badge."""
from conftest import login_as


def test_menu_is_public(client):
    r = client.get("/")
    assert r.status_code == 200
    assert b"deli menu" in r.data
    assert client.get("/api/public/menu").status_code == 200
    assert client.get("/healthz").json == {"status": "ok"}


def test_anonymous_is_sent_to_login(client):
    r = client.get("/order")
    assert r.status_code == 302 and "/login" in r.headers["Location"]
    r = client.get("/api/me")
    assert r.status_code == 401 and r.json["status"] == 401


def test_shopper_can_order_but_not_see_kitchen(client):
    login_as(client, "sam.shopper", ["shopper"])
    assert client.get("/order").status_code == 200
    r = client.post("/order", data={"item": "Veggie wrap", "notes": "extra sauce"}, follow_redirects=True)
    assert r.status_code == 200 and b"Ticket #1" in r.data
    r = client.get("/tickets")
    assert r.status_code == 403 and b"different badge" in r.data
    assert client.get("/admin").status_code == 403
    me = client.get("/api/me").json
    assert me["username"] == "sam.shopper" and me["roles"] == ["shopper"] and me["service"] == "python-deli"


def test_cashier_sees_kitchen_but_not_notebook(client):
    login_as(client, "casey.cashier", ["cashier"])
    assert client.get("/tickets").status_code == 200
    assert client.get("/admin").status_code == 403


def test_manager_opens_every_door(client):
    login_as(client, "morgan.manager", ["manager", "cashier"])
    assert client.get("/tickets").status_code == 200
    assert client.get("/admin").status_code == 200
    assert client.get("/api/activity").status_code == 200


def test_bearer_token_api(client, bearer):
    # no token at all
    assert client.get("/api/tickets").status_code == 401
    # a shopper token can create but not list
    r = client.post("/api/tickets", json={"item": "Chicken soup"}, headers=bearer("sam.shopper", ["shopper"]))
    assert r.status_code == 201 and r.json["status"] == "WAITING" and r.json["customer"] == "sam.shopper"
    assert client.get("/api/tickets", headers=bearer("sam.shopper", ["shopper"])).status_code == 403
    # a cashier token lists and finishes
    r = client.get("/api/tickets", headers=bearer("casey.cashier", ["cashier"]))
    assert r.status_code == 200 and len(r.json) == 1
    r = client.post("/api/tickets/1/done", headers=bearer("casey.cashier", ["cashier"]))
    assert r.status_code == 200 and r.json["status"] == "DONE" and r.json["done_by"] == "casey.cashier"
    assert client.post("/api/tickets/999/done", headers=bearer("casey.cashier", ["cashier"])).status_code == 404
    # a bad token is rejected
    assert client.get("/api/me", headers={"Authorization": "Bearer garbage"}).status_code == 401


def test_unknown_menu_item_is_rejected(client, bearer):
    r = client.post("/api/tickets", json={"item": "Lobster"}, headers=bearer("sam.shopper", ["shopper"]))
    assert r.status_code == 400


def test_everything_is_written_to_the_notebook(client, bearer):
    client.get("/")                                   # anonymous page view
    login_as(client, "sam.shopper", ["shopper"])
    client.post("/api/tickets", json={"item": "Fruit cup"}, headers=bearer("sam.shopper", ["shopper"]))
    login_as(client, "morgan.manager", ["manager"])
    rows = client.get("/api/activity").json
    actions = [(r["service"], r["actor"], r["action"], r["path"]) for r in rows]
    assert ("python-deli", "anonymous", "PAGE_VIEW", "/") in actions
    assert ("python-deli", "sam.shopper", "API_CALL", "/api/tickets") in actions
    assert any(a[2] == "TICKET_CREATED" and a[1] == "sam.shopper" for a in actions)
    assert all("occurred_at" in r and r["status"] is None or isinstance(r["status"], int) for r in rows)


def test_roles_claim_as_string_is_understood(client, bearer, monkeypatch):
    import auth

    monkeypatch.setattr(auth, "verify_bearer", lambda t: {"preferred_username": "riley.ldap", "roles": "manager cashier"})
    me = client.get("/api/me", headers={"Authorization": "Bearer x"}).json
    assert me["roles"] == ["cashier", "manager"]
