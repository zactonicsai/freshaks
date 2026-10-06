#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
#  lib/platform.sh - every command that talks to Docker, kind, istioctl or FreeIPA.
#  Keeping them in one file makes the other scripts easy to read, and lets the
#  tests swap these functions for stand-ins (see tests/TEST-REPORT.md).
# ============================================================================

# ---------------------------------------------------------------- nodes -----
node_names() { k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
node_has_label() { k get nodes -l "$2" -o name 2>/dev/null | grep -qx "node/$1"; }   # NODE "key=value"
nodes_of_selector() { k get nodes -l "$1" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
# Prints 1 when that node's Linux kernel runs in FIPS mode, else 0.
# kind nodes are Docker containers, so we can look inside with "docker exec".
# A container always shows the value of the HOST kernel: FIPS mode can not be turned on per container.
node_kernel_fips() {
  local v
  v="$(docker exec "$1" cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)"
  if [ "$v" = 1 ]; then echo 1; else echo 0; fi
}
label_nodes_with_fips_flag() {
  local n flag
  for n in $(node_names); do
    if [ "$(node_kernel_fips "$n")" = 1 ]; then flag=true; else flag=false; fi
    k label node "$n" "fipsdemo.test/kernel-fips=$flag" --overwrite >/dev/null
    log "node $n: kernel FIPS mode = $flag"
  done
}

# --------------------------------------------------------------- images -----
image_of_profile() { if [ "$1" = fips ]; then echo "$APP_IMAGE_FIPS"; else echo "$APP_IMAGE_NONFIPS"; fi; }
build_and_load_image() { # nonfips|fips
  local profile="$1" image
  image="$(image_of_profile "$profile")"
  log "building $image from app/Dockerfile.$profile"
  docker build --pull -f "$ROOT_DIR/app/Dockerfile.$profile" \
    --build-arg "BUILDER_IMAGE=$BUILDER_IMAGE" --build-arg "RUNTIME_IMAGE=$RUNTIME_IMAGE" \
    --build-arg "APP_VERSION=${image##*:}" -t "$image" "$ROOT_DIR/app"
  log "image id: $(docker image inspect -f '{{.Id}}' "$image")"
  kind load docker-image "$image" --name "$CLUSTER_NAME"
  ok "$image is loaded into every node of cluster $CLUSTER_NAME"
}
save_images() { docker save -o "$1" "$APP_IMAGE_NONFIPS" "$APP_IMAGE_FIPS" 2>/dev/null || docker save -o "$1" "$APP_IMAGE_NONFIPS"; }
load_images() { docker load -i "$1"; local i; for i in "$APP_IMAGE_NONFIPS" "$APP_IMAGE_FIPS"; do if docker image inspect "$i" >/dev/null 2>&1; then kind load docker-image "$i" --name "$CLUSTER_NAME"; fi; done; }

# ---------------------------------------------------------------- Istio -----
# mesh_install POLICY   POLICY is "" (normal Istio) or fips-140-3 / fips-140-2
# The policy is one environment variable on istiod. Istio's injector then copies it into every
# sidecar and gateway that starts afterwards (checked in the Istio 1.31.1 charts).
mesh_install() {
  local policy="$1"
  local -a extra=()
  if [ -n "$policy" ]; then extra=(--set "values.pilot.env.COMPLIANCE_POLICY=$policy"); fi
  log "istioctl install (compliance policy: ${policy:-none})"
  istioctl --context "$KUBE_CONTEXT" install -y -f "$ROOT_DIR/k8s/istio/istio-operator.yaml" ${extra[@]+"${extra[@]}"}
  rollout_wait "$ISTIO_NS" deployment/istiod
}
mesh_policy_now() {
  k -n "$ISTIO_NS" get deployment istiod \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="COMPLIANCE_POLICY")].value}' 2>/dev/null || true
}
gateway_install() {
  k create namespace "$INGRESS_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
  k label namespace "$INGRESS_NS" istio-injection=enabled "$PART_OF_LABEL" --overwrite >/dev/null
  render "$ROOT_DIR/k8s/istio/ingress-gateway.yaml" "INGRESS_NS=$INGRESS_NS" "NODEPORT_HTTPS=$NODEPORT_HTTPS" | k apply -f -
  rollout_wait "$INGRESS_NS" deployment/istio-ingressgateway
}
gateway_restart() {   # new pods get the current compliance policy from the injector
  k -n "$INGRESS_NS" rollout restart deployment/istio-ingressgateway >/dev/null
  rollout_wait "$INGRESS_NS" deployment/istio-ingressgateway
}
gateway_policy_now() {
  k -n "$INGRESS_NS" get pods -l istio=ingressgateway \
    -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="COMPLIANCE_POLICY")].value}' 2>/dev/null || true
}

