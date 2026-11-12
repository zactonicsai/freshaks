#!/usr/bin/env bash
# ==============================================================================
# k8s-backup.sh - back up and restore Kubernetes Deployments and Services
#
# Saves everything needed to bring an application back in an existing cluster:
#   - Services and the workloads behind them (Deployments, StatefulSets,
#     DaemonSets)
#   - what their pods use: ConfigMaps, Secrets, PVC definitions, ServiceAccounts
#     (with their image pull secrets, Roles and RoleBindings)
#   - what points at them: Ingresses (with TLS secrets), Gateway API HTTPRoutes,
#     HorizontalPodAutoscalers, PodDisruptionBudgets, NetworkPolicies
#   - hand-made Endpoints / EndpointSlices of Services that have no selector
#   - the Namespace definition (labels and annotations)
#
# Scope:
#   -n NAMESPACE               every object of the kinds above in the namespace
#   -n NAMESPACE -s SERVICE    one Service and only the objects it depends on
#
# A namespace backup also records, per Service, which objects that Service
# depends on, so one Service can be restored out of a namespace backup with -s.
#
# NOT included: the data inside volumes (use volume snapshots or Velero),
# cluster-scoped objects (ClusterRoles, StorageClasses, IngressClasses, CRDs,
# PersistentVolumes) and custom resources.
#
# Backups hold Secrets in readable form (base64). Every file is created private
# to the current user; encrypt backups before copying them anywhere else.
#
# Restore uses "kubectl apply": objects that are missing are created, objects
# that exist are set back to the saved values. Something added to a live object
# after the backup (an extra env var, an extra ConfigMap key) is not always
# removed; delete the object before restoring when it must match exactly.
#
# Manifests are stored as JSON, one object per file, which "kubectl apply -f"
# accepts directly.
#
# Requires: bash, kubectl, jq 1.5+ (and tar for --archive / .tar.gz)
# ==============================================================================

set -euo pipefail
umask 077

SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME
readonly TOOL_VERSION="1.0"

# Kinds this script handles, in the order they are restored: identity and
# configuration first, then storage, Services, workloads, and finally the
# objects that point at Services and workloads. A namespaced kind added here
# (for example cronjobs) is picked up by namespace backups and restores.
readonly RESOURCE_KINDS="serviceaccounts roles rolebindings secrets configmaps persistentvolumeclaims services endpoints endpointslices deployments statefulsets daemonsets horizontalpodautoscalers poddisruptionbudgets ingresses httproutes networkpolicies"
readonly WORKLOAD_KINDS="deployments statefulsets daemonsets"

# ---- options (set by parse_args) ---------------------------------------------
COMMAND=""
NAMESPACE=""                                   # backup: source, restore: target
SERVICE=""
BACKUP_ROOT="${K8S_BACKUP_DIR:-./k8s-backups}"
BACKUP_SRC=""                                  # restore: directory or .tar.gz
KUBE_CONTEXT=""
INCLUDE_SECRETS=true
ARCHIVE=false
DRY_RUN=false
WAIT_READY=true
TIMEOUT=180
ASSUME_YES=false

# ---- run state ---------------------------------------------------------------
WORK_DIR=""          # private scratch directory, removed on exit
CACHE_DIR=""         # raw "kubectl get" output, one file per kind
BACKUP_DIR=""        # backup being written or read
FINAL_DIR=""         # where a finished backup ends up
PARTIAL=""           # unfinished output, removed if the run fails
CLUSTER_VERSION=""
SOURCE_NS=""         # restore: namespace the backup was taken from
TARGET_NS=""         # restore: namespace being restored into
DRY_RUN_FLAG=""
WARNINGS=0
APPLIED=0
FAILED=0
NOT_READY=0

# ==============================================================================
# jq programs (single-quoted: keep apostrophes out of them)
# ==============================================================================

# Remove everything the cluster assigned, so a manifest applies to any cluster.
# shellcheck disable=SC2016
readonly JQ_SANITIZE='
def drop_annotations($names):
  if (.metadata.annotations | type) == "object" then
    .metadata.annotations |= with_entries(select(.key as $k | any($names[]; . == $k) | not))
    | if .metadata.annotations == {} then del(.metadata.annotations) else . end
  else . end;

def sanitize:
  del(.status,
      .metadata.uid, .metadata.resourceVersion, .metadata.generation,
      .metadata.creationTimestamp, .metadata.deletionTimestamp,
      .metadata.deletionGracePeriodSeconds, .metadata.selfLink,
      .metadata.managedFields, .metadata.ownerReferences)
  | drop_annotations(["kubectl.kubernetes.io/last-applied-configuration",
                      "deployment.kubernetes.io/revision"])
  | if .kind == "Service" then
      # keep "None" (headless Service); otherwise the target cluster picks the IP
      if .spec.clusterIP == "None" then . else del(.spec.clusterIP, .spec.clusterIPs) end
    elif .kind == "PersistentVolumeClaim" then
      # drop the binding to the old volume so a new one can be provisioned
      del(.spec.volumeName)
      | drop_annotations(["pv.kubernetes.io/bind-completed",
                          "pv.kubernetes.io/bound-by-controller",
                          "volume.beta.kubernetes.io/storage-provisioner",
                          "volume.kubernetes.io/storage-provisioner",
                          "volume.kubernetes.io/selected-node"])
    elif .kind == "ServiceAccount" then
      del(.secrets)
    elif .kind == "Secret" and .type == "kubernetes.io/service-account-token" then
      # a token only works in the cluster that issued it; the target re-issues it
      del(.data) | drop_annotations(["kubernetes.io/service-account.uid"])
    elif .kind == "Namespace" then
      del(.spec) | del(.metadata.labels["kubernetes.io/metadata.name"])
    else . end;
