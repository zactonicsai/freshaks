# 07 · The Java store (Spring Boot)

## Background

**Spring Boot** is the most common way to write web apps in Java. It comes with **Spring Security**, which already
speaks OIDC/OAuth 2.0, so the store needs very little security code of its own — mostly *rules*, not plumbing.

The app is a classic three-layer store:

```
 Browser  ──  static pages (HTML + Tailwind + a little JS)  ──  REST API (/api/…)  ──  JPA  ──  Postgres
             src/main/resources/static/                     controllers/services/repositories
```

## Map of the code (`apps/java-grocery-app/src/main/java/com/freshmart/store/`)

| File | What it is |
|------|------------|
| `GroceryApplication.java` | the `main()` |
| `config/SecurityConfig.java` | **the security guard**: which door needs which badge, OIDC login, Bearer tokens, CSRF, logout |
| `config/WebConfig.java` | plugs the activity logger into every request |
| `activity/ActivityLog*.java`, `ActivityService.java`, `LoginEventListener.java`, `ActivityController.java` | the notebook: entity, repository, writer, "LOGIN" listener, manager's read API |
| `product/Product*.java` | shelves: entity, repository, API (GET for all, POST/PUT/DELETE for managers) |
| `order/PurchaseOrder.java`, `OrderItem.java`, `OrderRequest.java`, `OrderService.java`, `OrderController.java` | receipts: place (any badge), list all / pay (cashier, manager) |
| `report/ReportController.java` | `/api/reports/sales` (manager) |
| `me/MeController.java` | `/api/me` (who am I) and `/api/public/store-info` (no badge) |
| `web/CurrentUser.java` | reads username/roles from either kind of badge |
| `web/ApiExceptionHandler.java` | small JSON errors instead of stack traces |

Resources: `application.yml` (settings), `schema.sql` + `data.sql` (tables + starting stock), `static/` (pages).

## The security guard, line by line

```java
.authorizeHttpRequests(auth -> auth
    .requestMatchers("/", "/index.html", "/css/**", "/js/**", "/api/public/**", "/actuator/health/**").permitAll()
    .requestMatchers("/app/office.html").hasRole("manager")
    .requestMatchers("/app/register.html").hasAnyRole("cashier", "manager")
    .anyRequest().authenticated())
```
Rules are checked top to bottom; the first match wins; the last line is the safe default.

```java
.oauth2Login(login -> login
    .authorizationEndpoint(e -> e.authorizationRequestResolver(authRequestResolver))   // PKCE
    .userInfoEndpoint(u -> u.userAuthoritiesMapper(userAuthoritiesMapper()))           // roles claim -> ROLE_*
    .defaultSuccessUrl("/app/shop.html"))
```
Browser login. The `GrantedAuthoritiesMapper` copies the `roles` claim from the ID token / userinfo into
`ROLE_shopper`, `ROLE_cashier`, … Everything else (redirects, code exchange, state) is Spring.

```java
.oauth2ResourceServer(rs -> rs.jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthenticationConverter())))
```
Bearer tokens for API clients; `JwtGrantedAuthoritiesConverter` reads the same `roles` claim.

```java
.csrf(csrf -> csrf.csrfTokenRepository(CookieCsrfTokenRepository.withHttpOnlyFalse())
                  .csrfTokenRequestHandler(csrfHandler)
                  .ignoringRequestMatchers(bearerRequests))
```
Browser POSTs must echo the `XSRF-TOKEN` cookie in the `X-XSRF-TOKEN` header (`js/app.js` does it). Bearer calls
don't use cookies, so CSRF does not apply to them.

```java
.exceptionHandling(ex -> ex
    .defaultAuthenticationEntryPointFor(new HttpStatusEntryPoint(UNAUTHORIZED), apiRequests)  // 401 as JSON on /api
    .accessDeniedHandler(accessDeniedHandler()))                                              // 403 JSON or forbidden page
```

```java
.logout(l -> l.logoutSuccessHandler(oidcLogoutHandler))   // also logs out of Keycloak
```

Settings come from environment variables (see `k8s/apps/java/deployment.yaml`): `OIDC_ISSUER`, `OIDC_CLIENT_ID`,
`OIDC_CLIENT_SECRET`, `DB_URL`, `DB_USER`, `DB_PASSWORD`. `server.forward-headers-strategy: framework` makes Spring trust
the ingress's `X-Forwarded-*` headers so redirect URLs are right.

## The notebook: logging *everything*

Three writers feed the `activity_log` table (`ActivityService.log(...)`):

1. `ActivityLogInterceptor.afterCompletion` — **every** `/api/**` and `/app/**` request: who, method, path, status.
   Anonymous requests are logged too (actor `anonymous`), and so are 401/403 answers.
2. `LoginEventListener` — Spring's `AuthenticationSuccessEvent` for browser logins → action `LOGIN` with the roles.
3. Business events inside services/controllers — `ORDER_PLACED`, `ORDER_PAID`, `PRODUCT_CREATED/UPDATED/DELETED`.

The writer swallows exceptions on purpose: a full disk must not stop sales. Reading the log (`/api/activity`) is
itself *not* logged, or the office page would fill the notebook by reading it.

| column | example |
|--------|---------|
| occurred_at | 2026-09-28 14:03:11+00 |
| service | java-store |
| actor | casey.cashier |
| action | ORDER_PAID |
| method / path / status | POST / /api/orders/7/pay / 200 |
| details | order=7 customer=sam.shopper total=3.75 |

## The pages (Tailwind CSS via CDN + vanilla JS)

* `index.html` — public; shows `/api/public/store-info` and the "who opens what" table.
* `app/shop.html` — product cards, a basket, **Place order** (`POST /api/orders`), my receipts.
* `app/register.html` — all orders, **Mark paid** (`POST /api/orders/{id}/pay`).
* `app/office.html` — sales report, add product, the notebook with a username filter.
* `app/me.html` — the badge as the app sees it (+ raw `/api/me`).
* `app/forbidden.html` — the friendly 403.
* `js/app.js` — `FM.api()` (adds CSRF header, turns 401 into a login redirect and 403 into the forbidden page).
* `js/nav.js` — draws the top bar from `/api/me`: links appear only for roles that can open them.

Tailwind comes from `cdn.tailwindcss.com` to keep the build trivial. For production you would compile Tailwind
into a small CSS file (no CDN, no runtime JIT).

## Database

`schema.sql` creates `products`, `orders`, `order_items`, `activity_log` with `IF NOT EXISTS`; `data.sql` inserts
ten products with `ON CONFLICT DO NOTHING`. Both run on every start (`spring.sql.init.mode: always`) so a fresh
database and a restart behave the same. Hibernate (`ddl-auto: none`) never guesses at tables.

## Run it on your laptop

```bash
# Postgres + Keycloak reachable from your machine, then:
export OIDC_ISSUER=http://keycloak.<domain>/realms/grocery OIDC_CLIENT_ID=grocery-java-app OIDC_CLIENT_SECRET=...
export DB_URL=jdbc:postgresql://localhost:5432/grocery DB_USER=grocery DB_PASSWORD=...
mvn spring-boot:run          # http://localhost:8080 (the realm allows http://localhost:8080/* as redirect URI)
```

## Ideas to extend

* Add a `stocker` role that may only change `stock` — see the [tutorial](tutorials/tutorial-add-a-stocker-role.md).
* Add `spring-boot-starter-data-rest`? No — explicit controllers keep the doors visible.
* Replace the CDN Tailwind with a build step (`npx tailwindcss`) when you go to production.