# -------------------------------------------------------------- FreeIPA -----
ipa_ip() { docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "$IPA_CONTAINER"; }
ipa_exists() { docker inspect "$IPA_CONTAINER" >/dev/null 2>&1; }
# ipa_sh: run the script given on stdin inside the FreeIPA container, already logged in as admin.
ipa_sh() {
  { printf '%s\n' 'set -e; mkdir -p /tmp/fipsdemo; export KRB5CCNAME=FILE:/tmp/fipsdemo/krb5cc_admin' \
                  'echo "$ADMIN_PW" | kinit admin >/dev/null'; cat; } |
    docker exec -i -e "ADMIN_PW=$IPA_ADMIN_PASSWORD" "$@" "$IPA_CONTAINER" bash -s
}
ipa_put() { docker exec -i "$IPA_CONTAINER" sh -c "mkdir -p /tmp/fipsdemo && cat > /tmp/fipsdemo/$2" < "$1"; }
ipa_get() { docker exec "$IPA_CONTAINER" cat "/tmp/fipsdemo/$1" > "$2"; }
ipa_is_ready() {
  docker exec -e "ADMIN_PW=$IPA_ADMIN_PASSWORD" "$IPA_CONTAINER" bash -c \
    'export KRB5CCNAME=FILE:/tmp/krb5cc_ready; echo "$ADMIN_PW" | kinit admin >/dev/null 2>&1 && ipa ping >/dev/null 2>&1'
}
ipa_start() {
  if ipa_exists; then
    log "container $IPA_CONTAINER exists already, starting it if it is stopped"
    docker start "$IPA_CONTAINER" >/dev/null
    return 0
  fi
  docker network inspect kind >/dev/null 2>&1 || die "Docker network 'kind' is missing. Run scripts/01-create-cluster.sh first."
  # FreeIPA runs systemd inside its container, and systemd must be able to write its control group.
  # The FreeIPA container project documents: with "userns-remap" Docker needs nothing extra;
  # otherwise (rootless, and in practice also plain root Docker / Docker Desktop) use the two flags below.
  local opts="$IPA_DOCKER_EXTRA_OPTS"
  if [ "$opts" = auto ]; then
    if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q 'name=userns'; then opts=""
    else opts="--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw"; fi
  fi
  log "docker run $IPA_IMAGE (extra options: ${opts:-none}). First start installs FreeIPA: 5 to 15 minutes."
  docker volume create "$IPA_VOLUME" >/dev/null
  # shellcheck disable=SC2086   # $opts is a list of flags on purpose
  docker run -d --name "$IPA_CONTAINER" --network kind \
    --hostname "$IPA_HOSTNAME" --network-alias "$IPA_HOSTNAME" \
    --read-only --sysctl net.ipv6.conf.all.disable_ipv6=0 $opts \
    -v "$IPA_VOLUME:/data" -e "PASSWORD=$IPA_ADMIN_PASSWORD" \
    "$IPA_IMAGE" ipa-server-install -U -r "$IPA_REALM" -n "$IPA_DOMAIN" --no-ntp --no-host-dns --skip-mem-check >/dev/null
}
ipa_wait_ready() {
  local i state
  for ((i = 1; i <= 180; i++)); do          # 180 x 10s = 30 minutes
    state="$(docker inspect -f '{{.State.Status}}' "$IPA_CONTAINER" 2>/dev/null || echo missing)"
    if [ "$state" != running ]; then
      err "FreeIPA container is '$state'. Last lines of its log:"; docker logs --tail 40 "$IPA_CONTAINER" 2>&1 || true
      err "Most common cause: systemd could not write its cgroup. See TUTORIAL.md, section 'When FreeIPA will not start'."
      return 1
    fi
    if ipa_is_ready; then ok "FreeIPA answers (kinit admin + ipa ping)"; return 0; fi
    if ((i % 6 == 0)); then log "still waiting for FreeIPA ($((i / 6)) min): $(docker logs --tail 1 "$IPA_CONTAINER" 2>&1 | cut -c1-110)"; fi
    sleep 10
  done
  err "FreeIPA was not ready after 30 minutes"; return 1
}
ipa_logs() { docker logs --tail 2000 "$IPA_CONTAINER" > "$1" 2>&1; }
ipa_ca_cert() { docker exec "$IPA_CONTAINER" cat /etc/ipa/ca.crt > "$1"; }
# Users, group, the app's Kerberos service and a host entry for the test client. Safe to run again.
ipa_bootstrap() {
  ipa_sh -e "U=$DEMO_USER" -e "UPW=$DEMO_USER_PASSWORD" -e "APPHOST=$APP_HOSTNAME" -e "CLIENTHOST=$CLIENT_HOSTNAME" <<'IPA'
if ! ipa user-show "$U" >/dev/null 2>&1; then
  echo "Temp-$UPW" | ipa user-add "$U" --first=Demo --last=User --password >/dev/null
  # A password set by an admin is "expired" on purpose. The user changes it once and it becomes normal:
  printf '%s\n%s\n%s\n' "Temp-$UPW" "$UPW" "$UPW" | KRB5CCNAME=FILE:/tmp/fipsdemo/krb5cc_user kinit "$U" >/dev/null
  echo "created user $U"
fi
ipa group-show fipsdemo-users >/dev/null 2>&1 || ipa group-add fipsdemo-users --desc="People allowed in the FIPS demo app" >/dev/null
ipa group-add-member fipsdemo-users --users="$U" >/dev/null 2>&1 || true
ipa host-show "$APPHOST" >/dev/null 2>&1 || ipa host-add "$APPHOST" --force >/dev/null
ipa service-show "HTTP/$APPHOST" >/dev/null 2>&1 || ipa service-add "HTTP/$APPHOST" --force >/dev/null
ipa host-show "$CLIENTHOST" >/dev/null 2>&1 || ipa host-add "$CLIENTHOST" --force >/dev/null
echo "FreeIPA demo entries are in place"
IPA
}
# First keytab of the app. ipa-getkeytab makes NEW keys every time (old keytabs stop working),
# so the scripts call this exactly once and afterwards only copy/filter the file.
ipa_new_service_keytab() { # OUTFILE [ENCTYPES]
  local out="$1" enctypes="${2:-}"
  ipa_sh -e "SPN=$SPN" -e "IPAHOST=$IPA_HOSTNAME" -e "ENCTYPES=$enctypes" <<'IPA'
rm -f /tmp/fipsdemo/new.keytab
if [ -n "$ENCTYPES" ]; then ipa-getkeytab -s "$IPAHOST" -p "$SPN" -k /tmp/fipsdemo/new.keytab -e "$ENCTYPES" >/dev/null
else ipa-getkeytab -s "$IPAHOST" -p "$SPN" -k /tmp/fipsdemo/new.keytab >/dev/null; fi
klist -kte /tmp/fipsdemo/new.keytab
IPA
  ipa_get new.keytab "$out"; chmod 600 "$out"
}
ipa_filter_keytab() { # IN OUT : copy that keeps only the SHA-2 keys (uses ktutil inside the FreeIPA container)
  ipa_put "$1" filter-in.keytab
  docker exec -i "$IPA_CONTAINER" bash -s -- /tmp/fipsdemo/filter-in.keytab /tmp/fipsdemo/filter-out.keytab \
    < "$ROOT_DIR/scripts/helpers/filter-keytab-sha2.sh"
  ipa_get filter-out.keytab "$2"; chmod 600 "$2"
}
# True when the KDC holds a SHA-2 key (aes256-cts-hmac-sha384-192) for that account.
ipa_principal_has_sha2() {
  docker exec "$IPA_CONTAINER" kadmin.local -q "getprinc $1" 2>/dev/null | grep -q 'aes256-cts-hmac-sha384-192'
}
# ipa_issue_cert PRINCIPAL COMMON_NAME RSA_BITS FILE_PREFIX  -> FILE_PREFIX.key and FILE_PREFIX.crt
# The private key is made here on your computer; only the request (CSR) travels to FreeIPA's CA.
ipa_issue_cert() {
  local principal="$1" cn="$2" bits="$3" prefix="$4"
  openssl req -new -newkey "rsa:$bits" -nodes -sha256 -keyout "$prefix.key" -out "$prefix.csr" \
    -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" 2>/dev/null
  chmod 600 "$prefix.key"
  ipa_put "$prefix.csr" req.csr
  ipa_sh -e "PRINCIPAL=$principal" <<'IPA'
rm -f /tmp/fipsdemo/out.crt
ipa cert-request /tmp/fipsdemo/req.csr --principal="$PRINCIPAL" --certificate-out=/tmp/fipsdemo/out.crt >/dev/null
IPA
  ipa_get out.crt "$prefix.crt"
  openssl x509 -in "$prefix.crt" -noout -subject -issuer | sed 's/^/    /'
}
ipa_backup_data() { # OUTFILE.tgz : stop FreeIPA for a moment, copy its whole data volume, start it again
  local out="$1"
  log "stopping FreeIPA for a consistent copy of its data"
  docker stop "$IPA_CONTAINER" >/dev/null
  docker run --rm --entrypoint /bin/tar -v "$IPA_VOLUME:/data:ro" -v "$(dirname "$out"):/backup" "$IPA_IMAGE" \
    czf "/backup/$(basename "$out")" -C /data . || { docker start "$IPA_CONTAINER" >/dev/null; return 1; }
  docker start "$IPA_CONTAINER" >/dev/null
  ipa_wait_ready
}
ipa_restore_data() { # INFILE.tgz : fill a fresh volume from a backup (the container must not exist yet)
  local in="$1"
  ipa_exists && die "container $IPA_CONTAINER exists already. Run scripts/90-destroy.sh --all first."
  docker volume create "$IPA_VOLUME" >/dev/null
  docker run --rm --entrypoint /bin/tar -v "$IPA_VOLUME:/data" -v "$(dirname "$in"):/backup:ro" "$IPA_IMAGE" \
    xzf "/backup/$(basename "$in")" -C /data
}
