#!/usr/bin/env bash
# Shared helpers for the scripts in scripts/. Source this file; do not run it.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="${TF_BIN:-terraform}" # TF_BIN=tofu runs everything with OpenTofu

log() { printf '\n==> %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found on PATH: $tool"
  done
}

# cfg <yq expression>: read one value from the merged config of the loaded cluster.
cfg() { yq -r "$1" "$CONFIG_FILE"; }

# load_config <cluster>: merge global.yaml with one cluster file and export
# everything the later steps need. <cluster> is a file name in config/clusters.
load_config() {
  CLUSTER="${1:-}"
  [[ -n "$CLUSTER" ]] || die "usage: ${0##*/} <cluster>  (a file name in config/clusters, without .yaml)"
  [[ "$CLUSTER" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] ||
    die "invalid cluster name '$CLUSTER': lowercase letters, digits and dashes, 40 characters at most"
  local cluster_file="$ROOT/config/clusters/$CLUSTER.yaml"
  [[ -f "$cluster_file" ]] || die "config/clusters/$CLUSTER.yaml not found"
  need yq

  BUILD_DIR="$ROOT/.build/$CLUSTER"
  CONFIG_FILE="$BUILD_DIR/config.yaml"
  mkdir -p "$BUILD_DIR"
  # Deep merge: maps merge key by key, lists and scalars are replaced.
  # Helm applies the same rule when Argo CD reads the same two files.
  # shellcheck disable=SC2016
  yq eval-all '. as $doc ireduce ({}; . * $doc)' "$ROOT/config/global.yaml" "$cluster_file" >"$CONFIG_FILE"

  [[ "$(cfg '.cluster.name')" == "$CLUSTER" ]] ||
    die "cluster.name in config/clusters/$CLUSTER.yaml must be '$CLUSTER'"
  CLUSTER_TYPE="$(cfg '.cluster.type')"
  DRIVER_DIR="$ROOT/terraform/clusters/$CLUSTER_TYPE"
  [[ -f "$DRIVER_DIR/kubeconfig.sh" ]] ||
    die "unknown cluster.type '$CLUSTER_TYPE': terraform/clusters/$CLUSTER_TYPE/kubeconfig.sh does not exist"

  # One private kubeconfig per cluster. ~/.kube/config is never modified.
  KUBECONFIG="$BUILD_DIR/kubeconfig"
  export ROOT CLUSTER CLUSTER_TYPE BUILD_DIR CONFIG_FILE DRIVER_DIR KUBECONFIG
  export TF_VAR_config_file="$CONFIG_FILE" TF_VAR_kubeconfig="$KUBECONFIG"
  export TF_IN_AUTOMATION=1 TF_INPUT=0
  export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
  mkdir -p "$TF_PLUGIN_CACHE_DIR"

  # Optional credentials: a KEY=VALUE file bound by Jenkins, or exported by you.
  if [[ -n "${DEPLOY_ENV_FILE:-}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$DEPLOY_ENV_FILE"
    set +a
  fi
}

# managed: true when the cluster type ships Terraform, so this repo creates and
# destroys the cluster. Type "existing" ships none.
managed() { compgen -G "$DRIVER_DIR/*.tf" >/dev/null; }

stack_dir() {
  if [[ "$1" == cluster ]]; then echo "$DRIVER_DIR"; else echo "$ROOT/terraform/bootstrap"; fi
}

# tf <stack> <terraform arguments...>   stack = cluster | bootstrap
tf() {
  local stack="$1"
  shift
  TF_DATA_DIR="$BUILD_DIR/$stack/.terraform" "$TF" -chdir="$(stack_dir "$stack")" "$@"
}

# tf_init <stack>: write the state backend for this cluster and stack, then init.
# Terraform cannot take the backend type from a variable, so the file is generated.
tf_init() {
  local stack="$1" dir
  dir="$(stack_dir "$stack")"
  if [[ "$(cfg '.state.backend // "local"')" == local ]]; then
    [[ -z "${JENKINS_URL:-}" ]] ||
      warn "local Terraform state is lost with the Jenkins workspace; add a state block to config/clusters/$CLUSTER.yaml"
    mkdir -p "$ROOT/.state/$CLUSTER"
    STATE_PATH="$ROOT/.state/$CLUSTER/$stack.tfstate" \
      yq -n -o=json '{"terraform": {"backend": {"local": {"path": strenv(STATE_PATH)}}}}' >"$dir/backend.tf.json"
  else
    yq -o=json '{"terraform": {"backend": {.state.backend: .state.config}}}' "$CONFIG_FILE" |
      sed "s/{stack}/$stack/g" >"$dir/backend.tf.json"
  fi
  tf "$stack" init -input=false -reconfigure
}

# get_kubeconfig: run the driver's kubeconfig.sh, which must write $KUBECONFIG.
get_kubeconfig() { bash "$DRIVER_DIR/kubeconfig.sh"; }
