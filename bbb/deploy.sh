#!/usr/bin/env bash
# deploy.sh — kind cluster in Docker + Istio ingress + Big Bang Keycloak, reachable at localhost.
#
# Uses public images (quay.io/keycloak/keycloak, docker.io/bitnamilegacy/postgresql,
# docker.io/istio/*), so no registry1.dso.mil login is needed.
#
# Usage:
#   ./deploy.sh              # create cluster, install Istio, deploy Keycloak, verify
#   ./deploy.sh --debug      # same, with bash xtrace + helm --debug
#   ./deploy.sh --verify     # only re-run the post-deploy checks
#   ./deploy.sh --diagnose   # dump pod status / events / logs for the keycloak namespace
#   ./deploy.sh --destroy    # delete the kind cluster
#
# Every step is checked; on any failure the script prints pod status, container
# states, recent events and container logs before exiting.
#
# Overridable env vars (defaults shown):
#   CLUSTER_NAME=bb-keycloak
#   NAMESPACE=keycloak
#   RELEASE=keycloak           # keep as "keycloak" unless you also change upstream.database.hostname
#   CHART_REPO=https://repo1.dso.mil/big-bang/product/packages/keycloak.git
#   CHART_REF=7.3.2-bb.2       # git tag/branch of the package repo ("main" for latest)
#   ISTIO_VERSION=             # empty = latest from the Istio Helm repo (e.g. 1.27.1)
#   ISTIO_NS=istio-system
#   GATEWAY_NS=istio-gateway
#   GATEWAY_NAME=public-ingressgateway
#   ISTIO_INJECT=false         # true = inject a sidecar into the keycloak pods too
#   PREPULL_IMAGES=true        # docker pull + kind load every image in the rendered chart
#   KC_ADMIN_USER=admin
#   KC_ADMIN_PASSWORD=password
#   VALUES_FILE=./values.yaml
#   HOST_HTTP_PORT=8080        # host port -> ingress gateway NodePort 30080
#   HOST_HTTPS_PORT=8443       # host port -> ingress gateway NodePort 30443
#   WAIT_TIMEOUT=600           # seconds to wait for each StatefulSet

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-bb-keycloak}"
NAMESPACE="${NAMESPACE:-keycloak}"
RELEASE="${RELEASE:-keycloak}"
CHART_REPO="${CHART_REPO:-https://repo1.dso.mil/big-bang/product/packages/keycloak.git}"
CHART_REF="${CHART_REF:-7.3.2-bb.2}"
ISTIO_VERSION="${ISTIO_VERSION:-}"
ISTIO_NS="${ISTIO_NS:-istio-system}"
GATEWAY_NS="${GATEWAY_NS:-istio-gateway}"
GATEWAY_NAME="${GATEWAY_NAME:-public-ingressgateway}"
ISTIO_INJECT="${ISTIO_INJECT:-false}"
PREPULL_IMAGES="${PREPULL_IMAGES:-true}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-password}"
HOST_HTTP_PORT="${HOST_HTTP_PORT:-8080}"
HOST_HTTPS_PORT="${HOST_HTTPS_PORT:-8443}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
DEBUG="${DEBUG:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${VALUES_FILE:-${SCRIPT_DIR}/values.yaml}"
WORK_DIR="${SCRIPT_DIR}/.work"
CHART_DIR="${WORK_DIR}/keycloak"
RENDERED="${WORK_DIR}/rendered.yaml"
KC_URL="http://localhost:${HOST_HTTP_PORT}"
HELM_DEBUG=()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
ts()   { date '+%H:%M:%S'; }
log()  { printf '\n\033[1;34m==> [%s] %s\033[0m\n' "$(ts)" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }
run()  { info "\$ $*"; "$@"; }

