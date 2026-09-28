# Fresh Mart Java Store (Spring Boot)

The "store front" of the demo. People log in through Keycloak, see products, place
orders, and depending on their badge (role) can open the Cash Register or the Manager's Office.

| Page / API                     | Who can use it              |
|--------------------------------|-----------------------------|
| `/`, `/api/public/*`           | everyone (no login)         |
| `/app/shop.html`, `/api/products` (GET), `/api/orders` (POST), `/api/orders/mine` | any logged-in person |
| `/app/register.html`, `/api/orders` (GET), `/api/orders/{id}/pay` | cashier, manager |
| `/app/office.html`, `/api/reports/sales`, `/api/activity`, `/api/products` (POST/PUT/DELETE) | manager |

Every request to `/api/**` and `/app/**` plus every login is written to the `activity_log` table.

Run locally (needs Postgres + Keycloak):

```bash
export OIDC_ISSUER=http://localhost:8180/realms/grocery OIDC_CLIENT_SECRET=...
export DB_URL=jdbc:postgresql://localhost:5432/grocery DB_USER=grocery DB_PASSWORD=...
mvn spring-boot:run
```

See `docs/07-java-store-app.md` for the friendly explanation.
