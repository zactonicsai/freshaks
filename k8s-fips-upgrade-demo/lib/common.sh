#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
#  lib/common.sh - helpers shared by every script: settings, logging, waiting.
#  Usage at the top of a script:
#      source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#      init "my-script-name" "$@"
# ============================================================================
set -Eeuo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "bash 4 or newer is needed (macOS: brew install bash)" >&2; exit 1; fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT_DIR/config.env"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/state}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work}"          # secrets made at run time (keys, keytab). Never commit it.
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-$CLUSTER_NAME}"
SITE_URL="https://$APP_HOSTNAME:$HOST_HTTPS_PORT"
PART_OF_LABEL="app.kubernetes.io/part-of=fipsdemo"   # every object we create carries this label
SPN="HTTP/$APP_HOSTNAME"                              # the app's Kerberos service name

# ---- logging: everything goes to the screen AND to one log file per run ----
ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '%s [INFO ] %s\n' "$(ts)" "$*"; }
ok()   { printf '%s [ OK  ] %s\n' "$(ts)" "$*"; }
warn() { printf '%s [WARN ] %s\n' "$(ts)" "$*"; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }
step() { printf '\n%s [STEP ] ===== %s =====\n' "$(ts)" "$*"; }
die()  { err "$*"; exit 1; }
history_line() { mkdir -p "$LOG_DIR"; printf '%s %s\n' "$(ts)" "$*" >> "$LOG_DIR/history.log"; }

init() {
  SCRIPT_NAME="$1"; shift || true
  mkdir -p "$LOG_DIR" "$STATE_DIR" "$WORK_DIR"; chmod 700 "$WORK_DIR"
  IS_TOP_LEVEL=0
  if [ -z "${FIPSDEMO_LOG_FILE:-}" ]; then
    # first script in the chain: open the log. Scripts started by this one write into the same file.
    IS_TOP_LEVEL=1
    FIPSDEMO_LOG_FILE="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$SCRIPT_NAME.log"
    export FIPSDEMO_LOG_FILE
    exec > >(tee -a "$FIPSDEMO_LOG_FILE") 2>&1
    TEE_PID=$!
  fi
  trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
  trap 'on_exit "$?"' EXIT
  history_line "START $SCRIPT_NAME args=[$*] user=$(id -un) context=$KUBE_CONTEXT log=$(basename "$FIPSDEMO_LOG_FILE")"
  log "$SCRIPT_NAME started. Log file: $FIPSDEMO_LOG_FILE"
}
on_err() { local cmd="${2%%$'\n'*}"; err "command failed at line $1 of $SCRIPT_NAME: ${cmd:0:140}"; }
on_exit() {
  local code="$1"
  trap - EXIT
  if declare -F cleanup_hook >/dev/null; then cleanup_hook || true; fi
  history_line "END   $SCRIPT_NAME exit=$code"
  if [ "$code" -eq 0 ]; then ok "$SCRIPT_NAME finished"; else err "$SCRIPT_NAME FAILED (exit $code). Read the log: $FIPSDEMO_LOG_FILE"; fi
  if [ "${IS_TOP_LEVEL:-0}" -eq 1 ] && [ -n "${TEE_PID:-}" ]; then
    exec 1>&- 2>&-            # close our end so tee can finish writing the log
    wait "$TEE_PID" 2>/dev/null || true
  fi
  exit "$code"
}

