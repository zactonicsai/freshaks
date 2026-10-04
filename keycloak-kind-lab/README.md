# Keycloak on kind with Istio + Postgres

Local lab: kind cluster `mycluster`, Postgres (no sidecar), Keycloak with an
Istio sidecar that handles ingress (gateway on localhost:8080) and egress
(REGISTRY_ONLY, Postgres only). All credentials are `admin` / `admin`.

## Requirements
docker (running), kind, kubectl, helm, curl, bash.
On Windows run the scripts from Git Bash or WSL.

## Usage
```bash
chmod +x *.sh

./rebuild.sh                 # create cluster + install everything (+ restore latest backup)
./save-and-destroy.sh        # dump Keycloak DB to backups/, then delete cluster
./rebuild.sh                 # comes back with your realms/users restored
```

### Options
| Command | What it does |
|---|---|
| `./save-and-destroy.sh --save-only` | Backup only, keep the cluster |
| `./save-and-destroy.sh -y` | No confirmation prompt |
| `./rebuild.sh --fresh` | Ignore backups, start clean |
| `./rebuild.sh --restore backups/keycloak-YYYYMMDD-HHMMSS.sql` | Restore a specific dump |
| `./rebuild.sh --force` | Delete an existing cluster first (no backup!) |
| `./rebuild.sh --refresh-charts` | Re-download the Helm charts |

Env vars: `CLUSTER_NAME`, `ISTIO_VERSION`, `KEYCLOAKX_VERSION` (pin chart versions).

## Layout
```
manifests/   kind config, Helm values, Postgres + Istio YAML
charts/      Helm charts, downloaded on first rebuild, then used locally
backups/     pg_dump files (latest.sql + last 10 timestamped)
lib/         shared helpers
```

Open http://localhost:8080/admin after `rebuild.sh` finishes.