# ---------------------------------------------------------------------------
# Diagnostics — printed on any failure after the cluster exists
# ---------------------------------------------------------------------------
diagnose() {
  local ns="${1:-${NAMESPACE}}"
  printf '\n\033[1;35m==================== DIAGNOSTICS (%s) ====================\033[0m\n' "${ns}"
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || { warn "no kind context"; return; }

  echo; echo "--- helm releases"
  helm -n "${ns}" list -a 2>/dev/null || true

  echo; echo "--- workloads"
  kubectl -n "${ns}" get sts,deploy,svc,pvc,secret 2>/dev/null || true

  echo; echo "--- pods"
  kubectl -n "${ns}" get pods -o wide 2>/dev/null || true

  echo; echo "--- container states (init + main)"
  kubectl -n "${ns}" get pods -o json > "${WORK_DIR}/pods.json" 2>/dev/null || echo '{"items":[]}' > "${WORK_DIR}/pods.json"
  python3 - "${WORK_DIR}/pods.json" <<'PY' || true
import sys, json
for p in json.load(open(sys.argv[1])).get("items", []):
    m, st = p["metadata"], p.get("status", {})
    print(f'{m["name"]}: phase={st.get("phase")} reason={st.get("reason","")} {st.get("message","")}')
    for kind in ("initContainerStatuses", "containerStatuses"):
        for c in st.get(kind, []):
            s = c.get("state", {}); k = next(iter(s), "unknown"); d = s.get(k) or {}
            print(f'  [{kind[:4]}] {c["name"]:<22} ready={c.get("ready")} restarts={c.get("restartCount")} '
                  f'state={k} reason={d.get("reason","")} exit={d.get("exitCode","")} {d.get("message","")[:200]}')
            lt = c.get("lastState", {})
            if lt:
                k2 = next(iter(lt)); d2 = lt[k2] or {}
                print(f'         last={k2} reason={d2.get("reason","")} exit={d2.get("exitCode","")} {d2.get("message","")[:200]}')
PY

  echo; echo "--- events (newest last)"
  kubectl -n "${ns}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 40 || true

  echo; echo "--- logs of non-ready pods (last 80 lines, current + previous)"
  local pod c
  for pod in $(kubectl -n "${ns}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null); do
    if kubectl -n "${ns}" get pod "${pod}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
      continue
    fi
    for c in $(kubectl -n "${ns}" get pod "${pod}" -o jsonpath='{range .spec.initContainers[*]}{.name}{" "}{end}{range .spec.containers[*]}{.name}{" "}{end}' 2>/dev/null); do
      echo "----- ${pod} / ${c} (current)"
      kubectl -n "${ns}" logs "${pod}" -c "${c}" --tail=80 2>&1 | sed 's/^/      /' || true
      echo "----- ${pod} / ${c} (previous)"
      kubectl -n "${ns}" logs "${pod}" -c "${c}" --tail=80 --previous 2>&1 | sed 's/^/      /' || true
    done
  done
  printf '\033[1;35m===========================================================\033[0m\n'
}

on_error() {
  local code=$? line=$1
  printf '\n\033[1;31mStep failed (exit %s) at line %s\033[0m\n' "${code}" "${line}" >&2
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    diagnose "${NAMESPACE}"
  fi
  exit "${code}"
}

# ---------------------------------------------------------------------------
# Wait for a StatefulSet, printing container states each round; bail out early
# on CrashLoopBackOff / ImagePullBackOff / Error instead of waiting for a timeout.
# ---------------------------------------------------------------------------
wait_for_sts() {
  local ns="$1" sts="$2" timeout="${3:-${WAIT_TIMEOUT}}"
  local start now want ready states bad
  start=$(date +%s)
  log "Waiting for StatefulSet ${ns}/${sts} (timeout ${timeout}s)"
  while :; do
    if ! kubectl -n "${ns}" get sts "${sts}" >/dev/null 2>&1; then
      info "StatefulSet ${sts} not created yet…"
    else
      want="$(kubectl -n "${ns}" get sts "${sts}" -o jsonpath='{.spec.replicas}')"
      ready="$(kubectl -n "${ns}" get sts "${sts}" -o jsonpath='{.status.readyReplicas}')"
      ready="${ready:-0}"
      kubectl -n "${ns}" get pods -l "app.kubernetes.io/instance=${RELEASE}" -o json > "${WORK_DIR}/pods.json" 2>/dev/null || echo '{"items":[]}' > "${WORK_DIR}/pods.json"
      states="$(python3 - "${WORK_DIR}/pods.json" <<'PY' || true
import sys, json
for p in json.load(open(sys.argv[1])).get("items", []):
    st = p.get("status", {})
    parts = [f'{p["metadata"]["name"]}={st.get("phase")}']
    for kind in ("initContainerStatuses", "containerStatuses"):
        for c in st.get(kind, []):
            s = c.get("state", {}); k = next(iter(s), "?"); r = (s.get(k) or {}).get("reason", "")
            parts.append(f'{c["name"]}:{k}{("/" + r) if r else ""}:r{c.get("restartCount",0)}')
    print(" ".join(parts))
PY
)"
      info "ready ${ready}/${want}  ${states//$'\n'/ | }"
      if [[ "${ready}" == "${want}" && "${want}" != "0" ]]; then
        ok "${sts} ready (${ready}/${want})"; return 0
      fi
      bad="$(grep -oE 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError|CreateContainerError|RunContainerError|OOMKilled|Error' <<<"${states}" | sort -u | tr '\n' ' ')"
      if [[ -n "${bad}" ]]; then
        warn "pod(s) in a failing state: ${bad}"
        diagnose "${ns}"
        die "StatefulSet ${ns}/${sts} failed to start — see diagnostics above."
      fi
    fi
    now=$(date +%s)
    if (( now - start > timeout )); then
      diagnose "${ns}"
      die "Timed out after ${timeout}s waiting for ${ns}/${sts}."
    fi
    sleep 10
  done
}

