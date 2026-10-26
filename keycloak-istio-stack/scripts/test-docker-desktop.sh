#!/usr/bin/env bash
# Installs a local test release on your CURRENT kube-context and checks Istio routing.
# Requires: kubectl, helm, curl, openssl, python3 (used only to validate discovery JSON).
# The script DOES NOT create an Istio Gateway, change your kube-context, or delete PVCs.
set -euo pipefail
umask 077

set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Override these with environment variables to reuse an existing gateway/service.
NAMESPACE="${NAMESPACE:-identity-demo}"
RELEASE="${RELEASE:-identity}"
GATEWAY_REF="${GATEWAY_REF:-istio-system/local-keycloak-gateway}"
INGRESS_SERVICE_NAMESPACE="${INGRESS_SERVICE_NAMESPACE:-istio-system}"
INGRESS_SERVICE="${INGRESS_SERVICE:-istio-ingressgateway}"
HOSTNAME="${HOSTNAME_OVERRIDE:-keycloak.localhost}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
REALM_NAME="${REALM_NAME:-team-demo}"

for binary in kubectl helm curl openssl python3; do
  command -v "$binary" >/dev/null || { echo "ERROR: missing $binary" >&2; exit 1; }
done

# Avoid accidental deployments to an arbitrary cloud account or cluster.
CURRENT_CONTEXT="$(kubectl config current-context)"
echo "Current Kubernetes context: $CURRENT_CONTEXT"
if [[ "${CONFIRM_CONTEXT:-}" != "$CURRENT_CONTEXT" ]]; then
  echo "SAFETY STOP: Re-run with CONFIRM_CONTEXT='$CURRENT_CONTEXT' to approve this exact context." >&2
  exit 2
fi

kubectl cluster-info >/dev/null

GATEWAY_NAMESPACE="${GATEWAY_REF%%/*}"
GATEWAY_NAME="${GATEWAY_REF#*/}"
if [[ "$GATEWAY_NAMESPACE" == "$GATEWAY_REF" || -z "$GATEWAY_NAME" ]]; then
  echo "ERROR: GATEWAY_REF must be namespace/name" >&2
  exit 1
fi

echo "Checking the EXISTING Gateway $GATEWAY_REF ..."
#kubectl -n "$GATEWAY_NAMESPACE" get gateways.networking.istio.io "$GATEWAY_NAME" >/dev/null
#kubectl -n "$INGRESS_SERVICE_NAMESPACE" get service "$INGRESS_SERVICE" >/dev/null

# Istio Gateways can list hosts as *, hostname, namespace/hostname, or namespace/*.
#GATEWAY_HOSTS="$(kubectl -n "$GATEWAY_NAMESPACE" get gateways.networking.istio.io "$GATEWAY_NAME" \
#  -o jsonpath='{range .spec.servers[*].hosts[*]}{.}{"\n"}{end}')"
HOST_ALLOWED=false
while IFS= read -r gateway_host; do
  case "$gateway_host" in
    '*'|"$HOSTNAME"|"*/$HOSTNAME"|"$NAMESPACE/$HOSTNAME"|"$NAMESPACE/*"|'*/*')
      HOST_ALLOWED=true ;;
  esac
  # Also accept DNS-suffix wildcards, such as *.localhost matching keycloak.localhost.
  if [[ "$gateway_host" == \*.* ]]; then
    wildcard_suffix="${gateway_host#\*.}"
    if [[ "$HOSTNAME" == *."$wildcard_suffix" ]]; then
      HOST_ALLOWED=true
    fi
  fi
done <<< "$GATEWAY_HOSTS"

if [[ "$HOST_ALLOWED" != true ]]; then
  echo "ERROR: Gateway does not list '$HOSTNAME' or a matching wildcard." >&2
  echo "Existing hosts:" >&2
  echo "$GATEWAY_HOSTS" >&2
  echo "Update your existing Gateway or set HOSTNAME_OVERRIDE to an allowed host." >&2
  exit 1
fi

