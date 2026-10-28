#!/usr/bin/env bash
# kc-check.sh — Keycloak + Istio health / hostname / routing checks (works on kind and cloud).
#
# Usage:
#   ./kc-check.sh                              # all sections
#   ./kc-check.sh pods|probes|health|hostname|istio|db|all
#
# Env (defaults):
#   NAMESPACE=keycloak  RELEASE=keycloak  GATEWAY_NS=istio-gateway  GATEWAY_NAME=public-ingressgateway
#   PUBLIC_URL=http://localhost:8080       # what users type in the browser (https://keycloak.example.com in the cloud)
#   CURL_IMAGE=curlimages/curl:8.10.1      # ephemeral pod used for in-cluster curls
#
# Read-only except for ephemeral `kubectl run --rm` curl pods.

set -uo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
RELEASE="${RELEASE:-keycloak}"
GATEWAY_NS="${GATEWAY_NS:-istio-gateway}"
GATEWAY_NAME="${GATEWAY_NAME:-public-ingressgateway}"
PUBLIC_URL="${PUBLIC_URL:-http://localhost:8080}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"
SECTION="${1:-all}"

B='\033[1m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;36m'; N='\033[0m'
hdr()  { printf "\n${C}━━━ %s ━━━${N}\n" "$*"; }
ok()   { printf "${G}  ✔ %s${N}\n" "$*"; }
warn() { printf "${Y}  ! %s${N}\n" "$*"; }
bad()  { printf "${R}  ✗ %s${N}\n" "$*"; FAILS=$((FAILS+1)); }
show() { printf "${B}  \$ %s${N}\n" "$*"; "$@" 2>&1 | sed 's/^/    /'; }
FAILS=0
HAVE_ISTIOCTL=0; command -v istioctl >/dev/null 2>&1 && HAVE_ISTIOCTL=1

