# Keycloak Helm chart (Fresh Mart front office)

A deliberately small chart: one Deployment, one Service, one Ingress, one Secret,
and a ConfigMap built from every `realms/*.json` file.

| Where | What |
|---|---|
| `values.yaml` | defaults (the ingredient list) |
| `values-generated.yaml` | written by `scripts/05-install-keycloak.sh` from your config; edit + re-run to change |
| `realms/grocery-realm.json` | users, roles, groups, clients — with `__PLACEHOLDERS__` filled from `realm.*` values |
| `templates/` | the recipe steps |

Install/upgrade by hand:

```bash
helm upgrade --install keycloak ./helm/keycloak -n identity -f helm/keycloak/values-generated.yaml
```

Realm JSON is imported only when the realm does not exist yet. After editing it, run
`tools/reimport-realm.sh` (partial import with OVERWRITE) instead of reinstalling.
