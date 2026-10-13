#!/usr/bin/env bash
# =============================================================================
#  lib/common.sh  —  shared helper library (SOURCE it, never execute it)
# =============================================================================
#  Every script in discover/, import/ and destroy/ starts with:
#
#      source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#      load_config     # read config.env and apply defaults
#      az_check        # verify `az login`, select the subscription, find MC_ RG
#
#  What this file provides:
#
#    Directory layout ......... ROOT_DIR, TF_DIR, IMPORTS_DIR, GENERATED_DIR, OUT_DIR
#    Logging .................. log / ok / warn / die / hr
#    DRY_RUN-aware runner ..... run <cmd> [args]   (prints instead of executing)
#    Configuration ............ load_config
#    Tool & login checks ...... require_tools, az_check, aks_credentials
#    Terraform import helpers . tf_import_begin / tf_import_add / tf_import_end
#                               tf_generate, tf_write_tfvars, archive_import_blocks
#    Utilities ................ tf_name, in_list, is_system_ns, target_namespaces,
#                               confirm, rg_exists, json_items
#
#  Design notes
#  ------------
#  * The import scripts never call `terraform import` directly. They write
#    Terraform 1.5+ `import {}` blocks into terraform/imports/<service>.tf and
#    then run `terraform plan -generate-config-out=...`, which makes Terraform
#    write the matching `resource {}` blocks for you. A parallel list of plain
#    `terraform import ADDR ID` commands is also written to
#    out/import-commands/<service>.sh for people who prefer the classic flow.
#  * All loops use process substitution  < <(jq ...)  rather than  jq | while,
#    so that variables set inside the loop survive (pipelines run in subshells).
#  * Written for bash 3.2+ (macOS default): no associative arrays, no mapfile,
#    no ${var,,}. `set -euo pipefail` is on everywhere, so every optional
#    command is explicitly guarded with `|| true` or an `if`.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Directory layout — absolute paths so scripts can be run from any cwd
# ---------------------------------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"                  # Terraform root module
IMPORTS_DIR="$TF_DIR/imports"                 # import {} blocks   (written by import/*.sh)
GENERATED_DIR="$TF_DIR/generated"             # resource {} blocks (written by terraform)
HELM_VALUES_DIR="$TF_DIR/helm-values"         # one values.yaml per Helm release
OUT_DIR="$ROOT_DIR/out"                       # inventories, logs, kubeconfig, backups
IMPORT_CMDS_DIR="$OUT_DIR/import-commands"    # classic `terraform import` command lists
IMPORT_LOG="$OUT_DIR/imports.csv"             # audit trail: service,address,id
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config.env}"

mkdir -p "$IMPORTS_DIR" "$GENERATED_DIR" "$HELM_VALUES_DIR" "$OUT_DIR" "$IMPORT_CMDS_DIR"

