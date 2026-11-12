k8s-backup-restore.sh is a modular Bash script that backs up and restores Kubernetes Deployments, Services, and their underlying dependencies (ConfigMaps, Secrets, PVCs, ServiceAccounts, Ingresses, and HPAs) by either an entire namespace or a specific service.
Complete Script (k8s-backup-restore.sh)
#!/usr/bin/env bash
# ==============================================================================
# Script Name: k8s-backup-restore.sh
# Description: Modular backup and restore script for Kubernetes Deployments,
#              Services, and their associated dependencies by Namespace or Service.
# Requirements: bash 4+, kubectl, jq (optional: yq for YAML output formatting)
# ==============================================================================

set -euo pipefail

# --- Global Defaults ---
ACTION=""
NAMESPACE=""
SERVICE_NAME=""
BACKUP_ROOT="./k8s-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESTORE_PATH=""
DRY_RUN="false"
OUTPUT_EXT="yaml"

# --- Logging Helpers ---
log_info()  { printf "\033[0;34m[INFO]\033[0m  %s\n" "$*"; }
log_ok()    { printf "\033[0;32m[OK]\033[0m    %s\n" "$*"; }
log_warn()  { printf "\033[0;33m[WARN]\033[0m  %s\n" "$*" >&2; }
log_error() { printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2; }

# --- Usage Documentation ---
usage() {
    cat <<EOF
Usage:
  $(basename "$0") <action> [options]

Actions:
  backup                  Backup resources from the cluster
  restore                 Restore resources into the current cluster context

Options:
  -n, --namespace <name>  Target Kubernetes namespace (Required)
  -s, --service <name>    Specific Service name to backup/restore (Optional: defaults to all in namespace)
  -d, --dir <path>        Base directory for backups or specific backup folder for restore (Default: ./k8s-backups)
      --dry-run           Run restore with --dry-run=server to validate against the cluster without applying
  -h, --help              Display this help message

Examples:
  # Backup an entire namespace
  $(basename "$0") backup -n production -d ./backups

  # Backup a single service, its backing deployment, and all its dependencies
  $(basename "$0") backup -n production -s payment-api -d ./backups

  # Restore an entire namespace from a backup directory
  $(basename "$0") restore -n production -d ./backups/production/all-20261112-120000

  # Restore only a specific service and its dependencies from a backup directory
  $(basename "$0") restore -n production -s payment-api -d ./backups/production/payment-api-20261112-120000
EOF
    exit 1
}

# --- 1. Prerequisite & Cluster Checks ---
check_prerequisites() {
    local missing=0
    for cmd in kubectl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command '$cmd' is not installed."
            missing=1
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        exit 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig and context."
        exit 1
    fi

    if ! command -v yq >/dev/null 2>&1; then
        log_warn "'yq' not found. Manifests will be saved as JSON-formatted YAML (natively supported by kubectl)."
    fi
}

# --- 2. Argument Parsing ---
parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
    fi

    case "$1" in
        backup|restore)
            ACTION="$1"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Invalid action: '$1'. Must be 'backup' or 'restore'."
            usage
            ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--namespace)
                NAMESPACE="${2:-}"
                shift 2
                ;;
            -s|--service)
                SERVICE_NAME="${2:-}"
                shift 2
                ;;
            -d|--dir)
                BACKUP_ROOT="${2:-}"
                RESTORE_PATH="${2:-}"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$NAMESPACE" ]]; then
        log_error "Namespace (-n|--namespace) is required."
        usage
    fi
}

# --- 3. Manifest Sanitization for Existing Clusters ---
# Strips cluster-specific runtime metadata, UIDs, resourceVersions, status blocks,
# and dynamically assigned ClusterIPs so manifests apply cleanly to existing clusters.
sanitize_manifest() {
    jq '
    del(
        .metadata.uid,
        .metadata.resourceVersion,
        .metadata.selfLink,
        .metadata.creationTimestamp,
        .metadata.generation,
        .metadata.managedFields,
        .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
        .metadata.annotations."deployment.kubernetes.io/revision",
        .status
    )
    | if .kind == "Service" then
        if .spec.clusterIP != "None" then
            del(.spec.clusterIP, .spec.clusterIPs)
        else . end
      else . end
    | if .kind == "PersistentVolumeClaim" then
        del(
            .spec.volumeName,
            .metadata.annotations."pv.kubernetes.io/bind-completed",
            .metadata.annotations."pv.kubernetes.io/bound-by-controller"
        )
      else . end
    '
}

# Format output as clean YAML if yq is present, otherwise pretty JSON (valid YAML 1.2)
format_output() {
    if command -v yq >/dev/null 2>&1; then
        yq -P '.'
    else
        cat
    fi
}