# ---------------------------------------------------------------------------
# Verification (also used by --verify)
# ---------------------------------------------------------------------------
verify() {
  local failed=0
  log "Verifying deployment"
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

  if kubectl -n "${ISTIO_NS}" rollout status deploy/istiod --timeout=60s >/dev/null 2>&1; then
    ok "istiod is ready"
  else warn "istiod is not ready"; failed=1; fi

  if kubectl -n "${GATEWAY_NS}" rollout status "deploy/${GATEWAY_NAME}" --timeout=60s >/dev/null 2>&1; then
    ok "ingress gateway ${GATEWAY_NS}/${GATEWAY_NAME} is ready"
  else warn "ingress gateway is not ready"; failed=1; fi

  if kubectl -n "${GATEWAY_NS}" get gateway.networking.istio.io "${GATEWAY_NAME}" >/dev/null 2>&1; then
    ok "Gateway ${GATEWAY_NS}/${GATEWAY_NAME} exists"
  else warn "Gateway resource missing"; failed=1; fi

  if kubectl -n "${NAMESPACE}" get virtualservice keycloak >/dev/null 2>&1; then
    ok "VirtualService ${NAMESPACE}/keycloak exists"
  else warn "VirtualService missing"; failed=1; fi

  if kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/name=keycloakx --timeout=120s >/dev/null 2>&1; then
    ok "Keycloak pod(s) Ready"
  else warn "Keycloak pods not Ready"; failed=1; fi

  # In-cluster check: gateway pod -> keycloak service (isolates kind port mapping problems)
  local svc port
  svc="$(kubectl -n "${NAMESPACE}" get svc -l app.kubernetes.io/name=keycloakx -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v headless | head -n1 || true)"
  if [[ -n "${svc}" ]]; then
    port="$(kubectl -n "${NAMESPACE}" get svc "${svc}" -o jsonpath='{.spec.ports[?(@.name=="http")].port}')"
    if kubectl -n "${GATEWAY_NS}" exec "deploy/${GATEWAY_NAME}" -- \
         curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${svc}.${NAMESPACE}.svc.cluster.local:${port:-80}/realms/master" 2>/dev/null | grep -q 200; then
      ok "in-cluster: gateway -> ${svc}:${port:-80}/realms/master -> 200"
    else warn "in-cluster: gateway cannot reach ${svc}:${port:-80} (service/VirtualService/port problem)"; failed=1; fi
  fi

  if command -v curl >/dev/null 2>&1; then
    local i code=000
    for i in $(seq 1 30); do
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${KC_URL}/realms/master" || true)"
      [[ "${code}" == "200" ]] && break
      sleep 3
    done
    if [[ "${code}" == "200" ]]; then
      ok "${KC_URL}/realms/master -> HTTP 200 (host -> kind -> Istio gateway -> Keycloak)"
    else
      warn "${KC_URL}/realms/master -> HTTP ${code}"
      warn "gateway logs: kubectl -n ${GATEWAY_NS} logs deploy/${GATEWAY_NAME}"
      failed=1
    fi
  else
    warn "curl not installed — skipping HTTP check"
  fi

  if [[ "${failed}" -ne 0 ]]; then
    diagnose "${NAMESPACE}"
    die "Verification failed — see warnings above."
  fi
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
case "${1:-}" in
  --destroy)
    need kind
    log "Deleting kind cluster '${CLUSTER_NAME}'"
    kind delete cluster --name "${CLUSTER_NAME}"
    exit 0 ;;
  --verify)
    need kubectl; verify; exit 0 ;;
  --diagnose)
    need kubectl; diagnose "${NAMESPACE}"; exit 0 ;;
  --debug)
    DEBUG=true ;;
  "") ;;
  *) die "unknown flag '$1' (use --debug, --verify, --diagnose or --destroy)" ;;
