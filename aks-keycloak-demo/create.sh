#!/usr/bin/env bash
# =============================================================================
# create.sh - builds everything:
#
#   Azure resource group
#     +- Container registry (holds the Java app image)
#     +- AKS cluster with the Istio add-on
#          +- Istio ingress gateway (the front door, locked to ALLOWED_IP)
#          +- namespace "demo" (every pod gets an Istio sidecar)
#               +- postgres  (database)
#               +- keycloak  (login server, saves into postgres)
#               +- app       (Java app: public, private and group pages)
#
# It is safe to run this script again. Steps that are already done are skipped.
# Run time: about 15-20 minutes the first time.
# Size: the cheapest setup that works - 1 node with 4 CPUs (see config.sh).
# =============================================================================

# Stop right away if any command fails (-e), if we use a variable that was
# never set (-u), or if one part of a "a | b" pipe fails (pipefail).
set -euo pipefail

# Load the settings and the little helper functions.
# shellcheck source=config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

# -----------------------------------------------------------------------------
step "Step 0: Checking that your computer has the tools we need"
# -----------------------------------------------------------------------------
# "command -v X" asks: is there a program called X?
for tool in az kubectl openssl curl sed; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed. See README, 'What you need first'."
done

# The Istio commands ("az aks mesh ...") need Azure CLI 2.57.0 or newer.
AZ_VERSION="$(az version --query '"azure-cli"' --output tsv)"
OLDEST="$(printf '%s\n' "2.57.0" "$AZ_VERSION" | sort -V | head -n 1)"
[[ "$OLDEST" == "2.57.0" ]] || die "Azure CLI $AZ_VERSION is too old. Run: az upgrade"

# "az account show" only works if you are logged in.
az account show >/dev/null 2>&1 || die "You are not logged in to Azure. Run: az login"
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
info "Using subscription: $(az account show --query name --output tsv)"