# --- 4. Export Single Resource Helper ---
export_resource() {
    local kind="$1"
    local name="$2"
    local out_dir="$3"
    local prefix="$4"

    if [[ -z "$name" || "$name" == "null" ]]; then
        return 0
    fi

    # Skip built-in default ServiceAccount to avoid overwriting cluster defaults
    if [[ "$kind" == "serviceaccount" && "$name" == "default" ]]; then
        return 0
    fi

    local target_file="${out_dir}/${prefix}-${kind}-${name}.${OUTPUT_EXT}"
    if [[ -f "$target_file" ]]; then
        return 0 # Already exported in this session
    fi

    if ! kubectl get "$kind" "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
        log_warn "Referenced $kind '$name' not found in namespace '$NAMESPACE'. Skipping."
        return 0
    fi

    log_info "Exporting $kind/$name..."
    kubectl get "$kind" "$name" -n "$NAMESPACE" -o json \
        | sanitize_manifest \
        | format_output > "$target_file"
}

# --- 5. Dependency Extraction for a Deployment ---
backup_deployment_dependencies() {
    local deploy_name="$1"
    local out_dir="$2"

    local deploy_json
    deploy_json="$(kubectl get deployment "$deploy_name" -n "$NAMESPACE" -o json)"

    # 1. ServiceAccount
    local sa_name
    sa_name="$(echo "$deploy_json" | jq -r '.spec.template.spec.serviceAccountName // empty')"
    if [[ -n "$sa_name" && "$sa_name" != "default" ]]; then
        export_resource "serviceaccount" "$sa_name" "$out_dir" "01"
    fi

    # 2. Secrets (env, envFrom, volumes, imagePullSecrets)
    local secrets
    secrets="$(echo "$deploy_json" | jq -r '
        [
            .spec.template.spec.containers[]?.env[]?.valueFrom.secretKeyRef.name,
            .spec.template.spec.initContainers[]?.env[]?.valueFrom.secretKeyRef.name,
            .spec.template.spec.containers[]?.envFrom[]?.secretRef.name,
            .spec.template.spec.initContainers[]?.envFrom[]?.secretRef.name,
            .spec.template.spec.volumes[]?.secret.secretName,
            .spec.template.spec.imagePullSecrets[]?.name
        ] | flatten | map(select(. != null)) | unique | .[]
    ')"
    for secret in $secrets; do
        export_resource "secret" "$secret" "$out_dir" "02"
    done

    # 3. ConfigMaps (env, envFrom, volumes)
    local configmaps
    configmaps="$(echo "$deploy_json" | jq -r '
        [
            .spec.template.spec.containers[]?.env[]?.valueFrom.configMapKeyRef.name,
            .spec.template.spec.initContainers[]?.env[]?.valueFrom.configMapKeyRef.name,
            .spec.template.spec.containers[]?.envFrom[]?.configMapRef.name,
            .spec.template.spec.initContainers[]?.envFrom[]?.configMapRef.name,
            .spec.template.spec.volumes[]?.configMap.name
        ] | flatten | map(select(. != null)) | unique | .[]
    ')"
    for cm in $configmaps; do
        export_resource "configmap" "$cm" "$out_dir" "03"
    done

    # 4. PersistentVolumeClaims (volumes)
    local pvcs
    pvcs="$(echo "$deploy_json" | jq -r '
        [
            .spec.template.spec.volumes[]?.persistentVolumeClaim.claimName
        ] | flatten | map(select(. != null)) | unique | .[]
    ')"
    for pvc in $pvcs; do
        export_resource "pvc" "$pvc" "$out_dir" "04"
    done

    # 5. Export the Deployment itself
    export_resource "deployment" "$deploy_name" "$out_dir" "05"

    # 6. HorizontalPodAutoscalers targeting this Deployment
    local hpas
    hpas="$(kubectl get hpa -n "$NAMESPACE" -o json | jq -r --arg DEP "$deploy_name" '
        .items[] | select(.spec.scaleTargetRef.kind == "Deployment" and .spec.scaleTargetRef.name == $DEP) | .metadata.name
    ')"
    for hpa in $hpas; do
        export_resource "hpa" "$hpa" "$out_dir" "07"
    done
}

