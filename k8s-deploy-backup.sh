#!/usr/bin/env bash
# k8s-deploy-backup.sh
# Backup and restore a Kubernetes Deployment + Service by namespace and name.
# Uses functions for separation of concerns.
# Saves cleaned YAML suitable for re-applying to an existing cluster.
#
# Requirements: kubectl (configured for the target cluster), bash 4+
# Optional: yq (for cleaner YAML; falls back to sed/awk if missing)
#
# Usage:
#   Backup:
#     ./k8s-deploy-backup.sh backup --namespace <ns> --name <deploy-or-svc-name> [--output-dir ./backups]
#
#   Restore:
#     ./k8s-deploy-backup.sh restore --namespace <ns> --name <deploy-or-svc-name> --backup-dir ./backups/<ns>-<name>
#
# Examples:
#   ./k8s-deploy-backup.sh backup -n production -d myapp --output-dir ./backups
#   ./k8s-deploy-backup.sh restore -n production -d myapp --backup-dir ./backups/production-myapp

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration & helpers
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
DEFAULT_OUTPUT_DIR="./k8s-backups"
REQUIRED_CMDS=(kubectl)

# Colors (optional, for nicer output)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <command> [options]

Commands:
  backup    Backup Deployment + Service (and related ConfigMaps/Secrets if present)
  restore   Restore Deployment + Service from a previous backup directory

Common options:
  -n, --namespace <ns>     Kubernetes namespace (required)
  -d, --name <name>        Name of the Deployment / Service (required; assumes same name)
  --output-dir <dir>       Where to write backups (default: $DEFAULT_OUTPUT_DIR)
  --backup-dir <dir>       Directory containing a previous backup (required for restore)

Examples:
  $SCRIPT_NAME backup -n apps -d webapp --output-dir ./backups
  $SCRIPT_NAME restore -n apps -d webapp --backup-dir ./backups/apps-webapp

Notes:
  - Deployment and Service are expected to share the same name.
  - YAML is cleaned (status, resourceVersion, uid, managedFields, etc. removed)
    so it can be applied cleanly with kubectl apply.
  - Related ConfigMaps and Secrets referenced by the Deployment are also backed up
    when detected (best-effort).
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

check_prerequisites() {
  for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Required command not found: $cmd"
    fi
  done

  # Verify kubectl can talk to a cluster
  if ! kubectl cluster-info >/dev/null 2>&1; then
    error "kubectl cannot reach a cluster. Check your context / kubeconfig."
  fi

  log "Prerequisites OK (kubectl reachable)"
}

# ---------------------------------------------------------------------------
# YAML cleaning
# ---------------------------------------------------------------------------

# Prefer yq when available (much cleaner). Fallback to sed.
clean_yaml() {
  local input_file="$1"
  local output_file="$2"

  if command -v yq >/dev/null 2>&1; then
    # Remove fields that prevent clean re-application
    yq eval '
      del(
        .metadata.resourceVersion,
        .metadata.uid,
        .metadata.generation,
        .metadata.creationTimestamp,
        .metadata.managedFields,
        .metadata.selfLink,
        .status,
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .metadata.annotations["deployment.kubernetes.io/revision"],
        .metadata.annotations["kubernetes.io/change-cause"]
      )
    ' "$input_file" > "$output_file"
  else
    # Portable fallback (sed/awk). Not perfect but works for most cases.
    sed -E \
      -e '/^  resourceVersion:/d' \
      -e '/^  uid:/d' \
      -e '/^  generation:/d' \
      -e '/^  creationTimestamp:/d' \
      -e '/^  selfLink:/d' \
      -e '/^status:/,/^[a-zA-Z]/ { /^status:/d; /^[a-zA-Z]/!d; }' \
      -e '/managedFields:/,/^  [a-zA-Z][^:]/d' \
      -e '/kubectl.kubernetes.io\/last-applied-configuration:/d' \
      -e '/deployment.kubernetes.io\/revision:/d' \
      "$input_file" > "$output_file"
  fi

  # Ensure the file is not empty
  if [[ ! -s "$output_file" ]]; then
    error "Cleaned YAML is empty for $input_file"
  fi
}

# ---------------------------------------------------------------------------
# Backup functions
# ---------------------------------------------------------------------------

backup_resource() {
  local kind="$1"          # deployment | service | configmap | secret
  local ns="$2"
  local name="$3"
  local dest_dir="$4"

  local raw_file="${dest_dir}/${kind}-${name}.raw.yaml"
  local clean_file="${dest_dir}/${kind}-${name}.yaml"

  log "Backing up ${kind}/${name} in namespace ${ns}..."

  if ! kubectl get "$kind" "$name" -n "$ns" -o yaml > "$raw_file" 2>/dev/null; then
    warn "Resource ${kind}/${name} not found in namespace ${ns} — skipping"
    return 1
  fi

  clean_yaml "$raw_file" "$clean_file"
  rm -f "$raw_file"
  log "  → saved ${clean_file}"
  return 0
}