esac

if [[ "${DEBUG}" == "true" ]]; then
  HELM_DEBUG=(--debug)
  export PS4='+ [$(date "+%H:%M:%S")] '
  set -x
fi
trap 'on_error ${LINENO}' ERR

# ---------------------------------------------------------------------------
# 1. Prereqs
# ---------------------------------------------------------------------------
log "Step 1/9: checking prerequisites"
for bin in docker kind kubectl helm git python3; do need "$bin"; ok "$bin: $(command -v "$bin")"; done
python3 -c "import yaml" 2>/dev/null || die "python3 PyYAML is required (pip install pyyaml)."
docker info >/dev/null 2>&1 || die "Docker daemon is not running."
ok "docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
ok "kind: $(kind version 2>/dev/null | cut -d' ' -f1-2)"
ok "helm: $(helm version --short)"
[[ -f "${VALUES_FILE}" ]] || die "Values file not found: ${VALUES_FILE}"
python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "${VALUES_FILE}" || die "${VALUES_FILE} is not valid YAML"
ok "values file: ${VALUES_FILE}"
for p in "${HOST_HTTP_PORT}" "${HOST_HTTPS_PORT}"; do
  if (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":${p} ") || \
     (command -v lsof >/dev/null && lsof -iTCP:"${p}" -sTCP:LISTEN >/dev/null 2>&1); then
    if ! docker ps --format '{{.Names}}' | grep -q "^${CLUSTER_NAME}-control-plane$"; then
      die "Host port ${p} is already in use (and not by this kind cluster). Set HOST_HTTP_PORT/HOST_HTTPS_PORT."
    fi
  fi
done
ok "host ports ${HOST_HTTP_PORT}/${HOST_HTTPS_PORT} available (or owned by this cluster)"

# ---------------------------------------------------------------------------
# 2. kind cluster
# ---------------------------------------------------------------------------
log "Step 2/9: kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "cluster exists — reusing it"
else
  info "creating (host :${HOST_HTTP_PORT} -> NodePort 30080, :${HOST_HTTPS_PORT} -> 30443)"
  kind create cluster --name "${CLUSTER_NAME}" --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: ${HOST_HTTP_PORT}
        protocol: TCP
      - containerPort: 30443
        hostPort: ${HOST_HTTPS_PORT}
        protocol: TCP
EOF
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl get nodes -o wide
kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null
ok "node(s) Ready; kubernetes $(kubectl version -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
if ! kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' | grep -q .; then
  die "No default StorageClass — the Postgres PVC would stay Pending. kind normally ships 'standard'."
fi
ok "default StorageClass present"

# ---------------------------------------------------------------------------
# 3. Istio
# ---------------------------------------------------------------------------
log "Step 3/9: Istio${ISTIO_VERSION:+ ${ISTIO_VERSION}} (base, istiod)"
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null
ISTIO_VER_ARGS=()
[[ -n "${ISTIO_VERSION}" ]] && ISTIO_VER_ARGS=(--version "${ISTIO_VERSION}")

run helm upgrade --install istio-base istio/base ${HELM_DEBUG[@]+"${HELM_DEBUG[@]}"} \
  --namespace "${ISTIO_NS}" --create-namespace ${ISTIO_VER_ARGS[@]+"${ISTIO_VER_ARGS[@]}"} \
  --set defaultRevision=default --wait --timeout 5m
run helm upgrade --install istiod istio/istiod ${HELM_DEBUG[@]+"${HELM_DEBUG[@]}"} \
  --namespace "${ISTIO_NS}" ${ISTIO_VER_ARGS[@]+"${ISTIO_VER_ARGS[@]}"} --wait --timeout 10m