POD="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=keycloakx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
SVC="$(kubectl -n "${NAMESPACE}" get svc -l app.kubernetes.io/name=keycloakx -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v headless | head -n1)"
SVC="${SVC:-${RELEASE}-keycloak-http}"
PODIP="$(kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.status.podIP}' 2>/dev/null)"
HAS_SIDECAR=0
[[ -n "${POD}" ]] && kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -q istio-proxy && HAS_SIDECAR=1
GWPOD="$(kubectl -n "${GATEWAY_NS}" get pod -l "istio=${GATEWAY_NAME#istio-}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
HOST_HDR="$(sed -E 's#^https?://##; s#/.*$##' <<<"${PUBLIC_URL}")"
PUB_SCHEME="${PUBLIC_URL%%://*}"

# in-cluster curl via an ephemeral pod; prints "<code> <body>"
incurl() {  # incurl <url> [extra curl args...]
  local url="$1"; shift
  kubectl -n "${NAMESPACE}" run "kc-check-$$-${RANDOM}" --rm -i --restart=Never --quiet \
    --image="${CURL_IMAGE}" --command -- \
    sh -c "curl -s -m 8 -w ' [%{http_code}]' $* '${url}' 2>&1 | tr -d '\n' | cut -c1-400; echo" 2>/dev/null
}

want() { [[ "${SECTION}" == "all" || "${SECTION}" == "$1" ]]; }

printf "${B}Keycloak check  ns=%s pod=%s svc=%s sidecar=%s gateway=%s/%s public=%s${N}\n" \
  "${NAMESPACE}" "${POD:-<none>}" "${SVC}" "${HAS_SIDECAR}" "${GATEWAY_NS}" "${GATEWAY_NAME}" "${PUBLIC_URL}"
[[ -n "${POD}" ]] || { bad "no pod with label app.kubernetes.io/name=keycloakx in ${NAMESPACE}"; exit 1; }

# ---------------------------------------------------------------------------
if want pods; then
hdr "PODS / WORKLOADS"
show kubectl -n "${NAMESPACE}" get pods -o wide
show kubectl -n "${NAMESPACE}" get sts,svc,endpoints,pvc
kubectl -n "${NAMESPACE}" get pod "${POD}" -o json > /tmp/kc-check-pod.json
python3 - /tmp/kc-check-pod.json <<'PY'
import sys, json
p = json.load(open(sys.argv[1])); st = p["status"]
for kind in ("initContainerStatuses", "containerStatuses"):
    for c in st.get(kind, []):
        s = c.get("state", {}); k = next(iter(s)); d = s[k] or {}
        last = c.get("lastState", {})
        lk = next(iter(last), None); ld = (last.get(lk) or {}) if lk else {}
        reason = ("/" + d["reason"]) if d.get("reason") else ""
        lastinfo = f'  last={lk} exit={ld.get("exitCode")} {ld.get("reason","")}' if lk else ""
        print(f'  [{kind[:4]}] {c["name"]:<14} ready={c.get("ready")!s:<5} restarts={c.get("restartCount")!s:<3} state={k}{reason}{lastinfo}')
PY
READY="$(kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
[[ "${READY}" == "True" ]] && ok "${POD} is Ready" || bad "${POD} is NOT Ready"
EP="$(kubectl -n "${NAMESPACE}" get endpoints "${SVC}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
[[ -n "${EP}" ]] && ok "Service ${SVC} endpoints: ${EP}" || bad "Service ${SVC} has NO endpoints (readiness failing or selector mismatch)"
fi

# ---------------------------------------------------------------------------
if want probes; then
hdr "PROBES (as configured on the running pod)"
kubectl -n "${NAMESPACE}" get pod "${POD}" -o json > /tmp/kc-check-pod.json
python3 - /tmp/kc-check-pod.json <<'PY'
import sys, json
p = json.load(open(sys.argv[1]))
ports = {}
for c in p["spec"]["containers"]:
    for pt in c.get("ports", []): ports[pt.get("name")] = pt["containerPort"]
for c in p["spec"]["containers"]:
    if c["name"] != "keycloak": continue
    for name in ("startupProbe", "readinessProbe", "livenessProbe"):
        pr = c.get(name)
        if not pr: print(f"  {name:<15} <none>"); continue
        hg = pr.get("httpGet") or {}
        port = hg.get("port"); port = f"{port}({ports.get(port)})" if isinstance(port, str) else port
        print(f'  {name:<15} {hg.get("scheme","HTTP")}://:{port}{hg.get("path")}  delay={pr.get("initialDelaySeconds",0)}s period={pr.get("periodSeconds",10)}s timeout={pr.get("timeoutSeconds",1)}s failures={pr.get("failureThreshold",3)}')
        if str(hg.get("port")) == "15020": print("                  (rewritten by Istio -> pilot-agent; app port taken from the original probe)")
PY
echo "  env that controls the management interface:"
kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{range .spec.containers[?(@.name=="keycloak")].env[*]}{"    "}{.name}={.value}{"\n"}{end}' \
  | grep -E 'KC_HEALTH|KC_METRICS|KC_HTTP_MANAGEMENT|KC_HTTP_RELATIVE|KC_HTTP_ENABLED|KC_HTTPS' || echo "    (none set inline)"
echo "  recent probe failures:"
kubectl -n "${NAMESPACE}" get events --field-selector "involvedObject.name=${POD},reason=Unhealthy" --sort-by=.lastTimestamp 2>/dev/null \
  | tail -n 6 | sed 's/^/    /'
if [[ "${HAS_SIDECAR}" == "1" ]]; then
  echo "  sidecar present — port exclusions / probe rewrite:"
  kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.metadata.annotations}' | tr ',' '\n' | grep -E 'excludeInboundPorts|rewriteAppHTTPProbers|includeInboundPorts' | sed 's/^/    /' || echo "    (no exclusions; relying on probe rewrite)"
fi
fi

# ---------------------------------------------------------------------------
if want health; then
hdr "HEALTH ENDPOINTS (curl from an in-cluster pod -> ${PODIP})"
for p in 9000/health/started 9000/health/ready 9000/health/live 9000/health 8080/realms/master; do
  out="$(incurl "http://${PODIP}:${p}")"
  code="$(grep -oE '\[[0-9]{3}\]$' <<<"${out}" | tr -d '[]')"
  printf "  %-28s %s\n" "${p}" "${out}"
  case "${p}:${code}" in
    9000/health/ready:200) ok "ready" ;;
    9000/health/ready:503) bad "NOT ready — see checks[] above (database / cluster / graceful shutdown)" ;;
    9000/health/started:200) ok "started" ;;
    9000/health/started:503|9000/health/started:000|9000/health/started:) bad "not started (still booting, or :9000 not listening — check scheme/path/port)" ;;
    8080/realms/master:200) ok "app port serves /realms/master" ;;
    8080/realms/master:*) warn "app port answered ${code:-nothing}" ;;
  esac
