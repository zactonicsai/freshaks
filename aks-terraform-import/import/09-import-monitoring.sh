#!/usr/bin/env bash
# =============================================================================
#  import/09-import-monitoring.sh — Logging, metrics and alerting
# =============================================================================
#   Azure object                            Terraform resource type                            Import ID
#   -------------------------------------   ------------------------------------------------   -----------------------------------------
#   Log Analytics workspace                 azurerm_log_analytics_workspace                    .../Microsoft.OperationalInsights/workspaces/<n>
#   Log Analytics solution (ContainerInsights) azurerm_log_analytics_solution                  .../Microsoft.OperationsManagement/solutions/<n>
#   Diagnostic setting on the cluster       azurerm_monitor_diagnostic_setting                 "<cluster id>|<setting name>"
#   Data collection rule (Container Insights / Prometheus) azurerm_monitor_data_collection_rule .../Microsoft.Insights/dataCollectionRules/<n>
#   DCR association on the cluster          azurerm_monitor_data_collection_rule_association   "<cluster id>/providers/Microsoft.Insights/dataCollectionRuleAssociations/<n>"
#   Azure Monitor workspace (managed Prometheus) azurerm_monitor_workspace                      .../Microsoft.Monitor/accounts/<n>
#   Azure Managed Grafana                   azurerm_dashboard_grafana                          .../Microsoft.Dashboard/grafana/<n>
#   Metric alert rule                       azurerm_monitor_metric_alert                       .../Microsoft.Insights/metricAlerts/<n>
#
#  The Log Analytics workspace used by Container Insights is often NOT in the
#  cluster's RG (AKS defaults to DefaultResourceGroup-XXX/DefaultWorkspace-...).
#  It is imported only when it lives in RESOURCE_GROUP; otherwise its ID is
#  printed so you can decide — a shared default workspace should not be
#  destroyed with one cluster.
#
#  Azure CLI commands used:
#     az monitor log-analytics workspace list -g <rg>                 workspaces
#     az monitor log-analytics solution list -g <rg>                  ContainerInsights(...) solutions (extension)
#     az monitor diagnostic-settings list --resource <cluster id>     diagnostic settings (control-plane logs)
#     az monitor data-collection rule list -g <rg>                    DCRs
#     az monitor data-collection rule association list --resource <id> DCR <-> cluster links
#     az monitor account list -g <rg>                                 Azure Monitor workspaces (Prometheus)
#     az grafana list -g <rg>                                         Managed Grafana (amg extension)
#     az monitor metrics alert list -g <rg>                           metric alert rules
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
tf_import_begin monitoring

cluster_json="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o json)"
cluster_id="$(jq -r '.id' <<<"$cluster_json")"

# --- Log Analytics workspaces --------------------------------------------------
json="$(az monitor log-analytics workspace list -g "$RESOURCE_GROUP" -o json)"
while IFS='|' read -r name id; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_log_analytics_workspace "$(tf_name "$name")" "$id" "Log Analytics workspace $name"
done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

ci_ws="$(jq -r '.addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID // empty' <<<"$cluster_json")"
if [[ -n "$ci_ws" ]]; then
  ci_ws_lc="$(tr '[:upper:]' '[:lower:]' <<<"$ci_ws")"
  rg_lc="$(tr '[:upper:]' '[:lower:]' <<<"$RESOURCE_GROUP")"
  if [[ "$ci_ws_lc" == *"/resourcegroups/${rg_lc}/"* ]]; then
    tf_import_add azurerm_log_analytics_workspace "$(tf_name "${ci_ws##*/}")" "$ci_ws" "Container Insights workspace"
  else
    warn "Container Insights uses a workspace outside $RESOURCE_GROUP — not imported: $ci_ws"
  fi
fi

# --- Log Analytics solutions (ContainerInsights(<workspace>)) ------------------
json="$(az monitor log-analytics solution list -g "$RESOURCE_GROUP" -o json 2>/dev/null || echo '[]')"
while IFS='|' read -r name id; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_log_analytics_solution "$(tf_name "$name")" "$id" "Log Analytics solution $name"
done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

# --- Diagnostic settings on the cluster (kube-audit, kube-apiserver logs ...) --
# Newer az versions return a plain list, older ones {"value": [...]}; handle both.
json="$(az monitor diagnostic-settings list --resource "$cluster_id" -o json 2>/dev/null || echo '[]')"
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_monitor_diagnostic_setting "$(tf_name "${CLUSTER_NAME}_${name}")" "${cluster_id}|${name}" \
    "Diagnostic setting $name on $CLUSTER_NAME"
done < <(jq -r 'if type == "array" then .[] else (.value // [])[] end | .name' <<<"$json")

# --- Data collection rules + associations -------------------------------------
json="$(az monitor data-collection rule list -g "$RESOURCE_GROUP" -o json 2>/dev/null || echo '[]')"
while IFS='|' read -r name id; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_monitor_data_collection_rule "$(tf_name "$name")" "$id" "Data collection rule $name"
done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

json="$(az monitor data-collection rule association list --resource "$cluster_id" -o json 2>/dev/null || echo '[]')"
while IFS='|' read -r name id rule; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_monitor_data_collection_rule_association "$(tf_name "${CLUSTER_NAME}_${name}")" "$id" \
    "DCR association $name -> ${rule##*/}"
done < <(jq -r '.[] | [.name, .id, (.dataCollectionRuleId // .dataCollectionEndpointId // "")] | join("|")' <<<"$json")

# --- Azure Monitor workspace (managed Prometheus) -------------------------------
json="$(az monitor account list -g "$RESOURCE_GROUP" -o json 2>/dev/null || echo '[]')"
while IFS='|' read -r name id; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_monitor_workspace "$(tf_name "$name")" "$id" "Azure Monitor workspace $name"
done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

# --- Azure Managed Grafana -----------------------------------------------------
json="$(az grafana list -g "$RESOURCE_GROUP" -o json 2>/dev/null || echo '[]')"
while IFS='|' read -r name id; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_dashboard_grafana "$(tf_name "$name")" "$id" "Managed Grafana $name"
done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

# --- Metric alert rules --------------------------------------------------------
json="$(az monitor metrics alert list -g "$RESOURCE_GROUP" -o json 2>/dev/null || echo '[]')"
while IFS='|' read -r name id; do
  [[ -z "$name" ]] && continue
  tf_import_add azurerm_monitor_metric_alert "$(tf_name "$name")" "$id" "Metric alert $name"
done < <(jq -r '.[] | [.name, .id] | join("|")' <<<"$json")

tf_import_end