kubectl -n "${ISTIO_NS}" rollout status deploy/istiod --timeout=120s
ok "istiod $(kubectl -n "${ISTIO_NS}" get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}')"
kubectl api-versions | grep -q '^networking.istio.io/v1$' || die "Istio CRDs (networking.istio.io/v1) not registered."
ok "Istio CRDs registered"

# ---------------------------------------------------------------------------
# 4. Ingress gateway + Gateway resource
# ---------------------------------------------------------------------------
log "Step 4/9: ingress gateway ${GATEWAY_NS}/${GATEWAY_NAME} (NodePort 30080/30443)"
kubectl create namespace "${GATEWAY_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
run helm upgrade --install "${GATEWAY_NAME}" istio/gateway ${HELM_DEBUG[@]+"${HELM_DEBUG[@]}"} \
  --namespace "${GATEWAY_NS}" ${ISTIO_VER_ARGS[@]+"${ISTIO_VER_ARGS[@]}"} --wait --timeout 10m \
  --values - <<EOF
service:
  type: NodePort
  ports:
    - name: status-port
      port: 15021
      targetPort: 15021
      nodePort: 30021
    - name: http2
      port: 80
      targetPort: 80
      nodePort: 30080
    - name: https
      port: 443
      targetPort: 443
      nodePort: 30443
resources:
  requests:
    cpu: 50m
    memory: 64Mi
EOF
kubectl -n "${GATEWAY_NS}" rollout status "deploy/${GATEWAY_NAME}" --timeout=120s
NP="$(kubectl -n "${GATEWAY_NS}" get svc "${GATEWAY_NAME}" -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')"
[[ "${NP}" == "30080" ]] || die "Gateway http2 NodePort is ${NP}, expected 30080 (kind maps host ${HOST_HTTP_PORT} -> 30080)."
ok "gateway service NodePort http2=30080"

GATEWAY_SELECTOR="${GATEWAY_NAME#istio-}"   # istio/gateway chart labels pods istio=<name minus istio- prefix>
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NS}
spec:
  selector:
    istio: ${GATEWAY_SELECTOR}
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*"
EOF
if ! kubectl -n "${GATEWAY_NS}" get pods -l "istio=${GATEWAY_SELECTOR}" -o name | grep -q .; then
  die "Gateway selector istio=${GATEWAY_SELECTOR} matches no pods in ${GATEWAY_NS}."
fi
ok "Gateway ${GATEWAY_NS}/${GATEWAY_NAME} selects $(kubectl -n "${GATEWAY_NS}" get pods -l "istio=${GATEWAY_SELECTOR}" -o name | wc -l | tr -d ' ') pod(s)"

# ---------------------------------------------------------------------------
# 5. Chart
# ---------------------------------------------------------------------------
log "Step 5/9: Big Bang Keycloak chart @ ${CHART_REF}"
mkdir -p "${WORK_DIR}"
if [[ -d "${CHART_DIR}/.git" ]]; then
  run git -C "${CHART_DIR}" fetch --depth 1 origin "${CHART_REF}"
  run git -C "${CHART_DIR}" checkout -q FETCH_HEAD
else
  run git clone --depth 1 --branch "${CHART_REF}" "${CHART_REPO}" "${CHART_DIR}"
fi
[[ -f "${CHART_DIR}/chart/Chart.yaml" ]] || die "No chart/Chart.yaml in ${CHART_DIR}"
ok "chart: $(grep -E '^(name|version|appVersion):' "${CHART_DIR}/chart/Chart.yaml" | tr '\n' ' ')"
if [[ -f "${CHART_DIR}/chart/Chart.lock" ]] && { [[ ! -d "${CHART_DIR}/chart/charts" ]] || [[ -z "$(ls -A "${CHART_DIR}/chart/charts" 2>/dev/null)" ]]; }; then
  info "subcharts not vendored — running helm dependency build (needs access to the OCI repos in Chart.yaml)"
  run helm dependency build "${CHART_DIR}/chart"
fi
ok "subcharts: $(ls "${CHART_DIR}/chart/charts" 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 6. Pre-flight render + static checks
# ---------------------------------------------------------------------------
log "Step 6/9: pre-flight render + checks"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if [[ "${ISTIO_INJECT}" == "true" ]]; then
  kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite >/dev/null
  ok "sidecar injection ON for ${NAMESPACE}"