# Let `az` install the CLI extensions it needs (k8s-extension, amg,
# log-analytics-solution ...) on first use without stopping to ask.
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL="${AZURE_EXTENSION_USE_DYNAMIC_INSTALL:-yes_without_prompt}"
export AZURE_EXTENSION_RUN_AFTER_DYNAMIC_INSTALL="${AZURE_EXTENSION_RUN_AFTER_DYNAMIC_INSTALL:-true}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
ok()   { printf '\033[1;32m    +\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
hr()   { printf '%s\n' "----------------------------------------------------------------------"; }

# run <cmd> [args...]
#   Executes the command. When DRY_RUN=true it only prints the command
#   (shell-quoted) so every destructive action can be reviewed first.
run() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '\033[1;35m[dry-run]\033[0m'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# load_config
#   Sources config.env (exporting every variable), validates the required
#   settings and fills in defaults for the optional ones. Every script calls
#   this first.
load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE  (cp config.env.example config.env, then edit it)"
  set -a                       # auto-export everything the file defines
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a

  : "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required in config.env}"
  : "${RESOURCE_GROUP:?RESOURCE_GROUP is required in config.env}"
  : "${CLUSTER_NAME:?CLUSTER_NAME is required in config.env}"

  # ---- optional settings and their defaults ---------------------------------
  NODE_RESOURCE_GROUP="${NODE_RESOURCE_GROUP:-}"        # auto-detected by az_check
  LOCATION="${LOCATION:-}"                              # auto-detected by az_check
  INCLUDE_NODE_RG="${INCLUDE_NODE_RG:-false}"           # also scan MC_* resource group
  DRY_RUN="${DRY_RUN:-false}"                           # print instead of execute
  SKIP_GENERATE="${SKIP_GENERATE:-false}"               # skip terraform plan -generate-config-out
  KUBECONFIG_PATH="${KUBECONFIG_PATH:-$OUT_DIR/kubeconfig}"
  USE_ADMIN_CREDENTIALS="${USE_ADMIN_CREDENTIALS:-false}"  # az aks get-credentials --admin
  SYSTEM_NAMESPACES="${SYSTEM_NAMESPACES:-kube-system kube-public kube-node-lease gatekeeper-system calico-system tigera-operator aks-istio-system aks-istio-ingress aks-istio-egress aks-command app-routing-system azure-arc azure-arc-release dapr-system kube-federation-system}"
  K8S_NAMESPACES="${K8S_NAMESPACES:-}"                  # explicit namespace list (blank = all non-system)
  IMPORT_SECRETS="${IMPORT_SECRETS:-false}"             # kubernetes_secret_v1 (data lands in state!)
  IMPORT_FILE_SHARES="${IMPORT_FILE_SHARES:-false}"     # azurerm_storage_share
  IMPORT_KEYVAULT_SECRETS="${IMPORT_KEYVAULT_SECRETS:-false}"  # azurerm_key_vault_secret
  HELM_SKIP_RELEASES="${HELM_SKIP_RELEASES:-}"          # "ns/name ns2/name2"
  HELM_REPO_MAP="${HELM_REPO_MAP:-}"                    # "chart=https://repo chart2=oci://..."
  ACR_NAMES="${ACR_NAMES:-}"                            # extra registries outside RESOURCE_GROUP

  export KUBECONFIG="$KUBECONFIG_PATH"
}

# require_tools <tool> [tool...]
#   Aborts with a clear message when a CLI dependency is missing.
require_tools() {
  local t missing=()
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then missing+=("$t"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tool(s): ${missing[*]}"
  fi
}

# az_check
#   * az account show      — proves there is a valid login token
#   * az account set       — pins every later call to SUBSCRIPTION_ID
#   * az group show        — resolves LOCATION of the resource group
#   * az aks show          — resolves the AKS node resource group (MC_<rg>_<cluster>_<region>)
az_check() {
  require_tools az jq
  az account show -o none 2>/dev/null || die "Azure CLI is not logged in. Run: az login"
  az account set --subscription "$SUBSCRIPTION_ID" -o none || die "Cannot select subscription $SUBSCRIPTION_ID"
  if [[ -z "$LOCATION" ]]; then
    LOCATION="$(az group show -n "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)"
  fi
  if [[ -z "$NODE_RESOURCE_GROUP" ]]; then
    NODE_RESOURCE_GROUP="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query nodeResourceGroup -o tsv 2>/dev/null || true)"
  fi
  export LOCATION NODE_RESOURCE_GROUP
  log "Subscription=$SUBSCRIPTION_ID  RG=$RESOURCE_GROUP  Cluster=$CLUSTER_NAME  NodeRG=${NODE_RESOURCE_GROUP:-<not found>}"
}

# rg_exists <name>  -> 0 when the resource group exists
rg_exists() {
  [[ -n "$1" ]] && [[ "$(az group exists -n "$1" -o tsv 2>/dev/null || echo false)" == "true" ]]
}

# aks_credentials
#   * az aks get-credentials  — writes a kubeconfig for the cluster to KUBECONFIG_PATH
#   * kubelogin convert       — converts the Entra ID exec plugin so kubectl can
#                               reuse the `az login` token (no-op for local accounts)
#   * kubectl cluster-info    — proves the API server is reachable before we go on
aks_credentials() {
  require_tools kubectl
  local args=(-g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --file "$KUBECONFIG_PATH" --overwrite-existing)
  if [[ "$USE_ADMIN_CREDENTIALS" == "true" ]]; then args+=(--admin); fi
  log "Fetching kubeconfig -> ${KUBECONFIG_PATH#$ROOT_DIR/}"
  az aks get-credentials "${args[@]}" -o none
  if command -v kubelogin >/dev/null 2>&1; then
    kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG_PATH" >/dev/null 2>&1 || true
  fi
  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach the API server. Private cluster? Missing kubelogin? Try USE_ADMIN_CREDENTIALS=true"
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
# tf_name <any string>
#   Converts an Azure / Kubernetes name into a legal Terraform resource label:
#   only [A-Za-z0-9_], and it may not start with a digit.
tf_name() {
  local n="$1"
  n="${n//[^a-zA-Z0-9_]/_}"
  case "$n" in [0-9]*) n="r_$n" ;; esac
  printf '%s' "$n"
}

