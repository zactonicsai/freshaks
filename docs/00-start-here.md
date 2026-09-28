# 00 · Start here — the big picture

> **Who is this for?** Anyone curious. If you can follow a recipe, you can follow this.
> Every hard word is explained the first time it appears and again in the [glossary](glossary.md).

## The story in one paragraph

Fresh Mart is a grocery store with two shops that share one **front office**. When you walk in, the front office
checks who you are and hands you a **badge**. Your badge says your name and your **job** (shopper, cashier, manager).
Every **door** in the store looks at your badge: the shelves open for everyone with a badge, the cash register only
for cashiers and managers, the manager's office only for managers. And a **notebook** in the back office records
everything that happens: who came in, who opened which door, who bought what.

That is exactly what this project builds — with computers:

| In the story | In the project | Real name |
|--------------|----------------|-----------|
| The store building with rooms | A Kubernetes cluster on Azure | **AKS** (Azure Kubernetes Service) |
| Rooms where work happens | Nodes (virtual machines) | node pools |
| Workers in the rooms | Pods (running programs) | pods / deployments |
| Hallways that group rooms | Namespaces (`identity`, `data`, `apps`, `testing`) | namespaces |
| The front door and the greeter who points you to the right shop | Ingress (routes `java.…`, `python.…`, `keycloak.…` to the right pod) | ingress-nginx |
| The front office that hands out badges | **Keycloak** | identity provider (IdP) |
| The badge | A token (a signed piece of text) | OIDC ID token / OAuth2 access token |
| Your job written on the badge | A role | realm role |
| A team you belong to (which gives you a job) | A group | group → role mapping |
| The staff phone book the front office also trusts | **OpenLDAP** | LDAP user federation |
| The Java shop (shelves, register, office) | Spring Boot app | `apps/java-grocery-app` |
| The Python deli (menu, kitchen board, notebook) | Flask app | `apps/python-deli-app` |
| The notebook in the back office | **Postgres** database, table `activity_log` | audit log |
| The recipe card for setting up the front office | **Helm chart** (`values.yaml` = ingredients) | `helm/keycloak` |
| Inspectors who test every door | Go program, curl script, Playwright robot | test jobs |

## How a visit works (the 10-second version)

```
   You                      Java store                   Keycloak (front office)
    |  1. open /app/shop.html  |                              |
    |------------------------->|                              |
    |  2. "go get a badge"     |                              |
    |<-------------------------|                              |
    |  3. username + password  ------------------------------>|
    |  4. here is a one-time code, go back to the store  <----|
    |------------------------->|  5. code -> badge (tokens)   |
    |                          |----------------------------->|
    |                          |<-----------------------------|
    |  6. the shelves page     |  (badge says: sam, shopper)  |
    |<-------------------------|                              |
```

The store never sees your password. It only sees the badge, and it trusts the badge because the front office
signed it. [Doc 04](04-how-login-works-oidc.md) walks through this slowly.

## Reading order

1. [01 · Step-by-step setup](01-step-by-step-setup.md) — do this first; it builds everything.
2. [02 · Cluster and nodes](02-cluster-and-nodes.md) — the building and the rooms.
3. [03 · Keycloak, the front office](03-keycloak-the-front-office.md) — the Helm chart and the realm.
4. [04 · How login works (OIDC)](04-how-login-works-oidc.md) — badges, tokens, PKCE.
5. [05 · Roles and permissions (RBAC)](05-roles-and-permissions-rbac.md) — which badge opens which door.
6. [06 · LDAP, the phone book](06-ldap-the-phone-book.md) — users that live somewhere else.
7. [07 · The Java store](07-java-store-app.md) and [08 · The Python deli](08-python-deli-app.md).
8. [09 · Adding a new service](09-adding-a-new-service.md) and [10 · Changing settings](10-changing-settings.md).
9. [11 · Testing with the inspectors](11-testing-the-inspectors.md) and [12 · Troubleshooting](12-troubleshooting.md).
10. Tutorials: [add a "stocker" role](tutorials/tutorial-add-a-stocker-role.md), [add an LDAP user](tutorials/tutorial-add-an-ldap-user.md).

## Why these choices? (pros and cons, honestly)

| Choice | Why | Downside |
|--------|-----|----------|
| Keycloak instead of Azure Entra ID | free, open source, runs anywhere, shows the OIDC machinery | you run and update it yourself |
| Plain shell scripts instead of Terraform/Bicep | you can read every command; great for learning | no "state" file: scripts check what exists instead |
| nip.io host names (`java.20.1.2.3.nip.io`) | no domain to buy; works instantly | ugly; for real life use your own DNS name |
| `http` by default, `ENABLE_TLS=true` optional | fewer moving parts on day one | never run `http` in production |
| One Postgres for Keycloak and the apps | simple, cheap | in production give Keycloak its own database |
| Images built with `az acr build` | no Docker on your laptop | needs internet + an Azure registry |
| Java **and** Python apps | proves OIDC/RBAC is language-independent | two code bases to read |
