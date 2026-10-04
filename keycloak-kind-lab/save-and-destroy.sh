#!/usr/bin/env bash
# Back up the Keycloak database, then delete the kind cluster.
#
# Usage:
#   ./save-and-destroy.sh            # backup, ask, destroy
#   ./save-and-destroy.sh -y         # backup + destroy, no prompt
#   ./save-and-destroy.sh --save-only
source "$(dirname "$0")/lib/common.sh"

SAVE_ONLY=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --save-only) SAVE_ONLY=true ;;
    -y|--yes)    ASSUME_YES=true ;;
    -h|--help)   sed -n '2,7p' "$0"; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done

require kind kubectl
cluster_exists || die "kind cluster '$CLUSTER_NAME' does not exist - nothing to save"

# ---- 1. Save state ---------------------------------------------------------
log "Saving Keycloak database from Postgres"
k get deployment postgres -n "$DB_NS" >/dev/null 2>&1 \
  || die "Postgres deployment not found in namespace '$DB_NS'"
wait_for_postgres

mkdir -p "$BACKUPS"
ts="$(date +%Y%m%d-%H%M%S)"
file="$BACKUPS/keycloak-$ts.sql"

k exec -n "$DB_NS" deploy/postgres -- \
  pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner > "$file.tmp"

[ -s "$file.tmp" ] || { rm -f "$file.tmp"; die "Dump is empty - aborting, cluster NOT deleted"; }
mv "$file.tmp" "$file"
cp "$file" "$BACKUPS/latest.sql"
ok "Saved: $file ($(wc -c < "$file") bytes)"
ok "Copied to: $BACKUPS/latest.sql"

# Keep only the newest $KEEP_BACKUPS timestamped dumps
ls -1t "$BACKUPS"/keycloak-*.sql 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))" | while read -r old; do
  rm -f "$old"
done

if $SAVE_ONLY; then
  log "Done (save only, cluster left running)"
  exit 0
fi

# ---- 2. Destroy ------------------------------------------------------------
if ! $ASSUME_YES; then
  printf '\nDelete kind cluster "%s"? [y/N] ' "$CLUSTER_NAME"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || { warn "Cancelled. Backup kept, cluster still running."; exit 0; }
fi

log "Deleting kind cluster '$CLUSTER_NAME'"
kind delete cluster --name "$CLUSTER_NAME"
ok "Cluster deleted. Rebuild with: ./rebuild.sh"