# in_list <needle> <word> [word...]
in_list() {
  local x="$1" i; shift
  for i in "$@"; do
    if [[ "$i" == "$x" ]]; then return 0; fi
  done
  return 1
}

# is_system_ns <namespace>  -> 0 when the namespace is AKS / platform managed
is_system_ns() {
  # shellcheck disable=SC2086
  in_list "$1" $SYSTEM_NAMESPACES
}

# target_namespaces
#   Prints one namespace per line: K8S_NAMESPACES when set, otherwise every
#   namespace in the cluster that is not in SYSTEM_NAMESPACES.
target_namespaces() {
  if [[ -n "$K8S_NAMESPACES" ]]; then
    # shellcheck disable=SC2086
    printf '%s\n' $K8S_NAMESPACES
    return 0
  fi
  local ns
  while IFS= read -r ns; do
    if [[ -n "$ns" ]] && ! is_system_ns "$ns"; then printf '%s\n' "$ns"; fi
  done < <(kubectl get ns -o json | jq -r '.items[].metadata.name')
}

# confirm <text-to-type>
#   Interactive guard used by every destructive script. Bypassed by
#   CONFIRM=yes (used by destroy-all.sh) or DRY_RUN=true.
confirm() {
  if [[ "${CONFIRM:-}" == "yes" || "$DRY_RUN" == "true" ]]; then return 0; fi
  printf '\nType "%s" to continue (anything else aborts): ' "$1"
  local answer
  read -r answer
  [[ "$answer" == "$1" ]] || die "Aborted."
}

# ---------------------------------------------------------------------------
# Terraform import helpers
# ---------------------------------------------------------------------------
# tf_write_tfvars
#   Mirrors config.env into terraform/terraform.tfvars so the providers know
#   the subscription and where the kubeconfig is.
tf_write_tfvars() {
  cat >"$TF_DIR/terraform.tfvars" <<EOF
# Generated by lib/common.sh from config.env — edit config.env instead.
subscription_id = "$SUBSCRIPTION_ID"
resource_group  = "$RESOURCE_GROUP"
cluster_name    = "$CLUSTER_NAME"
kubeconfig_path = "$KUBECONFIG_PATH"
EOF
}

# tf_import_begin <service>
#   Starts (truncates) terraform/imports/<service>.tf and
#   out/import-commands/<service>.sh, and drops this service's previous rows
#   from out/imports.csv so a re-run produces a clean result.
tf_import_begin() {
  CURRENT_SERVICE="$1"
  CURRENT_IMPORT_FILE="$IMPORTS_DIR/${1}.tf"
  CURRENT_CMD_FILE="$IMPORT_CMDS_DIR/${1}.sh"
  log "Import blocks -> ${CURRENT_IMPORT_FILE#$ROOT_DIR/}"
  cat >"$CURRENT_IMPORT_FILE" <<EOF
# -----------------------------------------------------------------------------
# Service : $1
# Written : $(date -u +%Y-%m-%dT%H:%M:%SZ) by import/*.sh
#
# Each import {} block tells Terraform (>= 1.5) to adopt an existing object
# into state. The matching resource {} blocks are produced by
#     terraform plan -generate-config-out=generated/$1.tf
# and the import itself happens on the next 'terraform apply'.
# Import blocks are ONE-SHOT: once applied, lib/common.sh archives this file to
# out/imports-applied/ so a later plan does not try to re-import.
# -----------------------------------------------------------------------------

EOF
  printf '#!/usr/bin/env bash\n# Classic `terraform import` commands for service: %s\n# Run from terraform/ AFTER you have written matching resource {} blocks.\nset -e\n' "$1" >"$CURRENT_CMD_FILE"
  if [[ -f "$IMPORT_LOG" ]]; then
    grep -v "^${1}," "$IMPORT_LOG" >"$IMPORT_LOG.tmp" || true
    mv "$IMPORT_LOG.tmp" "$IMPORT_LOG"
  else
    printf 'service,address,id\n' >"$IMPORT_LOG"
  fi
  tf_write_tfvars
}

