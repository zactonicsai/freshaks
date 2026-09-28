# 11 · Testing with the inspectors (Go, curl, Playwright)

## Background: why three inspectors?

A health inspector checks the kitchen, a fire inspector checks the exits, a mystery shopper checks the experience.
Each sees things the others miss:

| Inspector | Speaks | Checks | Strength |
|-----------|--------|--------|----------|
| **Go client** (`tests/go-client`) | HTTP with Bearer tokens | 28 API rules across both apps | fast, strict, one binary; has its own unit tests |
| **curl script** (`tests/curl-client`) | the same, with `curl` + `sed` | 23 API rules | every request is a line you can copy-paste |
| **Playwright** (`tests/playwright`) | a real Chromium browser | 10 scenarios: log in as each person, open doors, place an order | catches broken pages, redirects, cookies, CSRF |

All three run as Kubernetes **Jobs** in namespace `testing`, read the same `test-config` Secret
(`KEYCLOAK_URL`, `KC_REALM`, `TEST_CLIENT_ID`, `JAVA_URL`, `PYTHON_URL`, `DEMO_USER_PASSWORD`) and exit non-zero on
any failure — so `scripts/09-run-tests.sh` can be a CI step.

## Run them

```bash
scripts/09-run-tests.sh              # all three, prints each job's log, PASS/FAIL per inspector
scripts/09-run-tests.sh go           # or: curl | playwright
kubectl -n testing logs job/playwright-tests   # read a log again later
```

The Go image is built by script 07; the curl and Playwright jobs need no image build: their scripts are mounted from
ConfigMaps (`kubectl create configmap --from-file`) into stock images (`curlimages/curl`, `mcr.microsoft.com/playwright`).

## What "the rules" are

Read `Checklist()` in `tests/go-client/main.go` — it *is* the specification:

```go
{"java: shopper cannot open the register", "sam.shopper", "GET", j + "/api/orders", "", 403},
{"java: cashier opens the register",       "casey.cashier", "GET", j + "/api/orders", "", 200},
{"java: LDAP shopper (alex) cannot open the register", "alex.ldap", "GET", j + "/api/orders", "", 403},
{"python: no badge -> 401 on tickets",     "", "GET", p + "/api/tickets", "", 401},
```

Every row: *who*, *which door*, *expected answer*. Both positive (can) and negative (cannot) cases, local and LDAP
users, both apps. When you add a role or a door, add rows here **and** in `run-tests.sh` **and** a scenario in
`rbac.spec.js` — the three lists are deliberately similar.

## Playwright in a nutshell (`rbac.spec.js`)

```js
async function openJava(page, path, username) {
  await page.goto(JAVA + path);                       // the store redirects to Keycloak...
  if (page.url().includes('/realms/')) {              // ...where the robot types the password
    await page.fill('#username', username);
    await page.fill('#password', PASSWORD);
    await page.click('#kc-login');
  }
  await page.waitForURL(url => !url.toString().includes('/realms/'));
}

test('sam.shopper gets a shopper badge and cannot enter the office', async ({ page }) => {
  await openJava(page, '/app/me.html', 'sam.shopper');
  await expect(page.locator('#badge-username')).toHaveText('sam.shopper');
  await page.goto(JAVA + '/app/office.html');
  await expect(page).toHaveURL(/forbidden\.html/);
});
```

Each test gets a **fresh browser context** (no cookies), so "log in as Casey" never leaks into "log in as Sam".
`playwright.config.js` keeps `workers: 1` to be gentle with the demo cluster and saves a screenshot + trace on failure.

Run it from your laptop against the cluster:

```bash
cd tests/playwright && npm install && npx playwright install chromium
source ../../scripts/00-config.sh; source ../../scripts/.generated.env
JAVA_URL=$PROTO://java.$BASE_DOMAIN PYTHON_URL=$PROTO://python.$BASE_DOMAIN npx playwright test --headed
```

## Offline checks (no cluster): `tools/local-check.sh`

| # | Check | Needs |
|---|-------|-------|
| 1 | `bash -n` + shellcheck on every script | shellcheck (optional) |
| 2 | render every k8s template with `envsubst`, parse as YAML, no `${VAR}` left | envsubst, PyYAML |
| 3 | realm + LDAP JSON valid | python3 |
| 4 | Helm chart renders (real `helm`, or the tiny Go renderer in `tools/dev/minihelm.go`) and the realm inside the ConfigMap is valid JSON | helm **or** go + PyYAML |
| 5 | Python deli pytest (sqlite) | `pip install -r apps/python-deli-app/requirements-dev.txt` |
| 6 | Go inspector `go vet` + `go test` (fake Keycloak/apps in the test) | go |
| 7 | Playwright parses the spec (`--list`) | node |
| 8 | Java compiles (`mvn compile`) — or at least parses (`pip install javalang`) | maven or javalang |

This is what CI should run on every pull request; the cluster tests run on merge.

## Pros and cons

| | API tests (Go/curl) | Browser tests (Playwright) |
|-|---------------------|----------------------------|
| Speed | seconds | minutes |
| Flakiness | very low | some (timeouts, animations) |
| What they prove | the rules | the whole experience incl. login page, cookies, JS |
| Password grant needed | yes (test client) | no — real login form |
