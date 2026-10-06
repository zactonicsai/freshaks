#!/usr/bin/env bash
# tests/offline-tests.sh - every check that needs NO Docker and NO cluster.
# Missing tools are skipped, not failed.   usage: tests/offline-tests.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0; SKIP=0; OUT="$(mktemp)"; R="$(mktemp -d)"; trap 'rm -rf "$OUT" "$R"' EXIT
t() { local name="$1"; shift; if "$@" >"$OUT" 2>&1; then PASS=$((PASS + 1)); echo "  PASS  $name"; else FAIL=$((FAIL + 1)); echo "  FAIL  $name"; sed 's/^/        /' "$OUT" | head -15; fi; }
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $1"; }
have() { command -v "$1" >/dev/null 2>&1; }
ALL_SH=(lib/*.sh scripts/*.sh scripts/helpers/*.sh tests/*.sh tests/sandbox/*.sh)

echo "== 1. Shell syntax"
for f in "${ALL_SH[@]}"; do t "bash -n $f" bash -n "$f"; done

echo "== 2. shellcheck"
if have shellcheck; then
  t "shellcheck: no errors in ${#ALL_SH[@]} files" shellcheck -x -s bash -S error "${ALL_SH[@]}"
  echo "        (style notes at warning level: $(shellcheck -x -s bash -S warning -f gcc "${ALL_SH[@]}" 2>/dev/null | grep -c 'warning:' || true))"
else skip "shellcheck is not installed"; fi

echo "== 3. Java compiles without warnings"
if have javac; then t "javac -Xlint:all -Werror" javac -Xlint:all -Werror -d "$R/classes" app/src/demo/*.java; else skip "no JDK (javac)"; fi

echo "== 4. Templates render with no placeholder left over"
render_all() {
  ( # shellcheck disable=SC1091
    source lib/common.sh; trap - ERR EXIT
    render k8s/kind-cluster.yaml NODEPORT_HTTPS=30443 HOST_HTTPS_PORT=8443 BLUE_KEY=nodepool BLUE_VALUE=blue GREEN_KEY=nodepool GREEN_VALUE=green > "$R/kind.yaml"
    render k8s/istio/ingress-gateway.yaml INGRESS_NS=istio-ingress NODEPORT_HTTPS=30443 > "$R/gateway.yaml"
    render k8s/app/base.tmpl.yaml APP_NS=fipsdemo INGRESS_NS=istio-ingress IPA_IP=172.18.0.5 IPA_HOSTNAME=ipa.fipsdemo.test > "$R/base.yaml"
    render k8s/app/routing.tmpl.yaml APP_NS=fipsdemo INGRESS_NS=istio-ingress APP_HOSTNAME=app.fipsdemo.test LIVE_TRACK=blue TLS_SECRET=fipsdemo-tls-v1 > "$R/routing.yaml"
    for c in blue green; do
      track_settings "$c"
      render k8s/app/deployment.tmpl.yaml "COLOR=$c" APP_NS=fipsdemo "IMAGE=$T_IMAGE" "VERSION=${T_IMAGE##*:}" "PROFILE=$T_PROFILE" "KEYTAB_SECRET=$T_KEYTAB" \
        "SESSION_SECRET=$T_SESSION" "NODE_KEY=$(sel_key "$T_SELECTOR")" "NODE_VALUE=$(sel_val "$T_SELECTOR")" REPLICAS=2 IPA_IP=172.18.0.5 \
        IPA_HOSTNAME=ipa.fipsdemo.test REALM=FIPSDEMO.TEST SPN=HTTP/app.fipsdemo.test@FIPSDEMO.TEST "CHANGE_CAUSE=offline test" > "$R/deploy-$c.yaml"
    done
    for p in legacy fips; do render "k8s/app/krb5-$p.conf.tmpl" REALM=FIPSDEMO.TEST DOMAIN=fipsdemo.test KDC_ADDR=ipa.fipsdemo.test:88 > "$R/krb5-$p.conf"; done
  )
}
t "all templates render" render_all
if have python3 && python3 -c 'import yaml' 2>/dev/null; then
  t "rendered files are well-formed YAML" python3 -c 'import sys, yaml
for f in sys.argv[1:]:
    list(yaml.safe_load_all(open(f)))' "$R"/kind.yaml "$R"/gateway.yaml "$R"/base.yaml "$R"/routing.yaml "$R"/deploy-blue.yaml "$R"/deploy-green.yaml k8s/istio/istio-operator.yaml
else skip "python3 with PyYAML is not installed"; fi

echo "== 5. Istio's own checks (offline)"
if have istioctl; then
  t "istioctl validate" istioctl validate -f "$R/base.yaml" -f "$R/routing.yaml" -f "$R/deploy-blue.yaml" -f "$R/deploy-green.yaml" -f "$R/gateway.yaml"
  t "istioctl analyze --use-kube=false" istioctl analyze --use-kube=false "$R/base.yaml" "$R/routing.yaml" "$R/deploy-blue.yaml" "$R/deploy-green.yaml" "$R/gateway.yaml"
  fips_env() { istioctl manifest generate -f k8s/istio/istio-operator.yaml --set values.pilot.env.COMPLIANCE_POLICY=fips-140-3 | grep -A1 'name: COMPLIANCE_POLICY' | grep -q 'value: fips-140-3'; }
  t "install settings + FIPS switch put COMPLIANCE_POLICY=fips-140-3 on istiod" fips_env
else skip "istioctl is not installed"; fi

echo "== 6. The app against a throw-away Kerberos server"
if [ "$(id -u)" -ne 0 ]; then skip "app-kerberos-test.sh wants root (run: sudo tests/app-kerberos-test.sh)"
else
  tests/app-kerberos-test.sh > "$R/krb.log" 2>&1; rc=$?
  if [ "$rc" -eq 77 ]; then skip "Kerberos server tools are not installed ($(tail -1 "$R/krb.log"))"
  elif [ "$rc" -eq 0 ]; then PASS=$((PASS + 1)); echo "  PASS  app-kerberos-test.sh: $(tail -1 "$R/krb.log")"
  else FAIL=$((FAIL + 1)); echo "  FAIL  app-kerberos-test.sh"; grep -E 'FAIL|RESULT' "$R/krb.log" | head -10; fi
fi
echo; echo "OFFLINE RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