# tf_import_add <terraform type> <label> <import id> [comment]
#   Appends one import {} block, one `terraform import` command and one audit
#   row. Idempotent: an address already present in ANY import file is skipped,
#   so running the scripts twice never produces duplicate blocks.
tf_import_add() {
  local type="$1" name="$2" id="$3" comment="${4:-}"
  local addr="${type}.${name}"
  if grep -qsFx "  to = ${addr}" "$IMPORTS_DIR"/*.tf; then
    log "  (already recorded by another step, skipping duplicate: $addr)"
    return 0
  fi
  {
    if [[ -n "$comment" ]]; then printf '# %s\n' "$comment"; fi
    printf 'import {\n  to = %s\n  id = "%s"\n}\n\n' "$addr" "$id"
  } >>"$CURRENT_IMPORT_FILE"
  printf 'terraform import %q %q\n' "$addr" "$id" >>"$CURRENT_CMD_FILE"
  printf '%s,%s,%s\n' "$CURRENT_SERVICE" "$addr" "$id" >>"$IMPORT_LOG"
  ok "$addr"
}

# tf_generate <service>
#   terraform init (first time only) and
#   terraform plan -generate-config-out=generated/<service>.tf
#   Terraform reads every object named in an import {} block that has no
#   resource {} block yet, and writes HCL for it. Failures are reported but are
#   NOT fatal, so one bad import block does not stop the whole run.
tf_generate() {
  local service="$1"
  if [[ "$SKIP_GENERATE" == "true" ]]; then
    log "SKIP_GENERATE=true -> not running terraform plan -generate-config-out"
    return 0
  fi
  require_tools terraform
  tf_write_tfvars
  local out="generated/${service}.tf"
  if [[ -f "$TF_DIR/$out" ]]; then
    out="generated/${service}.$(date +%Y%m%d-%H%M%S).tf"
    warn "generated/${service}.tf already exists; new resources will be written to $out"
  fi
  (
    cd "$TF_DIR"
    if [[ ! -d .terraform ]]; then
      log "terraform init"
      run terraform init -input=false >"$OUT_DIR/terraform-init.log" 2>&1 \
        || { tail -n 20 "$OUT_DIR/terraform-init.log" >&2; die "terraform init failed (see out/terraform-init.log)"; }
    fi
    log "terraform plan -generate-config-out=$out"
    if run terraform plan -input=false -generate-config-out="$out" >"$OUT_DIR/plan-${service}.log" 2>&1; then
      if [[ -f "$out" ]]; then ok "wrote terraform/$out — review it before applying"; else log "nothing new to generate"; fi
    else
      tail -n 30 "$OUT_DIR/plan-${service}.log" >&2
      warn "terraform plan failed for '$service' (full log: out/plan-${service}.log)."
      warn "Fix or delete the offending import block, then re-run:  cd terraform && terraform plan -generate-config-out=$out"
    fi
  )
}

# tf_import_end
#   Reports how many blocks were written, removes an empty import file, and
#   triggers config generation.
tf_import_end() {
  local count
  count="$(grep -c '^import {' "$CURRENT_IMPORT_FILE" 2>/dev/null || true)"
  count="${count:-0}"
  hr
  log "$CURRENT_SERVICE: $count import block(s) recorded"
  if [[ "$count" -eq 0 ]]; then
    rm -f "$CURRENT_IMPORT_FILE" "$CURRENT_CMD_FILE"
    return 0
  fi
  tf_generate "$CURRENT_SERVICE"
}

# archive_import_blocks
#   Moves terraform/imports/*.tf to out/imports-applied/<timestamp>/.
#   Called after a successful `terraform apply` and before any destroy, because
#   an import block whose object no longer exists makes every plan fail.
archive_import_blocks() {
  local f found=false
  for f in "$IMPORTS_DIR"/*.tf; do
    if [[ -f "$f" ]]; then found=true; fi
  done
  if [[ "$found" == "false" ]]; then return 0; fi
  local dest
  dest="$OUT_DIR/imports-applied/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dest"
  mv "$IMPORTS_DIR"/*.tf "$dest"/
  log "Archived import blocks -> ${dest#$ROOT_DIR/}"
}

# json_items <json>  -> each element of a JSON array on its own line (compact)
json_items() { jq -c '.[]' <<<"$1"; }