# ---- small tools -------------------------------------------------------------
need() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "'$c' is not installed. Run scripts/00-check-tools.sh"; done; }
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }
confirm() { # confirm "question" WORD
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  local answer; printf '%s\nType %s to go on: ' "$1" "$2" >/dev/tty; read -r answer </dev/tty
  [ "$answer" = "$2" ] || die "stopped by you"
}
# wait_until "what we wait for" TRIES SLEEP_SECONDS command...
wait_until() {
  local what="$1" tries="$2" pause="$3" i; shift 3
  for ((i = 1; i <= tries; i++)); do
    if "$@" >/dev/null 2>&1; then ok "$what"; return 0; fi
    sleep "$pause"
  done
  err "gave up waiting for: $what"; return 1
}
# render FILE KEY=VALUE...   prints FILE with every __KEY__ replaced; fails if a __KEY__ is left over
render() {
  local file="$1" kv out; shift
  local -a args=()
  for kv in "$@"; do args+=(-e "s|__${kv%%=*}__|${kv#*=}|g"); done
  out="$(sed "${args[@]}" "$file")"
  if grep -Eq '__[A-Z][A-Z0-9_]*__' <<<"$out"; then
    err "template $file still has placeholders: $(grep -Eo '__[A-Z][A-Z0-9_]*__' <<<"$out" | sort -u | tr '\n' ' ')"; return 1
  fi
  printf '%s\n' "$out"
}
sel_key() { printf '%s' "${1%%=*}"; }      # "nodepool=green" -> nodepool
sel_val() { printf '%s' "${1#*=}"; }       # "nodepool=green" -> green
rollout_wait() { k -n "$1" rollout status "$2" --timeout="$ROLLOUT_TIMEOUT"; }
live_track() { k -n "$APP_NS" get virtualservice fipsdemo -o jsonpath='{.metadata.annotations.fipsdemo/live-track}' 2>/dev/null || true; }
run_script() { local s="$1"; shift; "$ROOT_DIR/scripts/$s" "$@"; }
site_curl() { curl -sS --max-time 20 --cacert "$WORK_DIR/ipa/ca.crt" --resolve "$APP_HOSTNAME:$HOST_HTTPS_PORT:127.0.0.1" "$@"; }
# apply_secret NAMESPACE NAME key=file...   (create-or-update, labelled, never printed)
apply_secret() {
  local ns="$1" name="$2" kv; shift 2
  local -a args=()
  for kv in "$@"; do args+=("--from-file=$kv"); done
  k -n "$ns" create secret generic "$name" "${args[@]}" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" label secret "$name" "$PART_OF_LABEL" --overwrite >/dev/null
  ok "secret $ns/$name is in place"
}
apply_configmap() {
  local ns="$1" name="$2" kv; shift 2
  local -a args=()
  for kv in "$@"; do args+=("--from-file=$kv"); done
  k -n "$ns" create configmap "$name" "${args[@]}" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" label configmap "$name" "$PART_OF_LABEL" --overwrite >/dev/null
  ok "configmap $ns/$name is in place"
}

# shellcheck source=platform.sh
source "$ROOT_DIR/lib/platform.sh"
# shellcheck source=deploy.sh
source "$ROOT_DIR/lib/deploy.sh"
# Test seam: a file named in FIPSDEMO_TEST_HOOKS may replace platform functions (used by tests/, see TEST-REPORT.md)
if [ -n "${FIPSDEMO_TEST_HOOKS:-}" ]; then
  # shellcheck disable=SC1090
  source "$FIPSDEMO_TEST_HOOKS"
fi

# ---- what "the state" is: every kind of object the demo creates (used by save, restore, rollback) ----
STATE_KINDS=(serviceaccounts configmaps secrets roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io
  services deployments.apps horizontalpodautoscalers.autoscaling poddisruptionbudgets.policy
  gateways.networking.istio.io destinationrules.networking.istio.io virtualservices.networking.istio.io
  serviceentries.networking.istio.io sidecars.networking.istio.io
  peerauthentications.security.istio.io authorizationpolicies.security.istio.io)
kind_order() { # in which order objects are put back: settings first, pods later, traffic rules last
  case "$1" in
    serviceaccounts) echo 10 ;; configmaps|secrets) echo 20 ;; roles.*) echo 30 ;; rolebindings.*) echo 31 ;;
    services) echo 40 ;; deployments.*) echo 50 ;; horizontalpodautoscalers.*|poddisruptionbudgets.*) echo 60 ;;
    *) echo 70 ;;
  esac
}
# jq program that turns a live object into a clean file that can be applied to any cluster
JQ_CLEAN='del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.generation,
              .metadata.managedFields, .metadata.selfLink, .metadata.ownerReferences, .status)
  | if .metadata.annotations then .metadata.annotations |= del(.["kubectl.kubernetes.io/last-applied-configuration"], .["deployment.kubernetes.io/revision"]) else . end
  | if .metadata.annotations == {} then del(.metadata.annotations) else . end
  | if .kind == "Service" then del(.spec.clusterIP, .spec.clusterIPs) else . end
  | if .kind == "Namespace" then del(.spec) else . end'
state_namespaces() { printf '%s\n' "$APP_NS" "$INGRESS_NS"; }