echo "Creating or reusing namespace and pre-existing Secrets ..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Generate local lab passwords without echoing them or storing them in Helm values.
# The temporary directory is deleted when the script exits; existing Secrets are never overwritten.
TMP_DIR="$(mktemp -d)"
PORT_FORWARD_PID=""
cleanup() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
  rm -f "$TMP_DIR/db-password" "$TMP_DIR/admin-password" "$TMP_DIR/discovery.json" "$TMP_DIR/port-forward.log"
  rmdir "$TMP_DIR"
}
trap cleanup EXIT

if ! kubectl -n "$NAMESPACE" get secret keycloak-db >/dev/null 2>&1; then
  printf '%s' "$(openssl rand -hex 32)" >"$TMP_DIR/db-password"
  kubectl -n "$NAMESPACE" create secret generic keycloak-db \
    --from-file=password="$TMP_DIR/db-password" >/dev/null
  echo "Created keycloak-db Secret."
else
  echo "Reusing keycloak-db Secret."
fi

if ! kubectl -n "$NAMESPACE" get secret keycloak-admin >/dev/null 2>&1; then
  printf '%s' "$(openssl rand -hex 24)" >"$TMP_DIR/admin-password"
  kubectl -n "$NAMESPACE" create secret generic keycloak-admin \
    --from-literal=username=admin \
    --from-file=password="$TMP_DIR/admin-password" >/dev/null
  echo "Created keycloak-admin Secret."
else
  echo "Reusing keycloak-admin Secret."
fi

echo "Linting / rendering before deployment ..."
"$SCRIPT_DIR/lint.sh"

echo "Installing/upgrading $RELEASE in $NAMESPACE ..."
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --values "$CHART_DIR/values-local.yaml" \
  --set-string "istio.gateways[0]=$GATEWAY_REF" \
  --set-string "istio.host=$HOSTNAME" \
  --set-string "keycloak.hostname=http://$HOSTNAME:$LOCAL_PORT" \
  --set-string "realm.name=$REALM_NAME" \
  --wait --timeout 10m --atomic

echo "Checking pod availability ..."
kubectl -n "$NAMESPACE" rollout status "deployment/$RELEASE-keycloak-istio-stack-keycloak" --timeout=5m
kubectl -n "$NAMESPACE" rollout status "statefulset/$RELEASE-keycloak-istio-stack-postgresql" --timeout=5m

echo "Testing the internal service and imported realm ..."
helm test "$RELEASE" --namespace "$NAMESPACE" --logs --timeout 3m

echo "Opening a temporary gateway port-forward: localhost:$LOCAL_PORT -> $INGRESS_SERVICE:80"
kubectl -n "$INGRESS_SERVICE_NAMESPACE" port-forward "service/$INGRESS_SERVICE" \
  "$LOCAL_PORT:80" >"$TMP_DIR/port-forward.log" 2>&1 &
PORT_FORWARD_PID=$!

echo "Checking public OIDC discovery through Istio ..."
DISCOVERY_URL="http://$HOSTNAME:$LOCAL_PORT/realms/$REALM_NAME/.well-known/openid-configuration"
curl --noproxy '*' --fail --silent --show-error --retry 20 --retry-delay 2 --retry-connrefused \
  --resolve "$HOSTNAME:$LOCAL_PORT:127.0.0.1" \
  "$DISCOVERY_URL" -o "$TMP_DIR/discovery.json"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); expected=sys.argv[2]; actual=p.get("issuer"); print("OIDC issuer:",actual); sys.exit(0 if actual == expected else 1)' \
  "$TMP_DIR/discovery.json" "http://$HOSTNAME:$LOCAL_PORT/realms/$REALM_NAME"

echo "PASS: Istio routed the OIDC discovery request to Keycloak and the realm exists."
echo "To browse later, run in a separate terminal:"
echo "  kubectl -n $INGRESS_SERVICE_NAMESPACE port-forward svc/$INGRESS_SERVICE $LOCAL_PORT:80"
echo "Then open: http://$HOSTNAME:$LOCAL_PORT/admin/"
echo "The generated admin password is held in Kubernetes Secret keycloak-admin (not printed here)."
