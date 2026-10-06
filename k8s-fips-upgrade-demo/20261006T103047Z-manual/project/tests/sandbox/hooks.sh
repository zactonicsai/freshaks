#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
#  TEST STAND-INS, loaded through FIPSDEMO_TEST_HOOKS (see lib/common.sh).
#  They replace ONLY the functions that need Docker, kind, istiod or FreeIPA, for a test
#  box that has none of them (a plain k3s node + a local MIT Kerberos KDC + a local test CA).
#  Everything else - kubectl logic, save/restore/rollback, the app, the tests - runs for real.
# ============================================================================
SBX="${SBX_DIR:?set SBX_DIR}"
export KRB5_KDC_PROFILE="$SBX/kdc/kdc.conf" KRB5_CONFIG="$SBX/kdc/krb5.conf"
PATH="$PATH:/usr/sbin:/sbin"

node_kernel_fips() { if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)" = 1 ]; then echo 1; else echo 0; fi; }
build_and_load_image() {
  local image; image="$(image_of_profile "$1")"
  if [ "${SBX_FAIL_AT:-}" = build ]; then err "(sandbox) pretend the image build failed"; return 1; fi
  if [ "${SBX_SKIP_IMAGE_CHECK:-}" = 1 ]; then warn "(sandbox) not checking that $image exists"; return 0; fi
  ctr -n k8s.io images ls -q | grep -q "/$image\$" || die "(sandbox) image $image was not imported into containerd"
  ok "(sandbox) image $image is already in the node's containerd"
}
save_images() { echo "sandbox placeholder" > "$1"; }
load_images() { :; }
mesh_install() {
  if [ "${SBX_FAIL_AT:-}" = mesh ] && [ -n "$1" ]; then err "(sandbox) pretend istiod did not come up with the policy"; return 1; fi
  k create namespace "$ISTIO_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ISTIO_NS" create configmap sandbox-mesh "--from-literal=policy=$1" --dry-run=client -o yaml | k apply -f - >/dev/null
  log "(sandbox) recorded mesh policy '${1:-none}'. There is no real istiod on this box."
}
mesh_policy_now() { k -n "$ISTIO_NS" get configmap sandbox-mesh -o jsonpath='{.data.policy}' 2>/dev/null || true; }
gateway_install() { k create namespace "$INGRESS_NS" --dry-run=client -o yaml | k apply -f - >/dev/null; k label namespace "$INGRESS_NS" "$PART_OF_LABEL" --overwrite >/dev/null; log "(sandbox) no gateway pod on this box"; }
gateway_restart() { log "(sandbox) gateway restart skipped"; }
gateway_policy_now() { mesh_policy_now; }

ipa_ip() { echo "${SBX_NODE_IP:?}"; }
ipa_exists() { return 0; }
ipa_start() { :; }
ipa_is_ready() { return 0; }
ipa_wait_ready() { ok "(sandbox) a local MIT Kerberos KDC stands in for FreeIPA"; }
ipa_logs() { tail -n 200 "$SBX/kdc/kdc.log" > "$1" 2>&1; }
ipa_ca_cert() { cp "$SBX/ca/ca.crt" "$1"; }
ipa_bootstrap() {
  kadmin.local -q "getprinc $DEMO_USER" 2>/dev/null | grep -q '^Principal:' || kadmin.local -q "addprinc -pw $DEMO_USER_PASSWORD $DEMO_USER" >/dev/null
  kadmin.local -q "getprinc $SPN" 2>/dev/null | grep -q '^Principal:' || kadmin.local -q "addprinc -randkey $SPN" >/dev/null
  echo "(sandbox) KDC entries are in place"
}
ipa_new_service_keytab() {
  local out="$1" enctypes="${2:-}"; rm -f "$out"
  if [ -n "$enctypes" ]; then kadmin.local -q "ktadd -k $out -e aes256-sha2:normal,aes128-sha2:normal $SPN" >/dev/null
  else kadmin.local -q "ktadd -k $out $SPN" >/dev/null; fi
  chmod 600 "$out"; klist -kte "$out"
}
ipa_filter_keytab() { "$ROOT_DIR/scripts/helpers/filter-keytab-sha2.sh" "$1" "$2"; }
ipa_principal_has_sha2() { kadmin.local -q "getprinc $1" 2>/dev/null | grep -q 'aes256-cts-hmac-sha384-192'; }
ipa_issue_cert() {
  local cn="$2" bits="$3" prefix="$4"
  openssl req -new -newkey "rsa:$bits" -nodes -sha256 -keyout "$prefix.key" -out "$prefix.csr" \
    -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" 2>/dev/null
  chmod 600 "$prefix.key"
  openssl x509 -req -in "$prefix.csr" -CA "$SBX/ca/ca.crt" -CAkey "$SBX/ca/ca.key" -CAcreateserial -days 30 -sha256 \
    -copy_extensions copy -out "$prefix.crt" 2>/dev/null
  openssl x509 -in "$prefix.crt" -noout -subject -issuer | sed 's/^/    /'
}
ipa_backup_data() { tar czf "$1" -C "$SBX/kdc" .; ok "(sandbox) KDC database saved"; }
ipa_restore_data() { :; }