# Best-effort: extract referenced ConfigMaps and Secrets from a Deployment
backup_related_resources() {
  local ns="$1"
  local deploy_name="$2"
  local dest_dir="$3"

  local deploy_yaml="${dest_dir}/deployment-${deploy_name}.yaml"
  [[ -f "$deploy_yaml" ]] || return 0

  # Extract configMapRef / secretRef names (simple grep; works for most cases)
  local cms secrets
  cms=$(grep -E 'name:.*' "$deploy_yaml" | grep -i configmap | awk '{print $2}' | sort -u || true)
  secrets=$(grep -E 'name:.*' "$deploy_yaml" | grep -i secret | awk '{print $2}' | sort -u || true)

  for cm in $cms; do
    [[ -n "$cm" ]] && backup_resource configmap "$ns" "$cm" "$dest_dir" || true
  done

  for secret in $secrets; do
    [[ -n "$secret" ]] && backup_resource secret "$ns" "$secret" "$dest_dir" || true
  done
}

backup_deployment_and_service() {
  local ns="$1"
  local name="$2"
  local output_dir="$3"

  local dest_dir="${output_dir}/${ns}-${name}"
  mkdir -p "$dest_dir"

  log "Creating backup directory: $dest_dir"

  # Core resources
  backup_resource deployment "$ns" "$name" "$dest_dir" || error "Deployment ${name} not found"
  backup_resource service     "$ns" "$name" "$dest_dir" || warn "Service ${name} not found (continuing)"

  # Related ConfigMaps / Secrets (best effort)
  backup_related_resources "$ns" "$name" "$dest_dir"

  # Metadata file for easy identification
  cat > "${dest_dir}/BACKUP-INFO.txt" <<EOF
Backup created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Namespace: ${ns}
Name: ${name}
Cluster context: $(kubectl config current-context 2>/dev/null || echo "unknown")
EOF

  log "Backup complete: $dest_dir"
  echo "$dest_dir"
}

# ---------------------------------------------------------------------------
# Restore functions
# ---------------------------------------------------------------------------

restore_from_directory() {
  local ns="$1"
  local name="$2"
  local backup_dir="$3"

  if [[ ! -d "$backup_dir" ]]; then
    error "Backup directory not found: $backup_dir"
  fi

  log "Restoring from $backup_dir into namespace $ns (name=$name)"

  # Ensure namespace exists
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    log "Namespace $ns does not exist — creating it"
    kubectl create namespace "$ns"
  fi

  # Apply in a sensible order: ConfigMaps/Secrets first, then Service, then Deployment
  local files=(
    "${backup_dir}"/configmap-*.yaml
    "${backup_dir}"/secret-*.yaml
    "${backup_dir}/service-${name}.yaml"
    "${backup_dir}/deployment-${name}.yaml"
  )

  local applied=0
  for pattern in "${files[@]}"; do
    # shellcheck disable=SC2086
    for f in $pattern; do
      if [[ -f "$f" ]]; then
        log "Applying $f"
        kubectl apply -f "$f" -n "$ns"
        applied=$((applied + 1))
      fi
    done
  done

  if [[ $applied -eq 0 ]]; then
    error "No YAML files found to apply in $backup_dir"
  fi

  log "Restore finished. Applied $applied resource(s)."
  log "Check status with:"
  echo "  kubectl get deploy,svc -n $ns | grep $name"
  echo "  kubectl rollout status deployment/$name -n $ns"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

COMMAND=""
NAMESPACE=""
NAME=""
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
BACKUP_DIR=""

parse_args() {
  if [[ $# -lt 1 ]]; then
    usage
  fi

  COMMAND="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        NAMESPACE="$2"; shift 2 ;;
      -d|--name)
        NAME="$2"; shift 2 ;;
      --output-dir)
        OUTPUT_DIR="$2"; shift 2 ;;
      --backup-dir)
        BACKUP_DIR="$2"; shift 2 ;;
      -h|--help)
        usage ;;
      *)
        error "Unknown option: $1" ;;
    esac
  done

  [[ -n "$NAMESPACE" ]] || error "Missing --namespace"
  [[ -n "$NAME" ]]      || error "Missing --name"

  case "$COMMAND" in
    backup|restore) ;;
    *) error "Unknown command: $COMMAND (expected backup or restore)" ;;
  esac

  if [[ "$COMMAND" == "restore" && -z "$BACKUP_DIR" ]]; then
    error "restore requires --backup-dir"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  check_prerequisites

  case "$COMMAND" in
    backup)
      backup_deployment_and_service "$NAMESPACE" "$NAME" "$OUTPUT_DIR"
      ;;
    restore)
      restore_from_directory "$NAMESPACE" "$NAME" "$BACKUP_DIR"
      ;;
  esac
}

main "$@"
