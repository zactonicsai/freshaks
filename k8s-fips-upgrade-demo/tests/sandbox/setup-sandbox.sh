#!/usr/bin/env bash
# Prepares a Docker-less test box: local KDC, test CA, Istio CRDs and two hand-built app images in k3s.
# Needs root, k3s running, krb5-kdc, a JRE tarball and an AlmaLinux 9 root filesystem (see TEST-REPORT.md).
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SBX="${SBX_DIR:?}"; PATH="$PATH:/usr/sbin:/sbin"
ALMA_DEFAULT="${ALMA_DEFAULT:?root fs with DEFAULT policy}"; ALMA_FIPS="${ALMA_FIPS:?root fs after update-crypto-policies --set FIPS}"; JRE_DIR="${JRE_DIR:?}"
ISTIO_MANIFEST="${ISTIO_MANIFEST:?output of istioctl manifest generate}"
mkdir -p "$SBX"/{kdc,ca,img}
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
echo "node ip: $NODE_IP"

if [ ! -f "$SBX/kdc/principal" ]; then
  cat > "$SBX/kdc/kdc.conf" <<KDC
[kdcdefaults]
  kdc_listen = 127.0.0.1:18099
  kdc_tcp_listen = 0.0.0.0:88
[realms]
  FIPSDEMO.TEST = {
    database_name = $SBX/kdc/principal
    key_stash_file = $SBX/kdc/stash
    acl_file = $SBX/kdc/kadm5.acl
    master_key_type = aes256-sha2
    supported_enctypes = aes256-sha2:normal aes128-sha2:normal aes256-cts:normal aes128-cts:normal
    default_principal_flags = +preauth
  }
[logging]
  kdc = FILE:$SBX/kdc/kdc.log
KDC
  printf '[libdefaults]\n  default_realm = FIPSDEMO.TEST\n  dns_lookup_kdc = false\n[realms]\n  FIPSDEMO.TEST = {\n    kdc = 127.0.0.1:88\n  }\n' > "$SBX/kdc/krb5.conf"
  KRB5_KDC_PROFILE="$SBX/kdc/kdc.conf" KRB5_CONFIG="$SBX/kdc/krb5.conf" kdb5_util create -s -r FIPSDEMO.TEST -P master-secret >/dev/null 2>&1
fi
if ! pgrep -x krb5kdc >/dev/null; then KRB5_KDC_PROFILE="$SBX/kdc/kdc.conf" KRB5_CONFIG="$SBX/kdc/krb5.conf" nohup krb5kdc -n >"$SBX/kdc/kdc.out" 2>&1 & sleep 1; fi
pgrep -x krb5kdc >/dev/null && echo "KDC running on TCP 88"

if [ ! -f "$SBX/ca/ca.crt" ]; then
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 30 -keyout "$SBX/ca/ca.key" -out "$SBX/ca/ca.crt" -subj "/O=FIPSDEMO.TEST/CN=Sandbox Test CA" 2>/dev/null
fi

echo "Istio CRDs:"; python3 - "$ISTIO_MANIFEST" "$SBX/istio-crds.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get('kind') == 'CustomResourceDefinition']
yaml.safe_dump_all(docs, open(sys.argv[2], 'w'))
print(len(docs), "CRDs")
PY
kubectl apply --server-side -f "$SBX/istio-crds.yaml" >/dev/null && echo "applied"

if ! ctr -n k8s.io images ls -q | grep -q 'fipsdemo-app:2.0-fips'; then
  S="$SBX/img"; rm -rf "$S"/*; mkdir -p "$S"/{java/opt/java,app/opt/app,fips/etc,classes}
  cp -a "$JRE_DIR/." "$S/java/opt/java/"
  javac -d "$S/app/opt/app/classes" "$ROOT"/app/src/demo/*.java
  cp -a "$ROOT/app/web" "$S/app/opt/app/web"; cp "$ROOT/app/run.sh" "$S/app/opt/app/run.sh"; chmod 0555 "$S/app/opt/app/run.sh"
  cp -a "$ALMA_FIPS/etc/crypto-policies" "$S/fips/etc/"
  tar -C "$ALMA_DEFAULT" -cf "$S/base.tar" .
  tar -C "$S/java" -cf "$S/java.tar" opt; tar -C "$S/app" -cf "$S/app.tar" opt; tar -C "$S/fips" -cf "$S/fips.tar" etc
  python3 - "$S" <<'PY'
import hashlib, json, sys, os
S = sys.argv[1]
def digest(name):
    h = hashlib.sha256()
    with open(os.path.join(S, name), 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return 'sha256:' + h.hexdigest()
d = {n: digest(n) for n in ('base.tar', 'java.tar', 'app.tar', 'fips.tar')}
def config(name, layers, profile, version):
    cfg = {"architecture": "amd64", "os": "linux",
           "config": {"User": "185", "Entrypoint": ["/opt/app/run.sh"], "ExposedPorts": {"8080/tcp": {}},
                      "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "JAVA_HOME=/opt/java",
                              "APP_CRYPTO_PROFILE=" + profile, "APP_VERSION=" + version]},
           "rootfs": {"type": "layers", "diff_ids": [d[l] for l in layers]}}
    json.dump(cfg, open(os.path.join(S, name), 'w'))
config('blue.json', ['base.tar', 'java.tar', 'app.tar'], 'legacy', '1.0-nonfips')
config('green.json', ['base.tar', 'java.tar', 'fips.tar', 'app.tar'], 'fips', '2.0-fips')
json.dump([{"Config": "blue.json", "RepoTags": ["docker.io/library/fipsdemo-app:1.0-nonfips"], "Layers": ["base.tar", "java.tar", "app.tar"]},
           {"Config": "green.json", "RepoTags": ["docker.io/library/fipsdemo-app:2.0-fips"], "Layers": ["base.tar", "java.tar", "fips.tar", "app.tar"]}],
          open(os.path.join(S, 'manifest.json'), 'w'))
PY
  tar -C "$S" -cf "$SBX/fipsdemo-images.tar" manifest.json blue.json green.json base.tar java.tar app.tar fips.tar
  ctr -n k8s.io images import "$SBX/fipsdemo-images.tar" | tail -2
  rm -rf "$S" "$SBX/fipsdemo-images.tar"
fi
ctr -n k8s.io images ls -q | grep fipsdemo
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
kubectl label node "$NODE" sandbox/blue=yes sandbox/green=yes --overwrite >/dev/null
cat > "$SBX/env.sh" <<ENV
export SBX_DIR="$SBX" SBX_NODE_IP="$NODE_IP" FIPSDEMO_TEST_HOOKS="$ROOT/tests/sandbox/hooks.sh"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml KUBE_CONTEXT=default TEST_MODE=direct ASSUME_YES=1
export BLUE_NODE_SELECTOR="sandbox/blue=yes" GREEN_NODE_SELECTOR="sandbox/green=yes" APP_REPLICAS=1 ROLLOUT_TIMEOUT=240s
ENV
echo "sandbox ready: source $SBX/env.sh"
