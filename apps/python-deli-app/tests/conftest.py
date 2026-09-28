import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import create_app  # noqa: E402


@pytest.fixture()
def app(tmp_path):
    app = create_app({
        "TESTING": True,
        "DATABASE_URL": "sqlite:///" + str(tmp_path / "test.db"),
        "SECRET_KEY": "test",
        "PUBLIC_URL": "http://deli.test",
    })
    return app


@pytest.fixture()
def client(app):
    return app.test_client()


def login_as(client, username, roles):
    """Fake a Keycloak login by writing the session the callback would write."""
    with client.session_transaction() as sess:
        sess["user"] = {"username": username, "name": username.title(), "email": username + "@freshmart.local",
                        "roles": roles, "id_token": "fake"}


@pytest.fixture()
def bearer(monkeypatch):
    """Make 'Authorization: Bearer <username>:<roles>' count as a valid token (no Keycloak in tests)."""
    import auth

    def fake_verify(token):
        if ":" not in token:
            return None
        username, roles = token.split(":", 1)
        return {"preferred_username": username, "roles": [r for r in roles.split(",") if r],
                "name": username, "email": username + "@freshmart.local"}

    monkeypatch.setattr(auth, "verify_bearer", fake_verify)
    return lambda username, roles: {"Authorization": "Bearer %s:%s" % (username, ",".join(roles))}