'

# Kubernetes label selector matching (matchLabels and matchExpressions).
# shellcheck disable=SC2016
readonly JQ_SELECTORS='
def selects($labels):
  ((.matchLabels // {}) | to_entries | all(.value == $labels[.key]))
  and ((.matchExpressions // []) | all(
        .key as $k | (.values // []) as $v
        | if   .operator == "In"           then ($labels | has($k)) and any($v[]; . == $labels[$k])
          elif .operator == "NotIn"        then (($labels | has($k)) and any($v[]; . == $labels[$k])) | not
          elif .operator == "Exists"       then $labels | has($k)
          elif .operator == "DoesNotExist" then $labels | has($k) | not
          else false end));
'

# Point a saved manifest at the namespace being restored into. Only the object
# namespace and RoleBinding subjects are rewritten; a namespace name written
# inside application config (for example a DNS name in a ConfigMap) is not.
# shellcheck disable=SC2016
readonly JQ_RETARGET='
.metadata.namespace = $ns
| if .kind == "RoleBinding" and (.subjects | type) == "array" then
    .subjects |= map(if .kind == "ServiceAccount" and (.namespace // $src) == $src
                     then .namespace = $ns else . end)
  else . end
'

# ==============================================================================
# General helpers
# ==============================================================================

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Log a message that may span several lines, indented by two spaces.
log_indented() {
  local newline=$'\n'
  log "  ${1//$newline/$newline  }"
}

usage() {
  cat <<EOF
$SCRIPT_NAME $TOOL_VERSION - back up and restore Kubernetes Deployments and Services

Usage:
  $SCRIPT_NAME backup  -n NAMESPACE [-s SERVICE] [options]
  $SCRIPT_NAME restore -f BACKUP    [-s SERVICE] [-n NAMESPACE] [options]
  $SCRIPT_NAME list    [-d DIR]

Backup options:
  -n, --namespace NS   namespace to back up (required)
  -s, --service NAME   back up only this Service and what it depends on
  -d, --dir DIR        where backups are kept (default: ./k8s-backups,
                       or \$K8S_BACKUP_DIR)
      --no-secrets     do not save Secrets
      --archive        pack the finished backup into one .tar.gz file

Restore options:
  -f, --from BACKUP    backup directory or .tar.gz file (required)
  -s, --service NAME   restore only this Service and what it depends on
  -n, --namespace NS   restore into this namespace (default: the namespace
                       the backup was taken from)
      --dry-run        show what would change without changing anything
      --no-wait        do not wait for restored workloads to become ready
      --timeout SECS   how long to wait for each workload (default: 180)
  -y, --yes            do not ask for confirmation

Common options:
      --context NAME   kubectl context to use (default: current context)
  -h, --help           show this help

Examples:
  $SCRIPT_NAME backup  -n shop                  # the whole namespace
  $SCRIPT_NAME backup  -n shop -s web           # one Service and its dependencies
  $SCRIPT_NAME list
  $SCRIPT_NAME restore -f ./k8s-backups/shop/namespace/20260101T120000Z
  $SCRIPT_NAME restore -f ./k8s-backups/shop/namespace/20260101T120000Z -s web
  $SCRIPT_NAME restore -f shop.tar.gz -n shop-staging --context staging --dry-run
EOF
}

cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  [[ -z "$PARTIAL" ]] || rm -rf "$PARTIAL"
}

# kubectl against the selected context
kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

# Fully qualified resource name for kubectl, so a CRD with the same plural name
# can never be picked up by mistake.
kind_resource() {
  case "$1" in
    roles|rolebindings)                  echo "$1.rbac.authorization.k8s.io" ;;
    deployments|statefulsets|daemonsets) echo "$1.apps" ;;
    horizontalpodautoscalers)            echo "$1.autoscaling" ;;
    poddisruptionbudgets)                echo "$1.policy" ;;
    ingresses|networkpolicies)           echo "$1.networking.k8s.io" ;;
    httproutes)                          echo "$1.gateway.networking.k8s.io" ;;
    endpointslices)                      echo "$1.discovery.k8s.io" ;;
    *)                                   echo "$1" ;;
  esac
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but was not found in PATH"
  done
}

# Names end up in file paths, so only accept what Kubernetes itself accepts.
validate_name() {
  local what="$1" value="$2" pattern='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'
  [[ "$value" =~ $pattern ]] || die "Invalid $what name: '$value'"
}

