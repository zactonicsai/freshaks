# Tutorial · Add a "stocker" role (a new badge and a new door)

**Goal:** Fresh Mart hires stockers. A stocker may **change the stock count** of a product but may not change
prices, see reports or work the register. We will add the role to Keycloak, give it to a user, open exactly one new
door in the Java store, and teach the inspectors to check it. About 30 minutes.

## What you will touch

| Layer | Change |
|-------|--------|
| Keycloak | role `stocker`, group `stockers`, put `sam.shopper` in it |
| Realm file | same, so a fresh install has it |
| Java store | one new API endpoint `PATCH /api/products/{id}/stock` for stocker **or** manager |
| Pages | a "stock +" button on the shop page, visible to stockers |
| Inspectors | new checks: stocker can, cashier cannot |

## Step 1 — the badge (2 min)

```bash
tools/add-role.sh stocker "Fills the shelves"
```

This runs `kcadm create roles` and `kcadm create groups`, maps the role to the group, and adds both to
`helm/keycloak/realms/grocery-realm.json`. Check:

```bash
tools/kcadm.sh get roles -r grocery --fields name
tools/kcadm.sh get groups -r grocery --fields name,realmRoles
```

## Step 2 — give Sam the badge (1 min)

```bash
SAM=$(tools/kcadm.sh get users -r grocery -q username=sam.shopper | jq -r '.[0].id')
STOCKERS=$(tools/kcadm.sh get groups -r grocery -q search=stockers | jq -r '.[0].id')
tools/kcadm.sh update "users/$SAM/groups/$STOCKERS" -r grocery -n     # -n = no body: "join this group"
tools/kcadm.sh get "users/$SAM/groups" -r grocery --fields name
```

Also edit the realm file so it stays true after a re-install: find `"username": "sam.shopper"` and change
`"groups": ["/shoppers"]` to `"groups": ["/shoppers", "/stockers"]`.

Log out and log in again as Sam (badges are read at login): `/app/me.html` now shows **stocker**.

## Step 3 — the new door in Java (10 min)

In `apps/java-grocery-app/src/main/java/com/freshmart/store/product/ProductController.java` add:

```java
@PatchMapping("/{id}/stock")
@PreAuthorize("hasAnyRole('stocker', 'manager')")
public Product restock(@PathVariable("id") Long id, @RequestBody Map<String, Integer> body, Authentication auth) {
    Product p = one(id);
    Integer delta = body.get("delta");
    if (delta == null) {
        throw new IllegalArgumentException("Send {\"delta\": 10}");
    }
    if (p.getStock() + delta < 0) {
        throw new IllegalArgumentException("Stock cannot go below zero");
    }
    p.setStock(p.getStock() + delta);
    Product saved = products.save(p);
    activity.log(CurrentUser.username(auth), "STOCK_CHANGED", "product=" + saved.getName() + " delta=" + delta
            + " stock=" + saved.getStock());
    return saved;
}
```

(Imports: `org.springframework.web.bind.annotation.PatchMapping`, `java.util.Map`.)

That is the whole security change. `@PreAuthorize` is the door rule; the log line is the notebook entry.
Optional page change in `static/app/shop.html`: after the `Add` button, show a `+10` button when
`window.FM_ME.roles` contains `stocker`, calling `FM.api('/api/products/' + id + '/stock', {method:'PATCH', body:{delta:10}})`.

## Step 4 — teach the inspectors (5 min)

`tests/go-client/main.go`, inside `Checklist()`:

```go
{"java: stocker can restock", "sam.shopper", "PATCH", j + "/api/products/1/stock", `{"delta":5}`, 200},
{"java: cashier cannot restock", "casey.cashier", "PATCH", j + "/api/products/1/stock", `{"delta":5}`, 403},
```

`tests/curl-client/run-tests.sh`:

```sh
check "stocker can restock"     sam.shopper   PATCH "$JAVA_URL/api/products/1/stock" 200 '{"delta":5}'
check "cashier cannot restock"  casey.cashier PATCH "$JAVA_URL/api/products/1/stock" 403 '{"delta":5}'
```

(`main_test.go` has a fake world; add a `/api/products/1/stock` handler there too so `go test` keeps passing.)

## Step 5 — rebuild, redeploy, test (8 min)

```bash
tools/set-config.sh IMAGE_TAG v2
scripts/07-build-images.sh java && scripts/07-build-images.sh go
scripts/08-deploy-apps.sh
scripts/09-run-tests.sh
```

Then open the office as `morgan.manager`: the notebook shows `STOCK_CHANGED` lines by `sam.shopper`.

## What you learned

* A role is just a word on the badge; Keycloak puts it there because a group carries it.
* Apps decide doors with one line next to the code (`@PreAuthorize`, `@roles_required`).
* Every new door gets two tests: someone who **can** and someone who **cannot**.
* The Python deli needed no change — roles it does not know about are simply ignored.