done
echo "  via Service ${SVC}:"
printf "  %-28s %s\n" "svc /realms/master" "$(incurl "http://${SVC}.${NAMESPACE}.svc.cluster.local/realms/master" -o /dev/null)"
echo "  boot markers in the log:"
kubectl -n "${NAMESPACE}" logs "${POD}" -c keycloak 2>/dev/null | grep -E "started in|Listening on|Management interface|ERROR" | tail -n 6 | cut -c1-200 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
if want db; then
hdr "DATABASE"
DBHOST="$(kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.spec.containers[?(@.name=="keycloak")].env[?(@.name=="KC_DB_URL_HOST")].value}')"
DBPORT="$(kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.spec.containers[?(@.name=="keycloak")].env[?(@.name=="KC_DB_URL_PORT")].value}')"
echo "  KC_DB_URL_HOST=${DBHOST:-<unset>} KC_DB_URL_PORT=${DBPORT:-<unset>}"
if kubectl -n "${NAMESPACE}" get svc "${DBHOST%%.*}" >/dev/null 2>&1; then ok "Service ${DBHOST%%.*} exists"; else bad "no Service named ${DBHOST%%.*} in ${NAMESPACE} (external DB? then check DNS below)"; fi
printf "  tcp check: %s\n" "$(kubectl -n "${NAMESPACE}" run "kc-check-nc-$$" --rm -i --restart=Never --quiet --image=busybox:1.37 --command -- nc -zv -w 3 "${DBHOST}" "${DBPORT:-5432}" 2>&1 | tail -n1)"
PGPOD="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -n "${PGPOD}" ]]; then
  show kubectl -n "${NAMESPACE}" exec "${PGPOD}" -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -tAc "select '"'"'schema version '"'"'||version from migration_model order by update_time desc limit 1; select '"'"'connections '"'"'||count(*)||'"'"'/'"'"'||current_setting('"'"'max_connections'"'"') from pg_stat_activity;"'
fi
fi

# ---------------------------------------------------------------------------
if want hostname; then
hdr "HOSTNAME"
kubectl -n "${NAMESPACE}" get secret "${RELEASE}-keycloak-env" -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}' 2>/dev/null \
  | grep -E '^KC_HOSTNAME|^KC_PROXY' | sed 's/^/  secret: /'
kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{range .spec.containers[?(@.name=="keycloak")].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -E '^KC_HOSTNAME|^KC_PROXY' | sed 's/^/  env:    /'
KCH="$(kubectl -n "${NAMESPACE}" get secret "${RELEASE}-keycloak-env" -o go-template='{{index .data "KC_HOSTNAME" | base64decode}}' 2>/dev/null)"
STRICT="$(kubectl -n "${NAMESPACE}" get secret "${RELEASE}-keycloak-env" -o go-template='{{index .data "KC_HOSTNAME_STRICT" | base64decode}}' 2>/dev/null)"
BCD="$(kubectl -n "${NAMESPACE}" get secret "${RELEASE}-keycloak-env" -o go-template='{{index .data "KC_HOSTNAME_BACKCHANNEL_DYNAMIC" | base64decode}}' 2>/dev/null)"
if [[ -z "${KCH}" || "${KCH}" == "<no value>" ]]; then
  [[ "${STRICT}" == "false" ]] && warn "KC_HOSTNAME unset: URLs derived from each request (ok for dev only)" || bad "KC_HOSTNAME unset and KC_HOSTNAME_STRICT!=false -> Keycloak refuses to start in production mode"
else
  [[ "${KCH}" == *"://"* ]] && ok "KC_HOSTNAME is a full URL (${KCH})" || warn "KC_HOSTNAME is a bare host (${KCH}); scheme/port come from X-Forwarded-* — fine only if the proxy sets them"
  [[ "${KCH%/}" == "${PUBLIC_URL%/}" ]] && ok "KC_HOSTNAME matches PUBLIC_URL" || warn "KC_HOSTNAME (${KCH}) != PUBLIC_URL (${PUBLIC_URL}) — redirects/issuer will use KC_HOSTNAME"
  [[ "${BCD}" == "true" && "${KCH}" != *"://"* ]] && bad "KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true requires KC_HOSTNAME to be a full URL"
fi
echo "  issuer as seen from the public URL:"
curl -sk -m 8 "${PUBLIC_URL}/realms/master/.well-known/openid-configuration" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("    (no JSON — public URL unreachable or not Keycloak)"); sys.exit(0)
for k in ("issuer","authorization_endpoint","token_endpoint"): print(f"    {k}: {d.get(k)}")
'
ISS="$(curl -sk -m 8 "${PUBLIC_URL}/realms/master/.well-known/openid-configuration" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["issuer"])' 2>/dev/null)"
if [[ -n "${ISS}" ]]; then
  [[ "${ISS}" == "${PUBLIC_URL%/}/realms/master" ]] && ok "issuer == PUBLIC_URL/realms/master" || bad "issuer (${ISS}) != ${PUBLIC_URL%/}/realms/master -> hostname/proxy-headers misconfigured"
fi
echo "  issuer as seen in-cluster (backchannel):"
printf "    %s\n" "$(incurl "http://${SVC}.${NAMESPACE}.svc.cluster.local/realms/master/.well-known/openid-configuration" | grep -oE '"issuer":"[^"]*"|"token_endpoint":"[^"]*"' | tr '\n' ' ')"
echo "  hostname-debug page (needs KC_HOSTNAME_DEBUG=true):"
HD="$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/realms/master/hostname-debug" 2>/dev/null)"
[[ "${HD}" == "200" ]] && echo "    open ${PUBLIC_URL}/realms/master/hostname-debug" || echo "    ${HD:-unreachable} — add  - {name: KC_HOSTNAME_DEBUG, value: \"true\"}  to upstream.extraEnv to enable (dev only)"
echo "  hostname-related log lines:"
kubectl -n "${NAMESPACE}" logs "${POD}" -c keycloak 2>/dev/null | grep -iE "hostname|proxy-headers|Possible solutions" | tail -n 5 | cut -c1-200 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
if want istio; then
hdr "ISTIO ROUTING"
if [[ "${HAVE_ISTIOCTL}" == "1" ]]; then
  show istioctl analyze -n "${NAMESPACE}"
  show istioctl analyze -n "${GATEWAY_NS}"
else
  warn "istioctl not installed — skipping analyze / proxy-config (brew install istioctl)"
fi
echo "  Gateway:"
kubectl -n "${GATEWAY_NS}" get gateway "${GATEWAY_NAME}" -o jsonpath='{range .spec.servers[*]}{"    port="}{.port.number}{"/"}{.port.protocol}{" hosts="}{.hosts}{" tls="}{.tls.mode}{" cred="}{.tls.credentialName}{"\n"}{end}' 2>/dev/null || bad "Gateway ${GATEWAY_NS}/${GATEWAY_NAME} missing"
SEL="$(kubectl -n "${GATEWAY_NS}" get gateway "${GATEWAY_NAME}" -o jsonpath='{.spec.selector}' 2>/dev/null)"
[[ -n "${GWPOD}" ]] && ok "Gateway selector ${SEL} matches pod ${GWPOD}" || bad "Gateway selector ${SEL} matches no pods in ${GATEWAY_NS}"
echo "  VirtualServices in ${NAMESPACE}:"
kubectl -n "${NAMESPACE}" get virtualservice -o jsonpath='{range .items[*]}{"    "}{.metadata.name}{": hosts="}{.spec.hosts}{" gateways="}{.spec.gateways}{" -> "}{range .spec.http[*].route[*]}{.destination.host}{":"}{.destination.port.number}{" "}{end}{range .spec.tls[*].route[*]}{"(tls) "}{.destination.host}{":"}{.destination.port.number}{" "}{end}{"\n"}{end}' 2>/dev/null
VSCOUNT="$(kubectl -n "${NAMESPACE}" get virtualservice --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[[ "${VSCOUNT}" -gt 0 ]] || bad "no VirtualService in ${NAMESPACE}"
kubectl -n "${NAMESPACE}" get virtualservice -o jsonpath='{range .items[*]}{range .spec.hosts[*]}{.}{"\n"}{end}{end}' 2>/dev/null | while read -r h; do
  [[ "${h}" == "*" || "${h}" == *.* ]] || bad "VirtualService host '${h}' has no dot -> Istio expands it to ${h}.${NAMESPACE}.svc.cluster.local (use the FQDN or \"*\")"