# --- 6. Discover Backing Deployments for a Service ---
find_deployments_for_service() {
    local svc_name="$1"
    local svc_json
    svc_json="$(kubectl get service "$svc_name" -n "$NAMESPACE" -o json)"

    # Build a comma-separated label selector from Service .spec.selector
    local selector
    selector="$(echo "$svc_json" | jq -r '
        .spec.selector // {} | to_entries | map("\(.key)=\(.value)") | join(",")
    ')"

    local matched_deployments=""
    if [[ -n "$selector" ]]; then
        # Match Deployments whose pod template labels contain all Service selector key-values
        matched_deployments="$(kubectl get deployments -n "$NAMESPACE" -o json | jq -r --argjson SEL "$(echo "$svc_json" | jq '.spec.selector')" '
            .items[]
            | select(.spec.template.metadata.labels != null)
            | select(.spec.template.metadata.labels | contains($SEL))
            | .metadata.name
        ')"
    fi

    # Fallback: check if a Deployment with the exact same name as the Service exists
    if [[ -z "$matched_deployments" ]]; then
        if kubectl get deployment "$svc_name" -n "$NAMESPACE" >/dev/null 2>&1; then
            matched_deployments="$svc_name"
        fi
    fi

    echo "$matched_deployments"
}

# --- 7. Backup by Specific Service ---
backup_by_service() {
    local out_dir="$1"

    if ! kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        log_error "Service '$SERVICE_NAME' does not exist in namespace '$NAMESPACE'."
        exit 1
    fi

    log_info "Starting targeted backup for Service '$SERVICE_NAME' in namespace '$NAMESPACE'..."

    # Export the Service
    export_resource "service" "$SERVICE_NAME" "$out_dir" "06"

    # Find and export backing Deployments + their dependencies
    local deployments
    deployments="$(find_deployments_for_service "$SERVICE_NAME")"

    if [[ -z "$deployments" ]]; then
        log_warn "No matching Deployment found for Service '$SERVICE_NAME'. Only the Service was backed up."
    else
        for deploy in $deployments; do
            log_info "Discovered backing Deployment '$deploy' for Service '$SERVICE_NAME'."
            backup_deployment_dependencies "$deploy" "$out_dir"
        done
    fi

    # Find and export Ingresses routing to this Service
    local ingresses
    ingresses="$(kubectl get ingress -n "$NAMESPACE" -o json 2>/dev/null | jq -r --arg SVC "$SERVICE_NAME" '
        .items[]
        | select(.spec.rules[]?.http.paths[]?.backend.service.name == $SVC)
        | .metadata.name
    ' | sort -u)"
    for ing in $ingresses; do
        export_resource "ingress" "$ing" "$out_dir" "08"
    done
}

# --- 8. Backup Entire Namespace ---
backup_by_namespace() {
    local out_dir="$1"
    log_info "Starting full namespace backup for '$NAMESPACE'..."

    # Export all Deployments and their direct dependencies
    local deployments
    deployments="$(kubectl get deployments -n "$NAMESPACE" -o json | jq -r '.items[].metadata.name')"
    for deploy in $deployments; do
        backup_deployment_dependencies "$deploy" "$out_dir"
    done

    # Export all Services (excluding the default 'kubernetes' service in default ns)
    local services
    services="$(kubectl get services -n "$NAMESPACE" -o json | jq -r '.items[] | select(.metadata.name != "kubernetes") | .metadata.name')"
    for svc in $services; do
        export_resource "service" "$svc" "$out_dir" "06"
    done

    # Export standalone ConfigMaps (skip kube-root-ca.crt)
    local cms
    cms="$(kubectl get configmaps -n "$NAMESPACE" -o json | jq -r '.items[] | select(.metadata.name != "kube-root-ca.crt") | .metadata.name')"
    for cm in $cms; do
        export_resource "configmap" "$cm" "$out_dir" "03"
    done

    # Export standalone Opaque/TLS/DockerConfig Secrets (skip helm release state & legacy SA tokens)
    local secrets
    secrets="$(kubectl get secrets -n "$NAMESPACE" -o json | jq -r '
        .items[]
        | select(.type != "kubernetes.io/service-account-token" and (.type | startswith("helm.sh/") | not))
        | .metadata.name
    ')"
    for sec in $secrets; do
        export_resource "secret" "$sec" "$out_dir" "02"
    done

    # Export all Ingresses
    local ingresses
    ingresses="$(kubectl get ingress -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[].metadata.name')"
    for ing in $ingresses; do
        export_resource "ingress" "$ing" "$out_dir" "08"
    done
}

# --- 9. Master Backup Coordinator ---
run_backup() {
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        log_error "Namespace '$NAMESPACE' does not exist in the current cluster."
        exit 1
    fi

    local scope_label="${SERVICE_NAME:-all}"
    local target_dir="${BACKUP_ROOT}/${NAMESPACE}/${scope_label}-${TIMESTAMP}"
    mkdir -p "$target_dir"

    if [[ -n "$SERVICE_NAME" ]]; then
        backup_by_service "$target_dir"
    else
        backup_by_namespace "$target_dir"
    fi

    log_ok "Backup completed successfully. Files saved to: $target_dir"
}

