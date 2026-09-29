#!/usr/bin/env bash
# =============================================================================
#  tools/shell.sh — open a shell (or run a command) INSIDE a pod.
#
#    tools/shell.sh                      # list targets and their pods
#    tools/shell.sh keycloak             # bash inside the Keycloak pod
#    tools/shell.sh postgres psql        # psql as the admin user (password filled in)
#    tools/shell.sh postgres psql -d grocery -c 'select count(*) from activity_log'
#    tools/shell.sh openldap ldapsearch  # ldapsearch already bound as the LDAP admin
#    tools/shell.sh openldap ldapsearch '(uid=riley*)' uid mail
#    tools/shell.sh keycloak kcadm get users -r grocery --fields username
#    tools/shell.sh java                 # bash inside the Java store container
#    tools/shell.sh python -- python -c 'import app; print(app.db.MENU)'
#    tools/shell.sh -c nginx ingress     # pick a container (multi-container pods)
#
#  Targets: keycloak postgres openldap java python ingress  (or any  NAMESPACE/POD-NAME)
#  Everything after the target is run inside the pod; nothing = interactive shell.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
require_cmd kubectl

CONTAINER=""
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -c|--container) CONTAINER="$2"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    --) shift; break ;;
    *) die "unknown option $1" ;;
  esac
done

# target -> "namespace|label-selector"
declare -A TARGETS=(
  [keycloak]="${NS_IDENTITY}|app.kubernetes.io/name=keycloak"
  [postgres]="${NS_DATA}|app=postgres"
  [openldap]="${NS_IDENTITY}|app=openldap"
  [java]="${NS_APPS}|app=java-store"
  [python]="${NS_APPS}|app=python-deli"
  [ingress]="ingress-nginx|app.kubernetes.io/name=ingress-nginx"
)

running_pod() { # namespace selector
  kubectl -n "$1" get pod -l "$2" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

if [[ $# -eq 0 ]]; then
  echo "Targets (tools/shell.sh <target> [command...]):"
  for t in keycloak postgres openldap java python ingress; do
    IFS='|' read -r ns sel <<<"${TARGETS[$t]}"
    pod="$(running_pod "$ns" "$sel")"
    printf '  %-10s namespace %-14s pod %s\n' "$t" "$ns" "${pod:-(not running)}"
  done
  exit 0
fi

TARGET="$1"; shift
if [[ -n "${TARGETS[$TARGET]:-}" ]]; then
  IFS='|' read -r NS SEL <<<"${TARGETS[$TARGET]}"
  POD="$(running_pod "$NS" "$SEL")"
  [[ -n "$POD" ]] || die "no running pod for '$TARGET' in namespace $NS (kubectl -n $NS get pods)"
elif [[ "$TARGET" == */* ]]; then
  NS="${TARGET%%/*}"; POD="${TARGET#*/}"
else
  die "unknown target '$TARGET'. Use one of: ${!TARGETS[*]}  or NAMESPACE/POD"
fi
[[ "$1" == "--" ]] 2>/dev/null && shift

CARGS=(); [[ -n "$CONTAINER" ]] && CARGS=(-c "$CONTAINER")
TTY=(-i); [[ -t 0 && -t 1 ]] && TTY=(-it)
x() { kubectl -n "$NS" exec "${TTY[@]}" "${CARGS[@]}" "$POD" -- "$@"; }

# ---- handy shortcuts (passwords come from 00-config.sh) --------------------------
case "${TARGET}:${1:-}" in
  postgres:psql)      shift; x env "PGPASSWORD=${PG_ADMIN_PASSWORD}" psql -U postgres "$@" ;;
  postgres:grocery)   shift; x env "PGPASSWORD=${APP_DB_PASSWORD}" psql -U grocery -d grocery "$@" ;;   # the apps' own login
  keycloak:kcadm)     shift
                      x /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master \
                        --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD" --config /tmp/kcadm.config >/dev/null
                      x /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config ;;
  openldap:ldapsearch) shift
                      x ldapsearch -x -H ldap://localhost -D "cn=admin,${LDAP_BASE_DN}" -w "$LDAP_ADMIN_PASSWORD" \
                        -b "$LDAP_BASE_DN" "${@:-(objectClass=*)}" ;;
  *:)                 log "shell in $NS/$POD (type 'exit' to leave)"
                      x sh -c 'command -v bash >/dev/null && exec bash || exec sh' ;;
  *)                  x "$@" ;;
esac
