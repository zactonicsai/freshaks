#!/usr/bin/env bash
# Create the kind cluster and install Istio, Postgres and Keycloak.
# Restores backups/latest.sql (if present) before Keycloak starts.
#
# Usage:
#   ./rebuild.sh                       # build + restore latest backup
#   ./rebuild.sh --fresh               # build, ignore backups
#   ./rebuild.sh --restore FILE.sql    # build + restore a specific dump
#   ./rebuild.sh --force               # delete existing cluster first (no backup!)
#   ./rebuild.sh --refresh-charts      # re-download Helm charts
source "$(dirname "$0")/lib/common.sh"

RESTORE_FILE="$BACKUPS/latest.sql"
FRESH=false
FORCE=false
REFRESH_CHARTS=false
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh)          FRESH=true ;;
    --force)          FORCE=true ;;
    --refresh-charts) REFRESH_CHARTS=true ;;
    --restore)        shift; RESTORE_FILE="${1:?--restore needs a file}" ;;
    -h|--help)        sed -n '2,10p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

require docker kind kubectl helm curl
docker info >/dev/null 2>&1 || die "Docker is not running"

# ---- 1. Cluster ------------------------------------------------------------
if cluster_exists; then
  if $FORCE; then
    warn "Deleting existing cluster '$CLUSTER_NAME' (no backup taken)"
    kind delete cluster --name "$CLUSTER_NAME"
  else
    die "Cluster '$CLUSTER_NAME' already exists. Run ./save-and-destroy.sh first, or use --force."
  fi
fi

log "Creating kind cluster '$CLUSTER_NAME'"
kind create cluster --name "$CLUSTER_NAME" --config "$MANIFESTS/kind-config.yaml" --wait 120s
kubectl config use-context "$CONTEXT" >/dev/null

# ---- 2. Helm charts (download once, then install from local files) --------
pull_chart() {   # pull_chart <repo/chart> <dir-name> <version>
  local ref="$1" dir="$2" ver="$3"
  if $REFRESH_CHARTS; then rm -rf "${CHARTS:?}/$dir"; fi
  if [ -d "$CHARTS/$dir" ]; then
    ok "Using local chart: charts/$dir"
    return
  fi
  helm pull "$ref" --untar --untardir "$CHARTS" ${ver:+--version "$ver"}
  ok "Downloaded: charts/$dir"
}

log "Preparing local Helm charts"
mkdir -p "$CHARTS"
if $REFRESH_CHARTS || [ ! -d "$CHARTS/base" ] || [ ! -d "$CHARTS/istiod" ] \
   || [ ! -d "$CHARTS/gateway" ] || [ ! -d "$CHARTS/keycloakx" ]; then
  helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update >/dev/null
  helm repo add codecentric https://codecentric.github.io/helm-charts --force-update >/dev/null
  helm repo update >/dev/null
fi
pull_chart istio/base            base      "$ISTIO_VERSION"
pull_chart istio/istiod          istiod    "$ISTIO_VERSION"
pull_chart istio/gateway         gateway   "$ISTIO_VERSION"
pull_chart codecentric/keycloakx keycloakx "$KEYCLOAKX_VERSION"

# ---- 3. Istio --------------------------------------------------------------
log "Installing Istio (base + istiod)"
ensure_ns istio-system
h upgrade --install istio-base "$CHARTS/base"   -n istio-system --wait
h upgrade --install istiod     "$CHARTS/istiod" -n istio-system --wait --timeout 5m

log "Installing Istio ingress gateway"
ensure_ns istio-ingress
h upgrade --install istio-ingressgateway "$CHARTS/gateway" -n istio-ingress \
  -f "$MANIFESTS/gateway-values.yaml" --wait --timeout 5m

# ---- 4. Postgres -----------------------------------------------------------
log "Deploying Postgres (no sidecar)"
k apply -f "$MANIFESTS/postgres.yaml"
wait_for_postgres
ok "Postgres ready"

# ---- 5. Restore saved state ------------------------------------------------
if $FRESH; then
  log "Fresh install - skipping restore"
elif [ -s "$RESTORE_FILE" ]; then
  log "Restoring database from $RESTORE_FILE"
  k exec -i -n "$DB_NS" deploy/postgres -- \
    psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$RESTORE_FILE" >/dev/null
  ok "Restore complete"
else
  log "No backup found at $RESTORE_FILE - starting with an empty database"
fi

# ---- 6. Keycloak -----------------------------------------------------------
log "Installing Keycloak (Istio sidecar on this pod only)"
ensure_ns "$KC_NS"
h upgrade --install "$KC_RELEASE" "$CHARTS/keycloakx" -n "$KC_NS" \
  -f "$MANIFESTS/keycloak-values.yaml"

log "Applying Istio Gateway, VirtualService and egress Sidecar"
k apply -f "$MANIFESTS/keycloak-istio.yaml"

log "Waiting for Keycloak to start (first start can take a few minutes)"
k rollout status "statefulset/${KC_RELEASE}-keycloakx" -n "$KC_NS" --timeout=600s

# ---- 7. Check it's reachable from localhost --------------------------------
log "Checking $KC_URL"
code=000
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$KC_URL/" || true)"
  case "$code" in 200|302|303) break ;; esac
  sleep 5
done
if [[ "$code" =~ ^(200|302|303)$ ]]; then
  ok "Keycloak responded with HTTP $code"
else
  warn "Keycloak not reachable yet (last HTTP code: $code). Check: kubectl logs -n $KC_NS ${KC_RELEASE}-keycloakx-0 -c keycloak"
fi

k get pods -n "$DB_NS"
k get pods -n "$KC_NS"

cat <<MSG

  Keycloak admin console : $KC_URL/admin
  Login                  : admin / admin
  Save + destroy         : ./save-and-destroy.sh

MSG