# --- 10. Restore Coordinator ---
run_restore() {
    if [[ -z "$RESTORE_PATH" || ! -d "$RESTORE_PATH" ]]; then
        log_error "Valid backup directory (-d|--dir) must be specified for restore."
        exit 1
    fi

    log_info "Starting restore into namespace '$NAMESPACE' from '$RESTORE_PATH'..."

    # Ensure target namespace exists on the cluster
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create missing namespace '$NAMESPACE'."
        else
            log_info "Creating missing namespace '$NAMESPACE'..."
            kubectl create namespace "$NAMESPACE"
        fi
    fi

    local apply_flags=("-n" "$NAMESPACE")
    if [[ "$DRY_RUN" == "true" ]]; then
        apply_flags+=("--dry-run=server")
        log_warn "Running in SERVER DRY-RUN mode. No resources will be persisted."
    fi

    shopt -s nullglob
    local files=("$RESTORE_PATH"/*.{yaml,json})
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        log_error "No manifest files found in '$RESTORE_PATH'."
        exit 1
    fi

    # If --service is specified during restore from a full-namespace backup,
    # filter which files to restore by inspecting the Service and its Deployment dependencies.
    local allowed_files=()
    if [[ -n "$SERVICE_NAME" ]]; then
        log_info "Filtering restore in '$RESTORE_PATH' for service '$SERVICE_NAME' and its dependencies..."
        allowed_files=($(filter_restore_files_for_service "$RESTORE_PATH" "$SERVICE_NAME"))
        if [[ ${#allowed_files[@]} -eq 0 ]]; then
            log_error "Could not find Service '$SERVICE_NAME' in backup directory '$RESTORE_PATH'."
            exit 1
        fi
    else
        allowed_files=("${files[@]}")
    fi

    # Files are prefixed with 01..08 so lexical sorting guarantees dependency order:
    # 01-serviceaccount -> 02-secret -> 03-configmap -> 04-pvc -> 05-deployment -> 06-service -> 07-hpa -> 08-ingress
    IFS=$'\n' sorted_files=($(sort <<<"${allowed_files[*]}"))
    unset IFS

    local restored_deployments=()

    for file in "${sorted_files[@]}"; do
        local kind name
        kind="$(jq -r '.kind' < <(yq -o=json '.' "$file" 2>/dev/null || cat "$file"))"
        name="$(jq -r '.metadata.name' < <(yq -o=json '.' "$file" 2>/dev/null || cat "$file"))"

        log_info "Applying ${kind}/${name} from $(basename "$file")..."
        # Override metadata.namespace to support restoring into a renamed/existing namespace
        if command -v yq >/dev/null 2>&1; then
            yq -o=json '.' "$file" | jq --arg NS "$NAMESPACE" '.metadata.namespace = $NS' | kubectl apply "${apply_flags[@]}" -f -
        else
            jq --arg NS "$NAMESPACE" '.metadata.namespace = $NS' "$file" | kubectl apply "${apply_flags[@]}" -f -
        fi

        if [[ "$kind" == "Deployment" ]]; then
            restored_deployments+=("$name")
        fi
    done

    # Verify rollout status for restored deployments
    if [[ "$DRY_RUN" == "false" && ${#restored_deployments[@]} -gt 0 ]]; then
        for deploy in "${restored_deployments[@]}"; do
            log_info "Waiting for Deployment '$deploy' rollout to complete..."
            kubectl rollout status deployment/"$deploy" -n "$NAMESPACE" --timeout=120s || \
                log_warn "Rollout for Deployment '$deploy' did not complete within 120s."
        done
    fi

    log_ok "Restore operation completed for namespace '$NAMESPACE'."
}

# --- 11. Helper: Filter a Full Backup Directory by Service Name on Restore ---
filter_restore_files_for_service() {
    local dir="$1"
    local svc="$2"
    local matched=()

    shopt -s nullglob
    local all_files=("$dir"/*.{yaml,json})
    shopt -u nullglob

    # Locate the Service file
    local svc_file=""
    for f in "${all_files[@]}"; do
        if [[ "$(basename "$f")" == "06-service-${svc}."* ]]; then
            svc_file="$f"
            matched+=("$f")
            break
        fi
    done

    if [[ -z "$svc_file" ]]; then
        return 0
    fi

    local svc_json
    svc_json="$(yq -o=json '.' "$svc_file" 2>/dev/null || cat "$svc_file")"

    # Match Deployments in the backup directory whose labels satisfy the Service selector
    for f in "${all_files[@]}"; do
        if [[ "$(basename "$f")" == 05-deployment-* ]]; then
            local dep_json
            dep_json="$(yq -o=json '.' "$f" 2>/dev/null || cat "$f")"
            local is_match
            is_match="$(jq -n --argjson SVC "$svc_json" --argjson DEP "$dep_json" '
                if ($SVC.spec.selector != null and $DEP.spec.template.metadata.labels != null) then
                    ($DEP.spec.template.metadata.labels | contains($SVC.spec.selector))
                elif ($SVC.metadata.name == $DEP.metadata.name) then
                    true
                else
                    false
                end
            ')"

            if [[ "$is_match" == "true" ]]; then
                matched+=("$f")
                # Extract dependency names from this Deployment manifest
                local deps
                deps="$(echo "$dep_json" | jq -r '
                    [
                        ("01-serviceaccount-" + (.spec.template.spec.serviceAccountName // "")),
                        (.spec.template.spec.containers[]?.env[]?.valueFrom.secretKeyRef.name | select(. != null) | "02-secret-" + .),
                        (.spec.template.spec.containers[]?.envFrom[]?.secretRef.name | select(. != null) | "02-secret-" + .),
                        (.spec.template.spec.volumes[]?.secret.secretName | select(. != null) | "02-secret-" + .),
                        (.spec.template.spec.imagePullSecrets[]?.name | select(. != null) | "02-secret-" + .),
                        (.spec.template.spec.containers[]?.env[]?.valueFrom.configMapKeyRef.name | select(. != null) | "03-configmap-" + .),
                        (.spec.template.spec.containers[]?.envFrom[]?.configMapRef.name | select(. != null) | "03-configmap-" + .),
                        (.spec.template.spec.volumes[]?.configMap.name | select(. != null) | "03-configmap-" + .),
                        (.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName | select(. != null) | "04-pvc-" + .)
                    ] | flatten | unique | .[]
                ')"
                for prefix_name in $deps; do
                    for df in "${all_files[@]}"; do
                        if [[ "$(basename "$df")" == "${prefix_name}."* ]]; then
                            matched+=("$df")
                        fi
                    done
                done
            fi
        fi
    done

    printf "%s\n" "${matched[@]}" | sort -u
}

# --- Main Execution ---
main() {
    parse_args "$@"
    check_prerequisites

    case "$ACTION" in
        backup)
            run_backup
            ;;
        restore)
            run_restore
            ;;
    esac
}

main "$@"

How the Functions Are Structured
| Function | Responsibility |
|---|---|
| check_prerequisites | Verifies kubectl and jq are installed and validates active cluster connectivity. Uses yq if present, or falls back to JSON-formatted YAML (valid YAML 1.2). |
| sanitize_manifest | Strips cluster-specific state (uid, resourceVersion, managedFields, status, PVC bindings, and dynamic clusterIP addresses while preserving headless clusterIP: None services) so resources apply cleanly into an existing cluster. |
| find_deployments_for_service | Inspects the Service's .spec.selector and matches it against .spec.template.metadata.labels of Deployments in the namespace (falling back to name matching). |
| backup_deployment_dependencies | Parses the Deployment spec to discover and export every referenced ServiceAccount, Secret (env, envFrom, volumes, imagePullSecrets), ConfigMap, PersistentVolumeClaim, and targeting HorizontalPodAutoscaler. |
| backup_by_service / backup_by_namespace | Handles scoping—either walking the dependency graph of a single Service or exporting all workloads and configurations across the namespace. |
| run_restore & filter_restore_files_for_service | Restores manifests in strict dependency order (01-serviceaccount through 08-ingress). Also supports restoring a single service (-s) out of a full-namespace backup folder and re-targeting to a different existing namespace (-n). |
Quick Usage Examples
 * Make the script executable:
   chmod +x k8s-backup-restore.sh

 * Backup a single service and everything it needs:
   ./k8s-backup-restore.sh backup -n devspaces -s spring-demo -d ./backups

 * Backup an entire namespace:
   ./k8s-backup-restore.sh backup -n devspaces -d ./backups

 * Dry-run test a restore against an existing cluster:
   ./k8s-backup-restore.sh restore -n devspaces -s spring-demo -d ./backups/devspaces/spring-demo-20261112-061200 --dry-run

 * Execute the live restore (even into a different target namespace):
   ./k8s-backup-restore.sh restore -n devspaces-staging -s spring-demo -d ./backups/devspaces/all-20261112-061200

