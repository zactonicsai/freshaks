# 05 · Roles and permissions (RBAC)

## Background

**RBAC** = Role-Based Access Control: instead of listing which *people* may open a door, you list which *jobs* may.
Hire a new cashier → put them in the `cashiers` team → every register in every shop opens. Nothing to change in the apps.

Three layers make this work:

```
 Keycloak                      Token                         App
 ─────────                     ─────                         ───
 user ∈ group ─→ group has role ─→ "roles": ["cashier"] ─→ door rule: needs cashier or manager ─→ open / 403
```

## The roles in Fresh Mart

| Role | Java store may… | Python deli may… |
|------|-----------------|------------------|
| *(logged in, any role)* | see shelves, place orders, see own receipts, see own badge | order, see own tickets, own badge |
| `shopper` | same as above (it is the *default* role every user gets) | same |
| `cashier` | + open the register, mark orders paid, list all orders | + kitchen board, mark tickets done |
| `manager` | + office, sales report, add/edit products, read the notebook | + notebook (`/admin`, `/api/activity`) |

`managers` group = `manager` **and** `cashier`, so a manager can cover the register. That is a *composite* through the
group; you could also make `manager` a composite role in Keycloak — both work, groups are easier to see.

## Where the doors are declared

### Java (`SecurityConfig.java`) — URL rules + method rules

```java
.requestMatchers("/", "/index.html", "/css/**", "/js/**", "/api/public/**", "/actuator/health/**").permitAll()
.requestMatchers("/app/office.html").hasRole("manager")
.requestMatchers("/app/register.html").hasAnyRole("cashier", "manager")
.anyRequest().authenticated()
```

and on API methods:

```java
@PreAuthorize("hasAnyRole('cashier', 'manager')")
public List<PurchaseOrder> all() { ... }
```

Spring writes roles as `ROLE_cashier`; `hasRole("cashier")` adds the prefix for you. The `roles` claim becomes those
authorities in two places: `userAuthoritiesMapper()` (browser sessions) and `jwtAuthenticationConverter()` (Bearer).

### Python (`app.py`) — decorators

```python
@main.route("/tickets")
@roles_required("cashier", "manager")     # any ONE of these
def tickets(): ...

@main.route("/order")
@login_required                            # any badge
def order(): ...
```

`roles_required` lives in `auth.py`; it reads roles from the session or from the Bearer token.

### Pages hide what you cannot open — but the server still checks

`nav.js` (Java) and `base.html` (Python) only *show* the Register/Office links to the right roles. That is
politeness, not security: the security is the server rule. Try it — type `/app/office.html` as `sam.shopper`.

## Groups vs roles vs "just give the user the role"

| Method | Pros | Cons |
|--------|------|------|
| Put users in **groups** (what we do) | one place to look; LDAP groups map straight onto them | one more concept |
| Assign **roles directly** to users | quickest for one person | after 50 users nobody knows who has what |
| **Composite roles** (manager includes cashier) | expresses hierarchy | hidden inside role definitions |
| **Client roles** (roles that exist only for one app) | tidy per app | the `roles` mapper must be told to include them |

Best practice: realm roles named after *jobs*, groups named after *teams*, apps check *roles* only.

## Design pattern for new doors

1. Ask "which job may do this?" — never "which person".
2. Prefer *allow-lists*: default is `authenticated`, then open specific doors to specific roles.
3. Keep the door rule next to the code it protects (`@PreAuthorize`, `@roles_required`).
4. Log the decision — both apps write 403s to `activity_log`, so a manager can see who tried which door.
5. Test both sides: the inspectors check that a cashier **can** open the register **and** that a shopper **cannot**.

## Reading a badge yourself

Java: open `/app/me.html` and expand "Raw answer from /api/me". Python: `/me`. From a terminal:

```bash
source scripts/00-config.sh; source scripts/.generated.env
TOKEN=$(curl -s -X POST "$PROTO://keycloak.$BASE_DOMAIN/realms/grocery/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=grocery-test-client -d username=morgan.manager -d "password=$DEMO_USER_PASSWORD" \
  | jq -r .access_token)
echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq .roles   # decode the JWT payload
```