# Make sure ALLOWED_IP looks like an IPv4 address (four numbers with dots).
[[ "$ALLOWED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "ALLOWED_IP='$ALLOWED_IP' is not an IPv4 address."
# "/32" means "exactly this one address, no neighbors".
ALLOWED_CIDR="${ALLOWED_IP}/32"

# Ask a public website "what is my internet address?". This is only used to
# warn you; if the website is down we just carry on.
MY_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
if [[ "$MY_IP" == "$ALLOWED_IP" ]]; then
  info "This computer's internet address is $MY_IP. It matches ALLOWED_IP."
else
  warn "This computer's internet address is '${MY_IP:-unknown}', but ALLOWED_IP is $ALLOWED_IP."
  warn "The cluster will be built, but only $ALLOWED_IP will be able to open Keycloak."
fi

# The registry name must be unique in ALL of Azure and may only use letters and
# numbers. We glue a number onto the end. "cksum" turns your subscription ID
# into a number, so you get the same name every time you run this.
ACR_NAME="${ACR_NAME:-acrkcdemo$(printf '%s' "${SUBSCRIPTION_ID}${RESOURCE_GROUP}" | cksum | cut -d ' ' -f 1)}"

# -----------------------------------------------------------------------------
step "Step 1: Turning on the Azure features we need"
# -----------------------------------------------------------------------------
# A brand-new subscription has most features switched off. "provider register"
# switches one on. Doing it twice does no harm.
for provider in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.Network Microsoft.Compute Microsoft.Storage; do
  az provider register --namespace "$provider" --wait --output none
done

# -----------------------------------------------------------------------------
step "Step 2: Creating the resource group '$RESOURCE_GROUP' in $LOCATION"
# -----------------------------------------------------------------------------
# The box that holds everything. Later, deleting this box deletes it all.
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags purpose=keycloak-demo \
  --output none

# -----------------------------------------------------------------------------
step "Step 3: Creating the container registry '$ACR_NAME'"
# -----------------------------------------------------------------------------
# A registry is a private shelf for app images. The cluster pulls our Java app
# from this shelf.
if az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  info "Already there. Skipping."
else
  az acr create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --sku Basic \
    --admin-enabled false \
    --output none
  # --sku Basic            the cheapest size
  # --admin-enabled false  no shared password; the cluster uses its own identity
fi
ACR_LOGIN_SERVER="$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query loginServer --output tsv)"

# -----------------------------------------------------------------------------
step "Step 4: Creating the AKS cluster '$CLUSTER_NAME' with Istio (about 10 minutes)"
# -----------------------------------------------------------------------------
if az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  info "Already there. Skipping."
else
  # ---- Pick the node size ----
  # Azure gives every subscription a "quota": the most CPUs you may use, counted
  # per VM family and per region. If the quota is 0, the cluster cannot be made.
  # So we ask Azure for the quota list ONCE, and take the first (cheapest) size
  # that fits.
  if [[ "$NODE_VM_SIZE" == "auto" ]]; then
    CPUS_NEEDED=$((NODE_COUNT * VM_SIZE_CPUS))
    # Each line of the answer looks like:  standardbsfamily  0  10
    #                                      (family name, used, limit)
    # "tr" makes it all lower-case so the names are easy to compare.
    QUOTA_LIST="$(az vm list-usage --location "$LOCATION" \
      --query "[].[name.value, currentValue, limit]" --output tsv | tr '[:upper:]' '[:lower:]')"

    # free_cpus NAME -> prints how many CPUs are still free (limit minus used).
    free_cpus() {
      local name
      name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
      awk -v name="$name" '$1 == name { print $3 - $2; found = 1 } END { if (!found) print 0 }' <<< "$QUOTA_LIST"
    }

    # "cores" is the limit for the whole region, all families added together.
    REGION_FREE="$(free_cpus cores)"
    [[ "$REGION_FREE" -ge "$CPUS_NEEDED" ]] || die "Region $LOCATION has only $REGION_FREE free CPUs in total; $CPUS_NEEDED are needed. Try another LOCATION or ask for more quota (README, Troubleshooting)."

    NODE_VM_SIZE=""
    for choice in $VM_SIZE_CHOICES; do
      size="${choice%%:*}"      # the part before the ":"
      family="${choice##*:}"    # the part after the ":"
      free="$(free_cpus "$family")"
      if [[ "$free" -ge "$CPUS_NEEDED" ]]; then
        NODE_VM_SIZE="$size"
        info "Picked node size $size ($free free CPUs in $family)."
        break
      fi
      info "Skipping $size: only $free free CPUs in $family, need $CPUS_NEEDED."
    done
    [[ -n "$NODE_VM_SIZE" ]] || die "No size in VM_SIZE_CHOICES has $CPUS_NEEDED free CPUs in $LOCATION. Try another LOCATION or ask for more quota (README, Troubleshooting)."
  fi

  # If you are sitting at ALLOWED_IP, we also lock the cluster's control room
  # (the "API server" that kubectl talks to) so only your address can use it.
  # If you are somewhere else, we skip this lock, or this script would lock
  # itself out half way through.
  API_LOCK=()
  if [[ "$MY_IP" == "$ALLOWED_IP" ]]; then
    API_LOCK=(--api-server-authorized-ip-ranges "$ALLOWED_CIDR")
    info "The Kubernetes API will only answer $ALLOWED_CIDR."
  else
    warn "Not locking the Kubernetes API to $ALLOWED_IP (you are not there). See README to add it later."
  fi

  az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER_NAME" \
    --location "$LOCATION" \
    --node-count "$NODE_COUNT" \
    --node-vm-size "$NODE_VM_SIZE" \
    --node-osdisk-size "$NODE_DISK_GB" \
    --tier free \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --enable-managed-identity \
    --enable-asm \
    --attach-acr "$ACR_NAME" \
    --no-ssh-key \
    ${API_LOCK[@]+"${API_LOCK[@]}"} \
    --output none
  # --node-count / --node-vm-size  how many worker computers, and how big
  # --node-osdisk-size             a small disk per node (smaller = cheaper)
  # --tier free                    do not pay for the control room (fine for a demo)
  # --network-plugin azure + overlay  Azure's recommended pod networking
  # --enable-managed-identity      the cluster gets its own Azure ID, no passwords
  # --enable-asm                   install the Istio add-on (asm = Azure Service Mesh)
  # --attach-acr                   let the cluster pull images from our registry
  # --no-ssh-key                   nobody can SSH into the nodes (we never need to)
  # ${API_LOCK[@]+...}             adds the API lock only if we set it above
fi

# -----------------------------------------------------------------------------
step "Step 5: Connecting kubectl to the cluster"
# -----------------------------------------------------------------------------
# This downloads the cluster's address and a login key into ~/.kube/config so
# that the "kubectl" command knows where to go.
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing \
  --output none
kubectl get nodes

# -----------------------------------------------------------------------------
step "Step 6: Turning on the Istio ingress gateway (the front door)"
# -----------------------------------------------------------------------------
# The add-on does not open a door to the internet until we ask for one.
# "external" means it gets a public IP address.
GATEWAY_ON="$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
  --query "serviceMeshProfile.istio.components.ingressGateways[?mode=='External'].enabled | [0]" --output tsv)"
if [[ "$GATEWAY_ON" == "true" ]]; then
  info "Already on. Skipping."
else
  az aks mesh enable-ingress-gateway \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER_NAME" \
    --ingress-gateway-type external \
    --output none
fi

# Istio on AKS has a version name called a "revision", like asm-1-26.
# We need it for the namespace label in Step 9.
ISTIO_REVISION="$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" \
  --query 'serviceMeshProfile.istio.revisions[0]' --output tsv)"