else
  kubectl label namespace "${NAMESPACE}" istio-injection- >/dev/null 2>&1 || true
  ok "sidecar injection OFF for ${NAMESPACE}"
fi

HELM_SET_ARGS=(
  --set-string "upstream.secrets.env.stringData.KC_HOSTNAME=${KC_URL}"
  --set-string "upstream.secrets.env.stringData.KC_BOOTSTRAP_ADMIN_USERNAME=${KC_ADMIN_USER}"
  --set-string "upstream.secrets.env.stringData.KC_BOOTSTRAP_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}"
  --set-string "upstream.secrets.env.stringData.KEYCLOAK_ADMIN=${KC_ADMIN_USER}"
  --set-string "upstream.secrets.env.stringData.KEYCLOAK_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}"
)

helm template "${RELEASE}" "${CHART_DIR}/chart" --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" "${HELM_SET_ARGS[@]}" > "${RENDERED}"
ok "rendered $(grep -c '^kind:' "${RENDERED}") resources -> ${RENDERED}"

# 6a. duplicate env names, 6b. db hostname vs rendered services, 6c. volumes vs secrets/configmaps
python3 - "${RENDERED}" <<'PY'
import sys, yaml, collections
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
problems = []
svcs = {d["metadata"]["name"] for d in docs if d.get("kind") == "Service"}
secrets = {d["metadata"]["name"] for d in docs if d.get("kind") == "Secret"}
cms = {d["metadata"]["name"] for d in docs if d.get("kind") == "ConfigMap"}
for d in docs:
    if d.get("kind") not in ("StatefulSet", "Deployment"): continue
    name = f'{d["kind"]}/{d["metadata"]["name"]}'
    spec = d["spec"]["template"]["spec"]
    for c in spec.get("initContainers", []) + spec.get("containers", []):
        env = c.get("env", []) or []
        dup = [n for n, k in collections.Counter(e["name"] for e in env).items() if k > 1]
        if dup: problems.append(f"{name} container {c['name']}: duplicate env {dup}")
        for e in env:
            if e["name"] == "KC_DB_URL_HOST":
                host = e.get("value", "")
                if host and host.split(".")[0] not in svcs:
                    problems.append(f"{name}: KC_DB_URL_HOST={host} but rendered Services are {sorted(svcs)} "
                                    f"-> fix upstream.database.hostname")
        print(f"  image  {name} / {c['name']}: {c.get('image')}")
    for v in spec.get("volumes", []) or []:
        if "secret" in v and v["secret"].get("secretName") not in secrets and not v["secret"].get("optional"):
            problems.append(f"{name}: volume {v['name']} wants Secret {v['secret']['secretName']} which the chart does not render")
        if "configMap" in v and v["configMap"].get("name") not in cms and not v["configMap"].get("optional"):
            problems.append(f"{name}: volume {v['name']} wants ConfigMap {v['configMap']['name']} which the chart does not render")
    for c in spec.get("containers", []):
        for src in c.get("envFrom", []) or []:
            ref = src.get("secretRef", {}).get("name")
            if ref and ref not in secrets and not src["secretRef"].get("optional"):
                problems.append(f"{name} container {c['name']}: envFrom Secret {ref} is not rendered by the chart")
if problems:
    print("\n".join("  ✗ " + p for p in problems)); sys.exit(1)
PY
ok "no duplicate env keys; DB host matches a rendered Service; all volume/envFrom refs are rendered"

