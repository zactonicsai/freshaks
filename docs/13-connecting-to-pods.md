# 13 · Connecting to the pods from your desktop (shell + port-forward)

Two small tools turn "it runs somewhere in Azure" into "it is right here on my machine".

## `tools/shell.sh` — step inside a pod

```bash
tools/shell.sh                        # list targets and the pod each one resolves to
tools/shell.sh keycloak               # a bash prompt inside Keycloak (type exit to leave)
tools/shell.sh postgres psql          # psql, already logged in as postgres
tools/shell.sh postgres psql -d grocery -c "select actor, action, path from activity_log order by id desc limit 10"
tools/shell.sh postgres grocery       # psql as the apps' own user (what the store sees)
tools/shell.sh openldap ldapsearch    # the whole phone book
tools/shell.sh openldap ldapsearch '(uid=jordan*)' uid mail
tools/shell.sh keycloak kcadm get clients -r grocery --fields clientId
tools/shell.sh java -- ls /app        # any command after the target
tools/shell.sh -c nginx ingress       # choose the container in a multi-container pod
tools/shell.sh apps/java-store-7d9f…  # or NAMESPACE/POD for anything else
```

The shortcuts `psql`, `grocery`, `ldapsearch` and `kcadm` fill in the passwords from `scripts/00-config.sh`, so you never
paste them. `kubectl exec` is all that happens underneath — nothing is exposed outside the cluster.

## `tools/forward.sh` — bring the ports to your desktop

```bash
tools/forward.sh                      # everything in the table below, Ctrl-C stops all
tools/forward.sh keycloak postgres    # only some
tools/forward.sh --lan                # other machines on your local network may connect too
tools/forward.sh --extra data/svc/postgres:15432:5432    # any NAMESPACE/svc|pod/NAME:LOCAL:REMOTE
KEYCLOAK_PORT=18080 tools/forward.sh keycloak            # change a local port
```

| target | local | what you can open |
|--------|-------|-------------------|
| `keycloak` | 8180 | `http://localhost:8180/admin/` — the admin console without going through the ingress |
| `keycloak-mgmt` | 9000 | `http://localhost:9000/health`, `/metrics` |
| `postgres` | 5432 | psql, DBeaver, pgAdmin, IntelliJ: host `localhost`, user `postgres`, db `grocery` or `keycloak` |
| `openldap` | 3389 | Apache Directory Studio / ldapsearch: `ldap://localhost:3389`, bind `cn=admin,dc=freshmart,dc=local` |
| `java` | 8080 | `http://localhost:8080` — login works (the realm allows `http://localhost:8080/*`) |
| `python` | 5000 | `http://localhost:5000` — login works; after Keycloak you land on the public URL |

The tool prints ready-to-paste connection commands, keeps every forward alive (it reconnects when a pod restarts),
and writes each forward's log to `/tmp/forward-<name>.log`.

**How it works.** `kubectl port-forward` opens a tunnel from a port on your machine, through the Kubernetes API
(encrypted, using your `az aks get-credentials` login), to a Service inside the cluster. Nothing is opened on the
cluster side — the pods stay private. That is why it is the safe way to poke at Postgres or LDAP: no public
endpoint, no firewall rule.

**`--lan` and safety.** With `--lan` the tunnel listens on `0.0.0.0`, so a colleague's laptop (or your phone) on the
same Wi-Fi can use `http://<your-ip>:8180`. Everything behind it uses the demo passwords, so stop the tool when you
are done. Never use `--lan` on a network you do not trust.

## Which one when?

| I want to… | Use |
|-----------|-----|
| run one SQL / LDAP / kcadm command | `tools/shell.sh <target> <shortcut>` |
| use a GUI (DBeaver, Directory Studio, browser dev tools) | `tools/forward.sh` |
| debug a crashing container | `tools/shell.sh <target>` then look around, or `kubectl -n <ns> logs` |
| reach Keycloak without the ingress (e.g. ingress broken) | `tools/forward.sh keycloak` |