[[ -n "$ISTIO_REVISION" ]] || die "Could not read the Istio revision. Is the Istio add-on enabled?"
info "Istio revision: $ISTIO_REVISION"

# Wait until the gateway's Service shows up in the cluster.
for _ in $(seq 1 30); do
  kubectl get service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" >/dev/null 2>&1 && break
  sleep 10
done
kubectl get service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" >/dev/null 2>&1 \
  || die "The ingress gateway Service never appeared. See README, Troubleshooting."

# -----------------------------------------------------------------------------
step "Step 7: Locking the front door"
# -----------------------------------------------------------------------------
# externalTrafficPolicy=Local keeps the visitor's REAL internet address.
# Without it, every visitor would look like one of our own nodes, and the
# "only this IP" rule in Istio could not work.
kubectl patch service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" \
  --type merge --patch '{"spec":{"externalTrafficPolicy":"Local"}}'

if [[ "$LOCK_APP_TO_ALLOWED_IP" == "true" ]]; then
  # This note on the Service tells Azure: "at the firewall, only let ALLOWED_IP
  # reach this load balancer". Other people's traffic never enters the cluster.
  kubectl annotate service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" \
    "service.beta.kubernetes.io/azure-allowed-ip-ranges=${ALLOWED_CIDR}" --overwrite
  info "Azure firewall: only $ALLOWED_CIDR may reach the gateway."
else
  # A "-" at the end of the name means "remove this note".
  kubectl annotate service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" \
    "service.beta.kubernetes.io/azure-allowed-ip-ranges-"
  warn "The app is open to the whole internet. Keycloak is still locked by Istio."
fi

# -----------------------------------------------------------------------------
step "Step 8: Finding the gateway's public IP address"
# -----------------------------------------------------------------------------
# Azure needs a minute or two to hand out the address, so we ask again and again.
INGRESS_IP=""
for _ in $(seq 1 36); do
  INGRESS_IP="$(kubectl get service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" \
    --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$INGRESS_IP" ]] && break
  sleep 10
done
[[ -n "$INGRESS_IP" ]] || die "The gateway did not get a public IP in 6 minutes. See README, Troubleshooting."

# nip.io is a free service: the name "anything.1.2.3.4.nip.io" always points
# to 1.2.3.4. That gives us two website names without buying a domain.
APP_HOST="app.${INGRESS_IP}.nip.io"
KC_HOST="keycloak.${INGRESS_IP}.nip.io"
info "Gateway IP : $INGRESS_IP"
info "App        : https://$APP_HOST"
info "Keycloak   : https://$KC_HOST"

# -----------------------------------------------------------------------------
step "Step 9: Making the 'demo' namespace with sidecar injection"
# -----------------------------------------------------------------------------
mkdir -p "$RENDER_DIR"
chmod 700 "$RENDER_DIR"