# 6d. images: refuse registry1 (needs creds), optionally pre-pull + load into kind
IMAGES="$(grep -E '^\s+image:' "${RENDERED}" | sed -E 's/^\s+image:\s*"?([^"]*)"?/\1/' | sort -u)"
if grep -q 'registry1.dso.mil' <<<"${IMAGES}"; then
  warn "rendered manifests reference Iron Bank images:"
  grep 'registry1.dso.mil' <<<"${IMAGES}" | sed 's/^/      /'
  die "Those need registry1 credentials. Override the corresponding image values in ${VALUES_FILE} (see upstream.image, postgresql.image, dbchecker, extraInitContainers)."
fi
if [[ "${PREPULL_IMAGES}" == "true" ]]; then
  while read -r img; do
    [[ -z "${img}" ]] && continue
    if docker image inspect "${img}" >/dev/null 2>&1; then
      info "cached   ${img}"
    else
      info "pulling  ${img}"
      docker pull -q "${img}" >/dev/null || die "docker pull failed for ${img} — check the tag exists and registry is reachable."
    fi
    kind load docker-image --name "${CLUSTER_NAME}" "${img}" >/dev/null 2>&1 || warn "kind load failed for ${img} (node will pull it itself)"
  done <<<"${IMAGES}"
  ok "images pulled and loaded into kind"
fi

# ---------------------------------------------------------------------------
# 7. Install Keycloak (no helm --wait: we watch the StatefulSets ourselves)
# ---------------------------------------------------------------------------
log "Step 7/9: helm upgrade --install ${RELEASE}"
run helm upgrade --install "${RELEASE}" "${CHART_DIR}/chart" ${HELM_DEBUG[@]+"${HELM_DEBUG[@]}"} \
  --namespace "${NAMESPACE}" \
  --values "${VALUES_FILE}" "${HELM_SET_ARGS[@]}" \
  --timeout 15m
helm -n "${NAMESPACE}" status "${RELEASE}" | head -n 8

PG_STS="$(grep -B1 -A3 '^kind: StatefulSet' "${RENDERED}" | grep -E '^\s+name:' | awk '{print $2}' | grep -i postgres | head -n1 || true)"
KC_STS="$(kubectl -n "${NAMESPACE}" get sts -l app.kubernetes.io/name=keycloakx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
KC_STS="${KC_STS:-${RELEASE}-keycloak}"
[[ -n "${PG_STS}" ]] && wait_for_sts "${NAMESPACE}" "${PG_STS}"
wait_for_sts "${NAMESPACE}" "${KC_STS}"

# ---------------------------------------------------------------------------
# 8. VirtualService
# ---------------------------------------------------------------------------
log "Step 8/9: VirtualService"
KC_SVC="$(kubectl -n "${NAMESPACE}" get svc -l app.kubernetes.io/name=keycloakx \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v headless | head -n1 || true)"
[[ -n "${KC_SVC}" ]] || KC_SVC="${RELEASE}-keycloak"
KC_SVC_PORT="$(kubectl -n "${NAMESPACE}" get svc "${KC_SVC}" -o jsonpath='{.spec.ports[?(@.name=="http")].port}' 2>/dev/null || true)"
KC_SVC_PORT="${KC_SVC_PORT:-80}"
kubectl -n "${NAMESPACE}" get endpoints "${KC_SVC}" -o jsonpath='{.subsets[*].addresses[*].ip}' | grep -q . \
  || die "Service ${KC_SVC} has no endpoints — pod not Ready or selector mismatch."
ok "service ${KC_SVC}:${KC_SVC_PORT} has endpoints"

kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: keycloak
  namespace: ${NAMESPACE}
spec:
  # "*" so localhost, 127.0.0.1 and keycloak.localhost all route here.
  # (A bare "localhost" would be expanded by Istio to localhost.${NAMESPACE}.svc.)
  hosts:
    - "*"
  gateways:
    - ${GATEWAY_NS}/${GATEWAY_NAME}
  http:
    - route:
        - destination:
            host: ${KC_SVC}.${NAMESPACE}.svc.cluster.local
            port:
              number: ${KC_SVC_PORT}
EOF
ok "VirtualService ${NAMESPACE}/keycloak -> ${KC_SVC}:${KC_SVC_PORT}"

# ---------------------------------------------------------------------------
# 9. Verify
# ---------------------------------------------------------------------------
log "Step 9/9: verify"
verify

cat <<EOF

Keycloak is up behind Istio.

  URL:        ${KC_URL}/
  Admin UI:   ${KC_URL}/admin/
  Username:   ${KC_ADMIN_USER}
  Password:   ${KC_ADMIN_PASSWORD}

  Pods:       kubectl -n ${NAMESPACE} get pods
  Logs:       kubectl -n ${NAMESPACE} logs -f -l app.kubernetes.io/name=keycloakx
  Gateway:    kubectl -n ${GATEWAY_NS} get gateway,svc
  Diagnose:   $0 --diagnose
  Re-verify:  $0 --verify
  Tear down:  $0 --destroy
EOF