done
kubectl -n "${NAMESPACE}" get virtualservice -o jsonpath='{range .items[*]}{range .spec.http[*].route[*]}{.destination.host}{"\n"}{end}{end}' 2>/dev/null | while read -r d; do
  [[ -z "${d}" ]] && continue
  kubectl -n "${NAMESPACE}" get svc "${d%%.*}" >/dev/null 2>&1 && ok "destination ${d%%.*} is a Service in ${NAMESPACE}" || bad "destination ${d} is not a Service in ${NAMESPACE}"
done
echo "  PeerAuthentication / AuthorizationPolicy / DestinationRule:"
kubectl -n "${NAMESPACE}" get peerauthentication,authorizationpolicy,destinationrule 2>/dev/null | sed 's/^/    /' || true
kubectl get peerauthentication -n istio-system -o jsonpath='{range .items[*]}{"    mesh-wide: "}{.metadata.name}{" mtls="}{.spec.mtls.mode}{"\n"}{end}' 2>/dev/null
if [[ -n "${GWPOD}" ]]; then
  echo "  gateway Envoy (${GWPOD}):"
  if [[ "${HAVE_ISTIOCTL}" == "1" ]]; then
    istioctl -n "${GATEWAY_NS}" proxy-status 2>/dev/null | grep -E "NAME|${GWPOD}" | sed 's/^/    /'
    istioctl -n "${GATEWAY_NS}" proxy-config listeners "${GWPOD}" 2>/dev/null | sed 's/^/    /'
    istioctl -n "${GATEWAY_NS}" proxy-config endpoints "${GWPOD}" 2>/dev/null | grep -E "ENDPOINT|${SVC}" | sed 's/^/    /'
    istioctl -n "${GATEWAY_NS}" proxy-config endpoints "${GWPOD}" 2>/dev/null | grep -q "${SVC}.*HEALTHY" && ok "gateway sees HEALTHY endpoint(s) for ${SVC}" || bad "gateway has no HEALTHY endpoint for ${SVC} (readiness) or no route to it (VirtualService)"
  fi
  echo "  route test from inside the gateway pod (Host: ${HOST_HDR}):"
  GC="$(kubectl -n "${GATEWAY_NS}" exec "${GWPOD}" -- curl -s -m 8 -o /dev/null -w '%{http_code}' -H "Host: ${HOST_HDR}" http://localhost:8080/realms/master 2>/dev/null)"
  [[ "${GC}" == "200" ]] && ok "gateway :8080 + Host header -> 200" || bad "gateway :8080 + Host header -> ${GC:-no answer} (see response flags below)"
  echo "  last gateway access-log lines (flags: NR=no route UH=no healthy upstream UF=connect fail UAEX=authz denied):"
  kubectl -n "${GATEWAY_NS}" logs "${GWPOD}" -c istio-proxy --tail=200 2>/dev/null | grep -v -E 'health|/metrics' | tail -n 6 | cut -c1-220 | sed 's/^/    /'
fi
echo "  public URL:"
PC="$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "${PUBLIC_URL}/realms/master" 2>/dev/null)"
[[ "${PC}" == "200" ]] && ok "${PUBLIC_URL}/realms/master -> 200" || bad "${PUBLIC_URL}/realms/master -> ${PC:-unreachable}"
if [[ "${PUB_SCHEME}" == "https" ]]; then
  echo "  TLS at the edge:"
  echo | openssl s_client -connect "${HOST_HDR}:443" -servername "${HOST_HDR}" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null | sed 's/^/    /' || warn "could not read the certificate"
  LBSVC="$(kubectl -n "${GATEWAY_NS}" get svc "${GATEWAY_NAME}" -o jsonpath='{.spec.type} {.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  echo "    gateway service: ${LBSVC}"
fi
fi

# ---------------------------------------------------------------------------
printf "\n"
if [[ "${FAILS}" -eq 0 ]]; then printf "${G}All checks passed.${N}\n"; else printf "${R}%s check(s) failed — see ✗ lines above.${N}\n" "${FAILS}"; exit 1; fi