# render: copy a template into .rendered/ and swap each __PLACEHOLDER__ for
# its real value. "sed" is a find-and-replace tool.
render() {
  local source_file="$1" target_file="$2"
  sed \
    -e "s|__ISTIO_REVISION__|${ISTIO_REVISION}|g" \
    -e "s|__APP_HOST__|${APP_HOST}|g" \
    -e "s|__KC_HOST__|${KC_HOST}|g" \
    -e "s|__ALLOWED_CIDR__|${ALLOWED_CIDR}|g" \
    -e "s|__KEYCLOAK_VERSION__|${KEYCLOAK_VERSION}|g" \
    -e "s|__APP_IMAGE__|${APP_IMAGE:-}|g" \
    -e "s|__OIDC_CLIENT_SECRET__|${OIDC_CLIENT_SECRET:-}|g" \
    -e "s|__ALICE_PASSWORD__|${ALICE_PASSWORD:-}|g" \
    -e "s|__BOB_PASSWORD__|${BOB_PASSWORD:-}|g" \
    -e "s|__CAROL_PASSWORD__|${CAROL_PASSWORD:-}|g" \
    "$source_file" > "$target_file"
}

render "$PROJECT_DIR/k8s/00-namespace.yaml" "$RENDER_DIR/00-namespace.yaml"
# "kubectl apply" means: make the cluster look like this file.
kubectl apply --filename "$RENDER_DIR/00-namespace.yaml"

# -----------------------------------------------------------------------------
step "Step 10: Making passwords"
# -----------------------------------------------------------------------------
# Passwords are made up by the computer (random), never typed into a file by
# hand. They are saved in .secrets.env so a second run uses the SAME ones.
# (Postgres only sets its password the first time it starts. A new password on
# the second run would lock Keycloak out of its own database.)
if [[ ! -f "$SECRETS_FILE" ]]; then
  (
    umask 077   # only you can read the new file
    {
      echo "# Made by create.sh. Keep private. Removed by destroy.sh."
      echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)"
      echo "KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -hex 12)"
      echo "OIDC_CLIENT_SECRET=$(openssl rand -hex 24)"
      echo "ALICE_PASSWORD=$(openssl rand -hex 8)"
      echo "BOB_PASSWORD=$(openssl rand -hex 8)"
      echo "CAROL_PASSWORD=$(openssl rand -hex 8)"
    } > "$SECRETS_FILE"
  )
  info "New passwords saved in .secrets.env"
else
  info "Using the passwords already in .secrets.env"
fi
# shellcheck source=/dev/null
source "$SECRETS_FILE"

# A Kubernetes Secret is a locked note inside the cluster. Pods that need a
# password read it from the Secret.
# "--dry-run=client -o yaml | kubectl apply" = "write the Secret as text, then
# apply it". This way the command works the first time AND on later runs.
kubectl create secret generic postgres-credentials --namespace "$NAMESPACE" \
  --from-literal=username=keycloak \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --dry-run=client --output yaml | kubectl apply --filename -

kubectl create secret generic keycloak-admin --namespace "$NAMESPACE" \
  --from-literal=username=admin \
  --from-literal=password="$KEYCLOAK_ADMIN_PASSWORD" \
  --dry-run=client --output yaml | kubectl apply --filename -

kubectl create secret generic app-oidc --namespace "$NAMESPACE" \
  --from-literal=client-secret="$OIDC_CLIENT_SECRET" \
  --dry-run=client --output yaml | kubectl apply --filename -

# The realm file sets up Keycloak: the realm "demo", the group "managers",
# the users alice, bob and carol, and the login client for the Java app.
render "$PROJECT_DIR/keycloak/realm-template.json" "$RENDER_DIR/demo-realm.json"
kubectl create secret generic keycloak-realm --namespace "$NAMESPACE" \
  --from-file=demo-realm.json="$RENDER_DIR/demo-realm.json" \
  --dry-run=client --output yaml | kubectl apply --filename -

