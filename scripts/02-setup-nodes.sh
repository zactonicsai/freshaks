#!/usr/bin/env bash
# =============================================================================
#  02-setup-nodes.sh — add the "apps" classrooms (node pool), the front door
#  (ingress-nginx), and optionally the certificate helper (cert-manager).
#  Saves INGRESS_IP and BASE_DOMAIN into scripts/.generated.env.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd az kubectl helm
need_generated ACR_NAME

step "1/4 Node pool 'apps' (${APPS_NODE_COUNT} x ${APPS_NODE_VM_SIZE}, label workload=apps)"
if az aks nodepool show --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --name apps >/dev/null 2>&1; then
  log "node pool already exists"
else
  az aks nodepool add \
    --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" \
    --name apps --mode User \
    --node-count "$APPS_NODE_COUNT" --node-vm-size "$APPS_NODE_VM_SIZE" \
    --labels workload=apps --output none
  log "node pool added"
fi
kubectl get nodes -L workload,agentpool

step "2/4 ingress-nginx (the front door that routes by host name)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --set controller.config.use-forwarded-headers="true" \
  --wait --timeout 10m

step "3/4 Waiting for the public IP of the front door"
INGRESS_IP=""
for _ in $(seq 1 60); do
  INGRESS_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$INGRESS_IP" ]] && break
  sleep 5
done
[[ -n "$INGRESS_IP" ]] || die "No public IP after 5 minutes. Check: kubectl -n ingress-nginx get svc"
save_generated INGRESS_IP "$INGRESS_IP"
save_generated BASE_DOMAIN "${INGRESS_IP}.nip.io"

step "4/4 TLS certificates (ENABLE_TLS=${ENABLE_TLS})"
if [[ "$ENABLE_TLS" == "true" ]]; then
  [[ "$LETSENCRYPT_EMAIL" != "you@example.com" ]] || die "Set LETSENCRYPT_EMAIL in scripts/00-config.sh first."
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace --set crds.enabled=true --wait --timeout 10m
  kubectl apply -f - <<EOT
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOT
  log "cert-manager + ClusterIssuer letsencrypt-prod ready"
else
  log "skipping (plain http). Set ENABLE_TLS=true in 00-config.sh to enable."
fi

log "Done. Your sites will live under *.${BASE_DOMAIN}. Next: scripts/03-install-postgres.sh"
