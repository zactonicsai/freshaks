# Fresh Mart Python Deli (Flask)

The second shop that trusts the same front office (Keycloak). Written in Python to show
that OIDC + roles work the same way in any language.

| Page / API                              | Who                 |
|-----------------------------------------|---------------------|
| `/`, `/api/public/menu`                 | everyone            |
| `/order`, `/me`, `/api/me`, `POST /api/tickets`, `/api/tickets/mine` | any logged-in person |
| `/tickets`, `GET /api/tickets`, `POST /api/tickets/<id>/done` | cashier, manager |
| `/admin`, `/api/activity`               | manager             |

Run locally with sqlite (no Postgres): `pip install -r requirements-dev.txt && python app.py`
Tests: `pytest`  (they use sqlite and a fake login, no Keycloak needed)