# -----------------------------------------------------------------------------
step "Step 11: Making the HTTPS certificate"
# -----------------------------------------------------------------------------
# A certificate lets the browser encrypt what you type (like passwords).
# This one is "self-signed": we made it ourselves, so the browser will show a
# warning the first time. That is expected here. See README for a real one.
TLS_CERT="$RENDER_DIR/tls.crt"
TLS_KEY="$RENDER_DIR/tls.key"
if [[ -f "$TLS_CERT" ]] && openssl x509 -in "$TLS_CERT" -noout -text | grep -q "DNS:${KC_HOST}"; then
  info "Certificate for these names already exists. Keeping it."
else
  ( umask 077
    openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
      -keyout "$TLS_KEY" -out "$TLS_CERT" \
      -subj "/CN=${APP_HOST}" \
      -addext "subjectAltName=DNS:${APP_HOST},DNS:${KC_HOST}" 2>/dev/null )
  # -x509        make a certificate right now (do not ask a company for one)
  # -newkey      also make a new secret key
  # -nodes       do not put a password on the key (the gateway must read it)
  # -days 90     it stops working after 90 days
  # -addext      the two website names this certificate is good for
fi
# GOTCHA: the certificate Secret must live in the GATEWAY's namespace
# (aks-istio-ingress), not in "demo".
kubectl create secret tls demo-tls --namespace "$INGRESS_NAMESPACE" \
  --cert "$TLS_CERT" --key "$TLS_KEY" \
  --dry-run=client --output yaml | kubectl apply --filename -

# -----------------------------------------------------------------------------
step "Step 12: Building the Java app image in Azure (about 3 minutes)"
# -----------------------------------------------------------------------------
# "az acr build" uploads the app folder and builds the image in the cloud.
# You do NOT need Docker or Java on your own computer.
# The tag is the date and time, so every build gets a new name.
IMAGE_TAG="$(date +%Y%m%d%H%M%S)"
az acr build \
  --registry "$ACR_NAME" \
  --image "demo-app:${IMAGE_TAG}" \
  "$PROJECT_DIR/app"
APP_IMAGE="${ACR_LOGIN_SERVER}/demo-app:${IMAGE_TAG}"

# -----------------------------------------------------------------------------
step "Step 13: Putting everything into the cluster"
# -----------------------------------------------------------------------------
for file in 10-postgres 20-keycloak 30-app 40-istio-gateway 50-istio-security; do
  render "$PROJECT_DIR/k8s/${file}.yaml" "$RENDER_DIR/${file}.yaml"
done

# The locks go on FIRST, the front-door signposts go on LAST. That way there is
# never a moment when Keycloak is reachable without its locks.
kubectl apply --filename "$RENDER_DIR/50-istio-security.yaml"
kubectl apply --filename "$RENDER_DIR/10-postgres.yaml"
kubectl apply --filename "$RENDER_DIR/20-keycloak.yaml"
kubectl apply --filename "$RENDER_DIR/30-app.yaml"

# "rollout status" waits until the pods are up and healthy.
info "Waiting for Postgres..."
kubectl rollout status statefulset/postgres --namespace "$NAMESPACE" --timeout=300s
info "Waiting for Keycloak (it is slow, 2-4 minutes is normal)..."
kubectl rollout status deployment/keycloak --namespace "$NAMESPACE" --timeout=600s
info "Waiting for the Java app..."
kubectl rollout status deployment/app --namespace "$NAMESPACE" --timeout=300s

kubectl apply --filename "$RENDER_DIR/40-istio-gateway.yaml"

# -----------------------------------------------------------------------------
step "Step 14: Checking that it all works"
# -----------------------------------------------------------------------------
# verify.sh may report problems; we still want to print the summary below.
"$PROJECT_DIR/verify.sh" || warn "Some checks did not pass. Read the lines above and README, Troubleshooting."

# -----------------------------------------------------------------------------
step "All done"
# -----------------------------------------------------------------------------
cat <<SUMMARY

  Open these from $ALLOWED_IP (your browser will warn about the certificate once
  for EACH address - choose "Advanced" and continue):

    Java app        https://$APP_HOST
      /             public page   (anyone)
      /private      private page  (alice, bob or carol)
      /group        group page    (alice or bob - they are in "managers")

    Keycloak admin  https://$KC_HOST/admin     (user: admin)

  Passwords are in:  $SECRETS_FILE
    show them with:  cat .secrets.env

  When you are finished, run ./destroy.sh so Azure stops charging you.

SUMMARY