need_value() {
  [[ $# -ge 2 && "$2" != -* ]] || die "Option $1 needs a value"
}

init_work_dir() {
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/k8s-backup.XXXXXX")
  CACHE_DIR="$WORK_DIR/cache"
  mkdir "$CACHE_DIR"
  : > "$WORK_DIR/optional.refs"   # references the pod spec marks as optional
  : > "$WORK_DIR/reported.refs"   # missing objects already warned about
}

# Make sure the cluster answers before doing anything else.
connect_cluster() {
  local version
  if [[ -z "$KUBE_CONTEXT" ]]; then
    KUBE_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
  fi
  version=$(kc get --raw /version --request-timeout=20s 2>/dev/null) ||
    die "Cannot reach the cluster (context: ${KUBE_CONTEXT:-kubectl default}). Try 'kubectl cluster-info'."
  CLUSTER_VERSION=$(jq -r '.gitVersion // "unknown"' <<<"$version")
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi
  COMMAND="$1"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace) need_value "$@"; NAMESPACE="$2"; shift 2 ;;
      -s|--service)   need_value "$@"; SERVICE="$2"; shift 2 ;;
      -d|--dir)       need_value "$@"; BACKUP_ROOT="$2"; shift 2 ;;
      -f|--from)      need_value "$@"; BACKUP_SRC="$2"; shift 2 ;;
      --context)      need_value "$@"; KUBE_CONTEXT="$2"; shift 2 ;;
      --timeout)      need_value "$@"; TIMEOUT="$2"; shift 2 ;;
      --no-secrets)   INCLUDE_SECRETS=false; shift ;;
      --archive)      ARCHIVE=true; shift ;;
      --dry-run)      DRY_RUN=true; shift ;;
      --no-wait)      WAIT_READY=false; shift ;;
      -y|--yes)       ASSUME_YES=true; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "Unknown option '$1' (see '$SCRIPT_NAME --help')" ;;
    esac
  done
  [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout needs a number of seconds"
}

# ==============================================================================
# Backup, part 1: read the namespace
# ==============================================================================

# Listing a namespace that does not exist returns nothing rather than an error,
# so a mistyped name must be caught here or it would give an empty "backup".
check_namespace_exists() {
  local err
  if ! err=$(kc get namespace "$NAMESPACE" 2>&1 > /dev/null) && [[ "$err" == *NotFound* ]]; then
    die "Namespace '$NAMESPACE' was not found (context: ${KUBE_CONTEXT:-kubectl default})"
  fi
}

# Fetch every handled kind once. All later steps work from these files, so the
# backup is one consistent read and needs few API calls.
snapshot_namespace() {
  local kind err="$WORK_DIR/kubectl.err"
  log "Reading namespace '$NAMESPACE' (context: ${KUBE_CONTEXT:-kubectl default}, $CLUSTER_VERSION)"
  for kind in $RESOURCE_KINDS; do
    echo '{"items":[]}' > "$CACHE_DIR/$kind.json"
    if [[ "$kind" == secrets && "$INCLUDE_SECRETS" != true ]]; then
      continue
    fi
    if kc get "$(kind_resource "$kind")" -n "$NAMESPACE" -o json > "$CACHE_DIR/$kind.tmp" 2> "$err"; then
      mv "$CACHE_DIR/$kind.tmp" "$CACHE_DIR/$kind.json"
    elif grep -q "doesn't have a resource type" "$err"; then
      log "  $kind: not available on this cluster, skipped"
    else
      # An unreadable kind would make the backup silently incomplete: stop.
      die "Could not read $kind in namespace '$NAMESPACE': $(head -n 1 "$err")"
    fi
  done
  prune_snapshot
}

# Keep only the objects of kind $1 that pass the jq test $2. $3 is optional
# JSON that the test can use as $names.
filter_snapshot() {
  jq --argjson names "${3:-[]}" ".items |= map(select($2))" "$CACHE_DIR/$1.json" > "$CACHE_DIR/$1.tmp"
  mv "$CACHE_DIR/$1.tmp" "$CACHE_DIR/$1.json"
}

