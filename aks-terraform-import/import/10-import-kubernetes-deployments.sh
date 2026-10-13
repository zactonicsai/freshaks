#!/usr/bin/env bash
# =============================================================================
#  import/10-import-kubernetes-deployments.sh — Workloads INSIDE the cluster
# =============================================================================
#  Adopts the plain-manifest objects (kubectl apply / CI pipelines) in every
#  non-system namespace into the Terraform `kubernetes` provider:
#
#   kubectl kind          Terraform resource type                    Import ID
#   -------------------   ----------------------------------------   -----------------
#   namespace             kubernetes_namespace_v1                    <name>
#   deployment            kubernetes_deployment_v1                   <namespace>/<name>
#   statefulset           kubernetes_stateful_set_v1                 <namespace>/<name>
#   daemonset             kubernetes_daemon_set_v1                   <namespace>/<name>
#   service               kubernetes_service_v1                      <namespace>/<name>
#   ingress               kubernetes_ingress_v1                      <namespace>/<name>
#   configmap             kubernetes_config_map_v1                   <namespace>/<name>
#   secret (opt-in)       kubernetes_secret_v1                       <namespace>/<name>
#   persistentvolumeclaim kubernetes_persistent_volume_claim_v1      <namespace>/<name>
#   serviceaccount        kubernetes_service_account_v1              <namespace>/<name>
#   hpa                   kubernetes_horizontal_pod_autoscaler_v2    <namespace>/<name>
#   cronjob               kubernetes_cron_job_v1                     <namespace>/<name>
#   storageclass          kubernetes_storage_class_v1                <name>   (custom classes only)
#
#  What is skipped, and why:
#    * system namespaces (SYSTEM_NAMESPACES) — owned by AKS add-ons
#    * anything labelled app.kubernetes.io/managed-by=Helm or annotated
#      meta.helm.sh/release-name — those belong to 11-import-helm-releases.sh;
#      importing them twice would make two Terraform resources fight
#    * objects with ownerReferences — created by a controller (ReplicaSets,
#      operator-managed Services ...), they vanish with their owner
#    * the `kubernetes` Service, the `default` ServiceAccount, kube-root-ca.crt,
#      service-account-token and helm.sh/release.v1 Secrets — API-server managed
#    * AKS-provided StorageClasses (label addonmanager.kubernetes.io/mode)
#
#  Secrets are opt-in (IMPORT_SECRETS=true): Terraform writes the decoded data
#  into generated HCL and into the state file.
#
#  kubectl commands used:
#     kubectl get ns -o json                     namespace list (via target_namespaces)
#     kubectl get <kind> -n <ns> -o json         objects of one kind, with labels/annotations/ownerReferences
#     kubectl get storageclass -o json           cluster-scoped storage classes
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
require_tools kubectl
aks_credentials
tf_import_begin kubernetes

# import_kind <namespace> <kubectl kind> <terraform type> [extra jq filter]
#   Lists objects of one kind in a namespace, applies the skip rules above plus
#   the optional extra filter, and records an import block per object.
import_kind() {
  local ns="$1" kind="$2" tftype="$3" extra="${4:-true}"
  local items name
  items="$(kubectl get "$kind" -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    tf_import_add "$tftype" "$(tf_name "${ns}__${name}")" "${ns}/${name}" "$kind $ns/$name"
  done < <(jq -r '
      .items[]
      | select((.metadata.labels["app.kubernetes.io/managed-by"] // "") != "Helm")
      | select((.metadata.annotations["meta.helm.sh/release-name"] // "") == "")
      | select(((.metadata.ownerReferences // []) | length) == 0)
      | select('"$extra"')
      | .metadata.name' <<<"$items")
}

while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue
  hr
  log "Namespace: $ns"
  if [[ "$ns" != "default" ]]; then
    tf_import_add kubernetes_namespace_v1 "$(tf_name "$ns")" "$ns" "Namespace $ns"
  fi
  import_kind "$ns" deployment            kubernetes_deployment_v1
  import_kind "$ns" statefulset           kubernetes_stateful_set_v1
  import_kind "$ns" daemonset             kubernetes_daemon_set_v1
  import_kind "$ns" service               kubernetes_service_v1 \
      '.metadata.name != "kubernetes"'
  import_kind "$ns" ingress               kubernetes_ingress_v1
  import_kind "$ns" configmap             kubernetes_config_map_v1 \
      '.metadata.name != "kube-root-ca.crt"'
  if [[ "$IMPORT_SECRETS" == "true" ]]; then
    import_kind "$ns" secret              kubernetes_secret_v1 \
      '(.type // "Opaque") != "kubernetes.io/service-account-token" and (.type // "") != "helm.sh/release.v1" and ((.type // "") | startswith("bootstrap.kubernetes.io") | not)'
  fi
  import_kind "$ns" persistentvolumeclaim kubernetes_persistent_volume_claim_v1
  import_kind "$ns" serviceaccount        kubernetes_service_account_v1 \
      '.metadata.name != "default"'
  import_kind "$ns" hpa                   kubernetes_horizontal_pod_autoscaler_v2
  import_kind "$ns" cronjob               kubernetes_cron_job_v1
done < <(target_namespaces)

# --- Cluster-scoped: custom StorageClasses ------------------------------------
hr
log "Custom storage classes"
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  tf_import_add kubernetes_storage_class_v1 "$(tf_name "$name")" "$name" "StorageClass $name"
done < <(kubectl get storageclass -o json | jq -r '
    .items[]
    | select((.metadata.labels["addonmanager.kubernetes.io/mode"] // "") == "")
    | select((.metadata.labels["kubernetes.io/cluster-service"] // "") == "")
    | .metadata.name')

hr
log "Review notes for generated/kubernetes.tf:"
log "  * generated blocks are verbose; delete server-populated fields (resource_version, uid, status...) if validate complains"
log "  * Deployments scaled by an HPA: add lifecycle { ignore_changes = [spec[0].replicas] }"
log "  * Secrets were $([[ "$IMPORT_SECRETS" == "true" ]] && echo 'INCLUDED — protect your state file' || echo 'skipped (IMPORT_SECRETS=false)')"
tf_import_end
