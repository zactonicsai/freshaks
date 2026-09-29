#!/usr/bin/env bash
# =============================================================================
#  tools/forward.sh — reach the pods from your desktop as if they were local
#  (kubectl port-forward, all in one terminal, auto-reconnects when a pod restarts).
#
#    tools/forward.sh                    # forward everything below
#    tools/forward.sh keycloak postgres  # only some
#    tools/forward.sh --lan              # also let OTHER machines on your local network connect (binds 0.0.0.0)
#    tools/forward.sh --extra apps/svc/java-store:9090:80   # any NAMESPACE/svc|pod/NAME:LOCAL:REMOTE
#    Ctrl-C stops all forwards.
#
#  target      local port  what you get
#  keycloak    8180        http://localhost:8180/admin/   (admin console + realm endpoints)
#  keycloak-mgmt 9000      http://localhost:9000/health   (management: health, metrics)
#  postgres    5432        psql -h localhost -U postgres   (also: DBeaver, pgAdmin, IntelliJ)
#  openldap    3389        ldap://localhost:3389           (Apache Directory Studio, ldapsearch)
#  java        8080        http://localhost:8080           (the Java store)
#  python      5000        http://localhost:5000           (the Python deli)
#
#  Change a port:  KEYCLOAK_PORT=18080 tools/forward.sh keycloak   (any <TARGET>_PORT, upper-case, - -> _)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
require_cmd kubectl

BIND="127.0.0.1"; EXTRA=(); SELECTED=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan) BIND="0.0.0.0"; shift ;;
    --bind) BIND="$2"; shift 2 ;;
    --extra) EXTRA+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) SELECTED+=("$1"); shift ;;
  esac
done

# name -> namespace/kind/name:LOCAL:REMOTE
declare -A FWD=(
  [keycloak]="${NS_IDENTITY}/svc/keycloak:${KEYCLOAK_PORT:-8180}:80"
  [keycloak-mgmt]="${NS_IDENTITY}/svc/keycloak:${KEYCLOAK_MGMT_PORT:-9000}:9000"
  [postgres]="${NS_DATA}/svc/postgres:${POSTGRES_PORT:-5432}:5432"
  [openldap]="${NS_IDENTITY}/svc/openldap:${OPENLDAP_PORT:-3389}:389"
  [java]="${NS_APPS}/svc/java-store:${JAVA_PORT:-8080}:80"
  [python]="${NS_APPS}/svc/python-deli:${PYTHON_PORT:-5000}:80"
)
ORDER=(keycloak keycloak-mgmt postgres openldap java python)
[[ ${#SELECTED[@]} -eq 0 ]] && SELECTED=("${ORDER[@]}")

SPECS=()
for name in "${SELECTED[@]}"; do
  [[ -n "${FWD[$name]:-}" ]] || die "unknown target '$name'. Known: ${ORDER[*]}"
  SPECS+=("$name=${FWD[$name]}")
done
for e in "${EXTRA[@]}"; do SPECS+=("extra=$e"); done

PIDS=()
cleanup() { trap - EXIT INT TERM; echo; log "stopping forwards"; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT INT TERM

# keep_forward NAME NAMESPACE KIND/NAME LOCAL REMOTE — restarts port-forward whenever it drops
keep_forward() {
  local name="$1" ns="$2" ref="$3" lport="$4" rport="$5"
  while true; do
    kubectl -n "$ns" port-forward --address "$BIND" "$ref" "${lport}:${rport}" >/dev/null 2>"/tmp/forward-${name}.log" || true
    sleep 2   # pod restarted / rollout / network blip -> reconnect
  done
}

step "Port-forwards (bind ${BIND}) — Ctrl-C to stop"
for spec in "${SPECS[@]}"; do
  name="${spec%%=*}"; rest="${spec#*=}"
  ns="${rest%%/*}"; rest="${rest#*/}"
  ref="${rest%%:*}"; ports="${rest#*:}"
  lport="${ports%%:*}"; rport="${ports#*:}"
  if ! kubectl -n "$ns" get "$ref" >/dev/null 2>&1; then
    warn "$name: $ns/$ref not found (not installed yet?) — skipping"
    continue
  fi
  keep_forward "$name" "$ns" "$ref" "$lport" "$rport" &
  PIDS+=($!)
  printf '  %-14s %s:%-5s -> %s/%s:%s\n' "$name" "$BIND" "$lport" "$ns" "$ref" "$rport"
done
[[ ${#PIDS[@]} -gt 0 ]] || die "nothing to forward"
sleep 2

HOST="localhost"; [[ "$BIND" != "127.0.0.1" ]] && HOST="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "$BIND")"
step "How to connect"
for spec in "${SPECS[@]}"; do
  case "${spec%%=*}" in
    keycloak)      echo "  Keycloak admin : http://${HOST}:${KEYCLOAK_PORT:-8180}/admin/   (user ${KC_ADMIN_USER})"
                   echo "  OIDC discovery : http://${HOST}:${KEYCLOAK_PORT:-8180}/realms/${KC_REALM}/.well-known/openid-configuration" ;;
    keycloak-mgmt) echo "  Keycloak health: http://${HOST}:${KEYCLOAK_MGMT_PORT:-9000}/health" ;;
    postgres)      echo "  Postgres       : PGPASSWORD='${PG_ADMIN_PASSWORD}' psql -h ${HOST} -p ${POSTGRES_PORT:-5432} -U postgres -d grocery"
                   echo "                   app login: user grocery / password from APP_DB_PASSWORD; databases: grocery, keycloak" ;;
    openldap)      echo "  LDAP           : ldapsearch -x -H ldap://${HOST}:${OPENLDAP_PORT:-3389} -D 'cn=admin,${LDAP_BASE_DN}' -w '${LDAP_ADMIN_PASSWORD}' -b '${LDAP_BASE_DN}'" ;;
    java)          echo "  Java store     : http://${HOST}:${JAVA_PORT:-8080}   (login works: the realm allows http://localhost:8080/*)" ;;
    python)        echo "  Python deli    : http://${HOST}:${PYTHON_PORT:-5000}   (after login you land on the public URL; that is fine)" ;;
    extra)         echo "  extra          : ${spec#*=}" ;;
  esac
done
[[ "$BIND" == "0.0.0.0" ]] && warn "--lan: anyone on your network can reach these ports (demo passwords!) — stop when done."
echo
log "forwarding... (logs in /tmp/forward-<name>.log)"
wait