# Drop from what was read the objects the cluster creates and maintains itself:
# restoring a stale copy of those would be wrong.
# shellcheck disable=SC2016
prune_snapshot() {
  local manual
  filter_snapshot configmaps '.metadata.name != "kube-root-ca.crt"'
  if [[ "$NAMESPACE" == default ]]; then
    filter_snapshot services '.metadata.name != "kubernetes"'
  fi
  # Endpoints and EndpointSlices are generated for every Service that selects
  # pods. Only the hand-made ones, for Services without a selector, are kept.
  manual=$(jq -c '[.items[]
                   | select(.spec.type != "ExternalName" and (.spec.selector // {}) == {})
                   | .metadata.name]' "$CACHE_DIR/services.json")
  filter_snapshot endpoints '.metadata.name as $n | $names | index($n)' "$manual"
  filter_snapshot endpointslices '
    (.metadata.labels // {}) as $labels
    | ($names | index($labels["kubernetes.io/service-name"] // ""))
      and $labels["endpointslice.kubernetes.io/managed-by"] != "endpointslicemirroring-controller.k8s.io"
  ' "$manual"
}

service_exists() {
  jq -e --arg n "$1" 'any(.items[]; .metadata.name == $n)' "$CACHE_DIR/services.json" > /dev/null
}

# stdin: kind/name lines in any order -> stdout: unique lines in restore order
order_refs() {
  local kind
  sort -u > "$WORK_DIR/order.tmp"
  for kind in $RESOURCE_KINDS; do
    sed -n "\\|^$kind/|p" "$WORK_DIR/order.tmp"
  done
}

# ==============================================================================
# Backup, part 2: work out what one Service depends on
# Each function prints kind/name lines.
# ==============================================================================

service_selector() {
  jq -c --arg n "$1" \
    'first(.items[] | select(.metadata.name == $n)) | .spec.selector // {}' "$CACHE_DIR/services.json"
}

# Workloads whose pods carry the labels in a Service selector ($1, JSON).
service_workloads() {
  local selector="$1" kind
  for kind in $WORKLOAD_KINDS; do
    jq -r --arg kind "$kind" --argjson selector "$selector" "$JQ_SELECTORS"'
      .items[]
      | select((.spec.template.metadata.labels // {}) as $labels
               | {matchLabels: $selector} | selects($labels))
      | "\($kind)/\(.metadata.name)"' "$CACHE_DIR/$kind.json"
  done
}

# Hand-made Endpoints / EndpointSlices behind Service $1 (the snapshot holds no
# generated ones), and the Ingresses and HTTPRoutes that send traffic to it,
# with their TLS secrets.
service_exposure() {
  jq -r --arg svc "$1" '
    .items[] | select(.metadata.name == $svc) | "endpoints/\(.metadata.name)"' "$CACHE_DIR/endpoints.json"
  jq -r --arg svc "$1" '
    .items[] | select(.metadata.labels["kubernetes.io/service-name"] == $svc)
    | "endpointslices/\(.metadata.name)"' "$CACHE_DIR/endpointslices.json"
  jq -r --arg svc "$1" '
    .items[]
    | select(any((.spec.defaultBackend, .spec.rules[]?.http.paths[]?.backend) | .service.name?;
                 . == $svc))
    | "ingresses/\(.metadata.name)",
      (.spec.tls[]?.secretName // empty | "secrets/\(.)")' "$CACHE_DIR/ingresses.json"
  jq -r --arg svc "$1" --arg ns "$NAMESPACE" '
    .items[]
    | select(any(.spec.rules[]?.backendRefs[]?;
                 (.kind // "Service") == "Service" and .name == $svc and (.namespace // $ns) == $ns))
    | "httproutes/\(.metadata.name)"' "$CACHE_DIR/httproutes.json"
}

# ConfigMaps, Secrets, PVCs and the ServiceAccount used by the pods of
# workload $1 (kind/name). A reference marked "optional: true" in the pod spec
# gets a trailing "?", so that it is not reported when the object is absent.
workload_pod_refs() {
  local kind="${1%%/*}" name="${1#*/}"
  jq -r --arg n "$name" '
    def ref($kind):
      select(type == "object" and (.name // .secretName) != null)
      | "\($kind)/\(.name // .secretName)" + (if .optional == true then "?" else "" end);

    first(.items[] | select(.metadata.name == $n)) | .spec.template.spec as $pod
    | (($pod.containers // []) + ($pod.initContainers // [])) as $containers
    | ($pod.volumes[]?             | .configMap                      | ref("configmaps")),
      ($pod.volumes[]?             | .projected.sources[]?.configMap | ref("configmaps")),
      ($containers[] | .envFrom[]? | .configMapRef                   | ref("configmaps")),
      ($containers[] | .env[]?     | .valueFrom.configMapKeyRef      | ref("configmaps")),
      ($pod.volumes[]?             | .secret                         | ref("secrets")),
      ($pod.volumes[]?             | .projected.sources[]?.secret    | ref("secrets")),
      ($containers[] | .envFrom[]? | .secretRef                      | ref("secrets")),
      ($containers[] | .env[]?     | .valueFrom.secretKeyRef         | ref("secrets")),
      ($pod.imagePullSecrets[]?                                      | ref("secrets")),
      ($pod.volumes[]? | .persistentVolumeClaim.claimName // empty   | "persistentvolumeclaims/\(.)"),
      "serviceaccounts/\($pod.serviceAccountName // "default")"
  ' "$CACHE_DIR/$kind.json"
}

# HPAs that scale workload $1, and the PodDisruptionBudgets and NetworkPolicies
# that select its pods.
workload_policies() {
  local kind="${1%%/*}" name="${1#*/}" labels
  labels=$(jq -c --arg n "$name" \
    'first(.items[] | select(.metadata.name == $n)) | .spec.template.metadata.labels // {}' \
    "$CACHE_DIR/$kind.json")
  jq -r --arg kind "$kind" --arg n "$name" '
    .items[] | .spec.scaleTargetRef as $target
    | select($target.name == $n and ($target.kind // "" | ascii_downcase) + "s" == $kind)
    | "horizontalpodautoscalers/\(.metadata.name)"' "$CACHE_DIR/horizontalpodautoscalers.json"
  jq -r --argjson labels "$labels" "$JQ_SELECTORS"'
    .items[]
    | select(.spec.selector != null and (.spec.selector | selects($labels)))
    | "poddisruptionbudgets/\(.metadata.name)"' "$CACHE_DIR/poddisruptionbudgets.json"
  jq -r --argjson labels "$labels" "$JQ_SELECTORS"'
    .items[]
    | select((.spec.podSelector // {}) | selects($labels))
    | "networkpolicies/\(.metadata.name)"' "$CACHE_DIR/networkpolicies.json"
}

# Image pull secrets attached to ServiceAccount $1, the RoleBindings that name
# it and the Roles those bind. (ClusterRoles are cluster-scoped: not saved.)
serviceaccount_refs() {
  jq -r --arg n "$1" '
    .items[] | select(.metadata.name == $n)
    | .imagePullSecrets[]? | .name // empty | "secrets/\(.)"' "$CACHE_DIR/serviceaccounts.json"
  jq -r --arg n "$1" --arg ns "$NAMESPACE" '
    .items[]
    | select(any(.subjects[]?;
                 .kind == "ServiceAccount" and .name == $n and (.namespace // $ns) == $ns))
    | "rolebindings/\(.metadata.name)",
      (select(.roleRef.kind == "Role") | "roles/\(.roleRef.name)")' "$CACHE_DIR/rolebindings.json"
}

# Everything Service $1 needs, in restore order.
resolve_service() {
  local svc="$1" tmp="$WORK_DIR/resolve" selector workload account
  echo "services/$svc" > "$tmp.refs"
  service_exposure "$svc" >> "$tmp.refs"

  : > "$tmp.workloads"
  selector=$(service_selector "$svc")
  if [[ "$selector" != "{}" ]]; then
    service_workloads "$selector" > "$tmp.workloads"
    if [[ ! -s "$tmp.workloads" ]]; then
      warn "Service '$svc': no Deployment, StatefulSet or DaemonSet matches its selector"
    fi
  fi
  while IFS= read -r workload; do
    echo "$workload"
    workload_pod_refs "$workload"
    workload_policies "$workload"
  done < "$tmp.workloads" >> "$tmp.refs"

  sed -n 's|^serviceaccounts/||p' "$tmp.refs" | sort -u > "$tmp.accounts"
  while IFS= read -r account; do
    serviceaccount_refs "$account"
  done < "$tmp.accounts" >> "$tmp.refs"

  # A reference is optional only if nothing else requires the same object.
  sed -n 's|?$||p' "$tmp.refs" | sort -u > "$tmp.maybe"
  sed '/?$/d' "$tmp.refs" | sort -u > "$tmp.required"
  comm -23 "$tmp.maybe" "$tmp.required" > "$WORK_DIR/optional.refs"

  sed 's|?$||' "$tmp.refs" | order_refs
}

# ==============================================================================
# Backup, part 3: write the backup
# ==============================================================================

# Layout: <root>/<namespace>/namespace/<time>          whole-namespace backup
#         <root>/<namespace>/service-<name>/<time>     single-Service backup
# The backup is built under a ".partial" name and renamed when complete, so an
# interrupted run never leaves something that looks like a usable backup.
create_backup_dir() {
  local scope="namespace" stamp
  [[ -z "$SERVICE" ]] || scope="service-$SERVICE"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  FINAL_DIR="$BACKUP_ROOT/$NAMESPACE/$scope/$stamp"
  [[ ! -e "$FINAL_DIR" && ! -e "$FINAL_DIR.tar.gz" ]] || die "Backup '$FINAL_DIR' already exists"
  mkdir -p "$BACKUP_ROOT/$NAMESPACE/$scope"
  # A plain mkdir fails if the directory exists, so two backups started in the
  # same second cannot write into each other.
  mkdir "$FINAL_DIR.partial" 2>/dev/null ||
    die "Cannot create '$FINAL_DIR.partial' (is another backup of the same scope running?)"
  PARTIAL="$FINAL_DIR.partial"
  BACKUP_DIR="$PARTIAL"
  mkdir "$BACKUP_DIR/resources" "$BACKUP_DIR/index"
}

# The Namespace object itself, so its labels and annotations come back when the
# namespace has to be recreated.
save_namespace_manifest() {
  if kc get namespace "$NAMESPACE" -o json 2>/dev/null > "$WORK_DIR/namespace.json"; then
    jq "$JQ_SANITIZE"'sanitize' "$WORK_DIR/namespace.json" > "$BACKUP_DIR/namespace.json"
  else
    warn "Could not read the Namespace object; restore will create a plain namespace"
  fi
}

# Save one object ($1 = kind/name) as a clean manifest. Fails if it is not in
# the namespace.
save_resource() {
  local kind="${1%%/*}" name="${1#*/}" out
  out="$BACKUP_DIR/resources/$kind/$name.json"
  if [[ -f "$out" ]]; then
    return 0
  fi
  if [[ -f "$CACHE_DIR/$kind.json" ]] &&
     jq -e --arg n "$name" "$JQ_SANITIZE"'first(.items[] | select(.metadata.name == $n)) | sanitize' \
       "$CACHE_DIR/$kind.json" > "$WORK_DIR/object.json"; then
    mkdir -p "$BACKUP_DIR/resources/$kind"
    mv "$WORK_DIR/object.json" "$out"
  else
    return 1
  fi
}

# stdin: kind/name lines -> saves each object and prints the ones it saved
save_refs() {
  local ref
  while IFS= read -r ref; do
    if [[ "$ref" == "configmaps/kube-root-ca.crt" ]]; then
      continue   # published into every namespace by Kubernetes itself
    fi
    if save_resource "$ref"; then
      echo "$ref"
    elif grep -qxF "$ref" "$WORK_DIR/reported.refs"; then
      continue   # already reported for another Service
    elif [[ "$ref" == secrets/* && "$INCLUDE_SECRETS" != true ]]; then
      warn "$ref is needed but was not saved (--no-secrets): create it before restoring"
      echo "$ref" >> "$WORK_DIR/reported.refs"
    elif grep -qxF "$ref" "$WORK_DIR/optional.refs"; then
      continue   # marked optional in the pod spec and absent: nothing to save
    else
      warn "$ref is referenced but does not exist in namespace '$NAMESPACE'"
      echo "$ref" >> "$WORK_DIR/reported.refs"
    fi
  done
}

# Save Service $1 with everything it depends on, and record that list so the
# Service can be restored on its own.
backup_service() {
  local svc="$1"
  resolve_service "$svc" > "$WORK_DIR/service.refs"
  save_refs < "$WORK_DIR/service.refs" > "$BACKUP_DIR/index/$svc.txt"
  log "  service/$svc: $(wc -l < "$BACKUP_DIR/index/$svc.txt" | tr -d ' ') object(s)"
}

# Save every object of kind $1 in one pass, which stays fast in namespaces with
# thousands of objects: jq prints a "#file <name>" line before each clean
# manifest (no line of the manifest itself can start with "#"), and awk writes
# each manifest to its own file.
save_all_of_kind() {
  local kind="$1" dir="$BACKUP_DIR/resources/$1"
  if ! jq -e '.items | length > 0' "$CACHE_DIR/$kind.json" > /dev/null; then
    return 0
  fi
  mkdir -p "$dir"
  jq -r "$JQ_SANITIZE"'.items[] | sanitize | "#file \(.metadata.name)", .' "$CACHE_DIR/$kind.json" |
    awk -v dir="$dir" '
      /^#file / { if (out != "") close(out); out = dir "/" substr($0, 7) ".json"; next }
                { print > out }'
}

# Save every object in the namespace, then index each Service.
backup_namespace() {
  local kind svc
  for kind in $RESOURCE_KINDS; do
    save_all_of_kind "$kind"
  done
  jq -r '.items[].metadata.name' "$CACHE_DIR/services.json" > "$WORK_DIR/services.txt"
  while IFS= read -r svc; do
    backup_service "$svc"
  done < "$WORK_DIR/services.txt"
}

# Prints "<kind> <count>" for every kind, counting the saved manifests.
count_saved() {
  local kind file count
  for kind in $RESOURCE_KINDS; do
    count=0
    for file in "$BACKUP_DIR/resources/$kind"/*.json; do
      if [[ -e "$file" ]]; then
        count=$((count + 1))
      fi
    done
    echo "$kind $count"
  done
}

# backup-info.json describes the backup: where and when it was taken and what
# it holds. Restore reads it to find the original namespace.
write_backup_info() {
  count_saved > "$WORK_DIR/counts.txt"
  jq -Rn \
    --arg tool "$SCRIPT_NAME $TOOL_VERSION" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg context "$KUBE_CONTEXT" \
    --arg version "$CLUSTER_VERSION" \
    --arg namespace "$NAMESPACE" \
    --arg service "$SERVICE" \
    --arg secrets "$INCLUDE_SECRETS" '
    { tool: $tool,
      created: $created,
      context: $context,
      kubernetesVersion: $version,
      namespace: $namespace,
      scope: (if $service == "" then "namespace" else "service" end),
      service: (if $service == "" then null else $service end),
      secretsIncluded: ($secrets == "true"),
      resources: ([inputs | split(" ") | {key: .[0], value: (.[1] | tonumber)}] | from_entries) }
  ' < "$WORK_DIR/counts.txt" > "$BACKUP_DIR/backup-info.json"
}

# Move the finished backup into place and, with --archive, pack it.
finish_backup() {
  mv "$PARTIAL" "$FINAL_DIR"
  PARTIAL=""
  BACKUP_DIR="$FINAL_DIR"
  if [[ "$ARCHIVE" == true ]]; then
    PARTIAL="$FINAL_DIR.tar.gz.partial"
    tar -czf "$PARTIAL" -C "${FINAL_DIR%/*}" "${FINAL_DIR##*/}"
    mv "$PARTIAL" "$FINAL_DIR.tar.gz"
    PARTIAL=""
    rm -rf "$FINAL_DIR"
    BACKUP_DIR="$FINAL_DIR.tar.gz"
  fi
}

report_backup() {
  local kind count total=0
  log ""
  log "Saved:"
  while read -r kind count; do
    total=$((total + count))
    if [[ "$count" -gt 0 ]]; then
      log "  $(printf '%-26s %s' "$kind" "$count")"
    fi
  done < "$WORK_DIR/counts.txt"
  if [[ "$total" -eq 0 ]]; then
    warn "Nothing was found to back up in namespace '$NAMESPACE'"
  fi
  if grep -q '^persistentvolumeclaims [1-9]' "$WORK_DIR/counts.txt"; then
    log "Note: PVCs are saved as definitions only. The data in the volumes is NOT in this backup."
  fi
  if grep -q '^secrets [1-9]' "$WORK_DIR/counts.txt"; then
    log "Note: this backup contains Secrets in readable form. Keep it private."
  fi
  log ""
  log "Backup complete ($WARNINGS warning(s)): $BACKUP_DIR"
  log "Restore with:   $SCRIPT_NAME restore -f \"$BACKUP_DIR\""
  echo "$BACKUP_DIR"   # the only line on stdout, for use in other scripts
}

cmd_backup() {
  [[ -n "$NAMESPACE" ]] || die "backup needs -n NAMESPACE (see '$SCRIPT_NAME --help')"
  validate_name namespace "$NAMESPACE"
  [[ -z "$SERVICE" ]] || validate_name service "$SERVICE"
  require_tools kubectl jq
  [[ "$ARCHIVE" != true ]] || require_tools tar
  init_work_dir
  connect_cluster
  check_namespace_exists

  snapshot_namespace
  if [[ -n "$SERVICE" ]]; then
    service_exists "$SERVICE" || die "Service '$SERVICE' was not found in namespace '$NAMESPACE'"
  fi

  create_backup_dir
  save_namespace_manifest
  if [[ -n "$SERVICE" ]]; then
    backup_service "$SERVICE"
  else
    backup_namespace
  fi
  write_backup_info
  finish_backup
  report_backup
}

# ==============================================================================
# Restore
# ==============================================================================

# Open the backup (unpacking a .tar.gz into the scratch directory) and check it
# is one of ours.
load_backup() {
  local dir="$BACKUP_SRC" candidate
  if [[ -f "$BACKUP_SRC" ]]; then
    require_tools tar
    mkdir "$WORK_DIR/extracted"
    tar -xzf "$BACKUP_SRC" -C "$WORK_DIR/extracted" || die "Could not unpack '$BACKUP_SRC'"
    dir=""
    for candidate in "$WORK_DIR/extracted"/*; do
      if [[ -f "$candidate/backup-info.json" ]]; then
        dir="$candidate"
      fi
    done
  fi
  dir="${dir%/}"
  [[ -n "$dir" && -f "$dir/backup-info.json" && -d "$dir/resources" ]] ||
    die "'$BACKUP_SRC' is not a backup made by $SCRIPT_NAME"
  BACKUP_DIR="$dir"
  SOURCE_NS=$(jq -r '.namespace' "$BACKUP_DIR/backup-info.json")
}

# Names of the Services that can be restored individually from this backup.
backup_services() {
  local file names=""
  for file in "$BACKUP_DIR/index"/*.txt; do
    if [[ -e "$file" ]]; then
      file="${file##*/}"
      names="$names ${file%.txt}"
    fi
  done
  echo "${names# }"
}

# Decide what to restore: one Service and its dependencies, or everything.
# Writes kind/name lines in restore order to $WORK_DIR/restore.refs.
select_restore_refs() {
  local kind file
  if [[ -n "$SERVICE" ]]; then
    [[ -f "$BACKUP_DIR/index/$SERVICE.txt" ]] ||
      die "Service '$SERVICE' is not in this backup. Services in it: $(backup_services)"
    cp "$BACKUP_DIR/index/$SERVICE.txt" "$WORK_DIR/restore.refs"
  else
    for kind in $RESOURCE_KINDS; do
      for file in "$BACKUP_DIR/resources/$kind"/*.json; do
        if [[ -e "$file" ]]; then
          file="${file##*/}"
          echo "$kind/${file%.json}"
        fi
      done
    done > "$WORK_DIR/restore.refs"
  fi
  [[ -s "$WORK_DIR/restore.refs" ]] || die "There is nothing to restore in '$BACKUP_SRC'"
}

confirm_restore() {
  local info="$BACKUP_DIR/backup-info.json" what="everything in the backup" reply
  [[ -z "$SERVICE" ]] || what="service '$SERVICE' and its dependencies"
  log "Restore plan"
  log "  backup:  $BACKUP_SRC"
  log "           taken $(jq -r '.created' "$info") from namespace '$SOURCE_NS' (context: $(jq -r '.context' "$info"))"
  log "  restore: $what, $(wc -l < "$WORK_DIR/restore.refs" | tr -d ' ') object(s)"
  log "  into:    namespace '$TARGET_NS' (context: ${KUBE_CONTEXT:-kubectl default}, $CLUSTER_VERSION)"
  if [[ "$DRY_RUN" == true ]]; then
    log "  mode:    dry run, nothing will be changed"
    return 0
  fi
  log "Objects that already exist there will be updated to match the backup."
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  [[ -t 0 ]] || die "Not asking for confirmation without a terminal: re-run with --yes"
  printf 'Proceed? [y/N] ' >&2
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) die "Restore cancelled" ;;
  esac
}

# Create the target namespace from the saved definition if it is missing.
ensure_namespace() {
  if kc get namespace "$TARGET_NS" > /dev/null 2>&1; then
    [[ "$DRY_RUN" != true ]] || DRY_RUN_FLAG="--dry-run=server"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "Namespace '$TARGET_NS' does not exist: it would be created"
    DRY_RUN_FLAG="--dry-run=client"   # the server cannot validate against a missing namespace
    return 0
  fi
  log "Creating namespace '$TARGET_NS'"
  if [[ -f "$BACKUP_DIR/namespace.json" ]]; then
    jq --arg ns "$TARGET_NS" '.metadata.name = $ns' "$BACKUP_DIR/namespace.json" > "$WORK_DIR/target-ns.json"
    kc create -f "$WORK_DIR/target-ns.json" >&2 ||
      warn "Could not create namespace '$TARGET_NS'; continuing in case it exists"
  else
    kc create namespace "$TARGET_NS" >&2 ||
      warn "Could not create namespace '$TARGET_NS'; continuing in case it exists"
  fi
}

# Print a saved manifest, pointed at the target namespace.
render_manifest() {
  jq --arg ns "$TARGET_NS" --arg src "$SOURCE_NS" "$JQ_RETARGET" "$1"
}

# "kubectl apply" the manifest on stdin; extra kubectl arguments in "$@".
# Prints what kubectl said, minus its notice that an object was not created
# with "kubectl apply" (expected during a restore, and harmless).
apply_manifest() {
  local out status=0
  out=$(kc apply -n "$TARGET_NS" ${DRY_RUN_FLAG:+"$DRY_RUN_FLAG"} "$@" -f - 2>&1) || status=$?
  grep -v 'last-applied-configuration annotation which is required by kubectl apply' <<<"$out" || true
  return "$status"
}

# Create or update one object ($1 = kind/name) in the target namespace.
apply_resource() {
  local ref="$1" file="$BACKUP_DIR/resources/$1.json" out
  if [[ ! -f "$file" ]]; then
    log "  FAILED $ref: manifest is missing from the backup"
    return 1
  fi
  if out=$(render_manifest "$file" | apply_manifest); then
    log_indented "$out"
    return 0
  fi
  # Something else created the object between kubectl's check and its create
  # (the cluster does this for the "default" ServiceAccount of a new
  # namespace): apply again, which now updates it.
  if [[ "$out" == *"AlreadyExists"* ]] && out=$(render_manifest "$file" | apply_manifest); then
    log_indented "$out"
    return 0
  fi
  # kubectl records each applied manifest in an annotation, which objects over
  # ~256 KiB do not fit into. Server-side apply has no such limit.
  if [[ "$out" == *"metadata.annotations: Too long"* ]] &&
     out=$(render_manifest "$file" | apply_manifest --server-side --force-conflicts); then
    log_indented "$out"
    return 0
  fi
  # A node port is unique across the whole cluster. If another Service already
  # holds this one (for example when copying a namespace inside one cluster),
  # let the cluster assign a free port rather than lose the Service.
  if [[ "$ref" == services/* && "$out" == *"port is already allocated"* ]] &&
     out=$(render_manifest "$file" |
           jq 'del(.spec.ports[]?.nodePort, .spec.healthCheckNodePort)' | apply_manifest); then
    log_indented "$out"
    warn "$ref: its node port is used by another Service, so the cluster assigned a new one"
    return 0
  fi
  log_indented "FAILED $ref: $out"
  return 1
}

# Apply the selected objects in restore order. One failure does not stop the
# rest; failures are counted and reported at the end.
apply_refs() {
  local ref
  log ""
  log "Applying to namespace '$TARGET_NS':"
  : > "$WORK_DIR/applied.refs"
  while IFS= read -r ref; do
    if apply_resource "$ref"; then
      APPLIED=$((APPLIED + 1))
      echo "$ref" >> "$WORK_DIR/applied.refs"
    else
      FAILED=$((FAILED + 1))
    fi
  done < "$WORK_DIR/restore.refs"
}

# Wait until every restored workload has finished rolling out.
wait_for_workloads() {
  local ref kind
  while IFS= read -r ref; do
    kind="${ref%%/*}"
    case " $WORKLOAD_KINDS " in
      *" $kind "*) ;;
      *) continue ;;
    esac
    log "Waiting for $ref (up to ${TIMEOUT}s)"
    if ! kc rollout status "$(kind_resource "$kind")/${ref#*/}" -n "$TARGET_NS" \
           --timeout="${TIMEOUT}s" < /dev/null >&2; then
      warn "$ref did not become ready"
      NOT_READY=$((NOT_READY + 1))
    fi
  done < "$WORK_DIR/applied.refs"
}

report_restore() {
  log ""
  if [[ "$DRY_RUN" == true ]]; then
    log "Dry run finished: $APPLIED object(s) would be applied, $FAILED failed. Nothing was changed."
  else
    if grep -q '^persistentvolumeclaims/' "$WORK_DIR/applied.refs"; then
      log "Note: PVCs were restored as definitions only; volume data is not part of the backup."
    fi
    log "Restore finished: $APPLIED applied, $FAILED failed, $NOT_READY workload(s) not ready."
  fi
  if [[ $((FAILED + NOT_READY)) -gt 0 ]]; then
    exit 1
  fi
}

cmd_restore() {
  [[ -n "$BACKUP_SRC" ]] || die "restore needs -f BACKUP (see '$SCRIPT_NAME list')"
  [[ -e "$BACKUP_SRC" ]] || die "Backup '$BACKUP_SRC' does not exist"
  [[ -z "$SERVICE" ]] || validate_name service "$SERVICE"
  require_tools kubectl jq
  init_work_dir
  load_backup
  TARGET_NS="${NAMESPACE:-$SOURCE_NS}"
  validate_name namespace "$TARGET_NS"
  select_restore_refs
  connect_cluster

  confirm_restore
  ensure_namespace
  apply_refs
  if [[ "$WAIT_READY" == true && "$DRY_RUN" != true ]]; then
    wait_for_workloads
  fi
  report_restore
}

# ==============================================================================
# List
# ==============================================================================

cmd_list() {
  local path stamp scope ns count=0
  [[ -d "$BACKUP_ROOT" ]] || die "No backups found: '$BACKUP_ROOT' does not exist"
  printf '%-20s %-26s %-18s %s\n' "NAMESPACE" "SCOPE" "TAKEN (UTC)" "PATH"
  for path in "$BACKUP_ROOT"/*/*/*; do
    if [[ "$path" == *.partial ]]; then
      continue
    elif [[ -f "$path/backup-info.json" ]]; then
      stamp="${path##*/}"
    elif [[ -f "$path" && "$path" == *.tar.gz ]]; then
      stamp="${path##*/}"
      stamp="${stamp%.tar.gz}"
    else
      continue
    fi
    scope="${path%/*}"
    ns="${scope%/*}"
    printf '%-20s %-26s %-18s %s\n' "${ns##*/}" "${scope##*/}" "$stamp" "$path"
    count=$((count + 1))
  done
  [[ "$count" -gt 0 ]] || log "No backups in '$BACKUP_ROOT'"
}

# ==============================================================================
# Main
# ==============================================================================

main() {
  parse_args "$@"
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  case "$COMMAND" in
    backup)         cmd_backup ;;
    restore)        cmd_restore ;;
    list)           cmd_list ;;
    help|-h|--help) usage ;;
    *)              die "Unknown command '$COMMAND' (see '$SCRIPT_NAME --help')" ;;
  esac
}

main "$@"
