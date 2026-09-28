# 🥬 Fresh Mart — AKS + Keycloak (OIDC) demo store

A complete, runnable example of **one login for many apps** on Azure Kubernetes Service:

* **Keycloak** is the *front office* that hands out badges (tokens) — installed with a small Helm chart
* **OpenLDAP** is the *phone book* some employees are listed in (user federation)
* A **Java (Spring Boot)** grocery store and a **Python (Flask)** deli both trust that front office
* **Roles** (shopper, cashier, manager) decide which *doors* (pages and API calls) open
* **Every activity** (logins, page views, API calls, orders) is written to **Postgres**
* Three **inspectors** check everything: a **Go** client, a **curl** script and a **Playwright** robot browser
* Everything is driven by plain **shell scripts** you can read, and changed with **sed**

The docs are written for beginners (think: a curious 8th grader), with grocery-store and school analogies.
Start at **[docs/00-start-here.md](docs/00-start-here.md)**.

## Quick start (about 30 minutes, ~$0.30/hour while it runs)

```bash
# 0. tools you need once: az, kubectl, helm, jq, envsubst (gettext)  — see docs/01
# 1. edit the settings (passwords, region...) — or use tools/set-config.sh
nano scripts/00-config.sh

# 2. run the numbered scripts in order (each one can be re-run safely)
scripts/01-create-cluster.sh      # resource group + container registry + AKS
scripts/02-setup-nodes.sh         # apps node pool + ingress-nginx (+ cert-manager if ENABLE_TLS=true)
scripts/03-install-postgres.sh    # the notebook
scripts/04-install-openldap.sh    # the phone book (with demo users)
scripts/05-install-keycloak.sh    # the front office (Helm chart, imports the 'grocery' realm)
scripts/06-configure-realm.sh     # connect Keycloak to LDAP, sync users + groups
scripts/07-build-images.sh        # build Java, Python and Go images in the cloud (az acr build)
scripts/08-deploy-apps.sh         # deploy the store and the deli
scripts/09-run-tests.sh           # send in the inspectors
scripts/10-status.sh              # URLs, pods, users
scripts/99-destroy.sh             # delete everything (stops the bill)
```

Before spending money you can run every offline check on your laptop: `tools/local-check.sh`.

## What is where

| Folder | What lives there |
|--------|------------------|
| `scripts/` | `00-config.sh` (the only file you *must* edit) + numbered scripts 01→10 + `99-destroy.sh` |
| `scripts/lib/common.sh` | helpers shared by all scripts (logging, templates, kcadm wrapper) |
| `helm/keycloak/` | the Keycloak Helm chart, `values.yaml`, and `realms/grocery-realm.json` |
| `k8s/` | Kubernetes manifests as `${VAR}` templates: postgres, openldap, apps, tests, `_templates/new-service` |
| `apps/java-grocery-app/` | Spring Boot store: OIDC login, RBAC, REST API, Tailwind pages, activity log |
| `apps/python-deli-app/` | Flask deli: OIDC login, RBAC, JSON API, activity log (+ pytest suite) |
| `tests/go-client/` | Go inspector (Bearer tokens, 28 checks) + its own unit tests |
| `tests/curl-client/` | the same checks with only curl + sed |
| `tests/playwright/` | robot browser: logs in as each person and tries every door |
| `tools/` | `set-config.sh` (sed), `kcadm.sh`, `reimport-realm.sh`, `add-service.sh`, `add-role.sh`, `render-templates.sh`, `local-check.sh` |
| `docs/` | the friendly explanations and tutorials |

## Demo people

| Username | Where they live | Group → roles | Opens |
|----------|-----------------|---------------|-------|
| `sam.shopper` | Keycloak | shoppers → shopper | shop, order |
| `casey.cashier` | Keycloak | cashiers → cashier | + cash register / kitchen board |
| `morgan.manager` | Keycloak | managers → manager + cashier | + manager's office / notebook |
| `alex.ldap` | LDAP | (no group) → shopper (default role) | shop, order |
| `jordan.ldap` | LDAP | cashiers → cashier | + register |
| `riley.ldap` | LDAP | managers → manager + cashier | everything |

All passwords are `DEMO_USER_PASSWORD` from `scripts/00-config.sh` (default `password123`).

## Requirements

Azure CLI 2.60+, kubectl, Helm 3.12+, jq, envsubst (package `gettext`), bash 4+. No Docker needed (images build in ACR).
Optional for offline checks: Python 3.10+, Go 1.22+, Node 18+, shellcheck, Maven.

MIT licensed — copy, break, learn.
# freshaks
