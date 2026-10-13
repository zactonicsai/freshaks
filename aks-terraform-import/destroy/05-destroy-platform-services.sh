#!/usr/bin/env bash
# =============================================================================
#  destroy/05-destroy-platform-services.sh — ACR, Key Vault, storage, monitoring, identities
# =============================================================================
#  Deletes the supporting services in RESOURCE_GROUP:
#
#    1. monitoring: metric alerts, DCR associations, data collection rules,
#       Log Analytics solutions, Managed Grafana, Azure Monitor workspaces,
#       Log Analytics workspaces (--force = permanent, not soft-deleted)
#    2. container registries
#    3. key vaults (soft-delete, then optional purge)
#    4. storage accounts
#    5. user-assigned identities, after removing their role assignments
#
#  Options (env vars)
#    PURGE_KEYVAULT=true            purge after delete so the name is reusable now
#                                   (impossible when purge protection is enabled)
#    KEEP_LOG_ANALYTICS=false       leave Log Analytics workspaces alone
#
#  Azure CLI commands used:
#     az monitor metrics alert list/delete -g <rg>
#     az monitor data-collection rule association list --resource <cluster id> / delete --resource <id> -n <name> --yes
#     az monitor data-collection rule list/delete -g <rg> --yes
#     az monitor log-analytics solution list/delete -g <rg> --yes
#     az grafana list/delete -g <rg> --yes
#     az monitor account list/delete -g <rg> --yes
#     az monitor log-analytics workspace list/delete -g <rg> --force --yes
#     az acr list/delete -g <rg> --yes
#     az keyvault list/delete -g <rg>;  az keyvault purge -n <name> -l <location>
#     az storage account list/delete -g <rg> --yes
#     az identity list -g <rg>;  az role assignment list --assignee <principal> --all;
#     az role assignment delete --ids <id>;  az identity delete -g <rg> -n <name>
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
PURGE_KEYVAULT="${PURGE_KEYVAULT:-true}"
KEEP_LOG_ANALYTICS="${KEEP_LOG_ANALYTICS:-false}"

hr
warn "This deletes ACR, Key Vault, storage, monitoring and identity resources in $RESOURCE_GROUP."
confirm "$CLUSTER_NAME"

del() {
  local what="$1"; shift
  log "  delete $what"
  run az "$@" || warn "failed: $what"
}
names() { az "$@" --query '[].name' -o tsv 2>/dev/null || true; }

# --- 1. Monitoring --------------------------------------------------------------
hr; log "1/5 monitoring"
for n in $(names monitor metrics alert list -g "$RESOURCE_GROUP"); do
  del "metric alert $n" monitor metrics alert delete -g "$RESOURCE_GROUP" -n "$n"
done

cluster_id="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query id -o tsv 2>/dev/null || true)"
if [[ -n "$cluster_id" ]]; then
  for n in $(az monitor data-collection rule association list --resource "$cluster_id" --query '[].name' -o tsv 2>/dev/null || true); do
    del "DCR association $n" monitor data-collection rule association delete --resource "$cluster_id" -n "$n" --yes
  done
fi
for n in $(names monitor data-collection rule list -g "$RESOURCE_GROUP"); do
  del "data collection rule $n" monitor data-collection rule delete -g "$RESOURCE_GROUP" -n "$n" --yes
done
for n in $(names monitor log-analytics solution list -g "$RESOURCE_GROUP"); do
  del "log analytics solution $n" monitor log-analytics solution delete -g "$RESOURCE_GROUP" -n "$n" --yes
done
for n in $(names grafana list -g "$RESOURCE_GROUP"); do
  del "managed grafana $n" grafana delete -g "$RESOURCE_GROUP" -n "$n" --yes
done
for n in $(names monitor account list -g "$RESOURCE_GROUP"); do
  del "azure monitor workspace $n" monitor account delete -g "$RESOURCE_GROUP" -n "$n" --yes
done
if [[ "$KEEP_LOG_ANALYTICS" != "true" ]]; then
  for n in $(names monitor log-analytics workspace list -g "$RESOURCE_GROUP"); do
    # --force deletes permanently; without it the workspace is soft-deleted for 14 days
    del "log analytics workspace $n" monitor log-analytics workspace delete -g "$RESOURCE_GROUP" -n "$n" --force --yes
  done
fi

# --- 2. Container registries ---------------------------------------------------
hr; log "2/5 container registries"
for n in $(names acr list -g "$RESOURCE_GROUP"); do
  del "container registry $n" acr delete -g "$RESOURCE_GROUP" -n "$n" --yes
done

# --- 3. Key vaults ---------------------------------------------------------------
hr; log "3/5 key vaults"
while IFS='|' read -r n loc purge_prot; do
  [[ -z "$n" ]] && continue
  del "key vault $n (soft-delete)" keyvault delete -g "$RESOURCE_GROUP" -n "$n"
  if [[ "$PURGE_KEYVAULT" == "true" ]]; then
    if [[ "$purge_prot" == "true" ]]; then
      warn "  key vault $n has purge protection enabled — it stays soft-deleted for the retention period"
    else
      del "key vault $n (purge)" keyvault purge -n "$n" -l "$loc"
    fi
  fi
done < <(az keyvault list -g "$RESOURCE_GROUP" --resource-type vault -o json | jq -r '.[] | [.name, .location, ((.properties.enablePurgeProtection // false) | tostring)] | join("|")')

# --- 4. Storage accounts ---------------------------------------------------------
hr; log "4/5 storage accounts"
for n in $(names storage account list -g "$RESOURCE_GROUP"); do
  del "storage account $n" storage account delete -g "$RESOURCE_GROUP" -n "$n" --yes
done

# --- 5. Identities and their role assignments --------------------------------------
hr; log "5/5 user-assigned identities"
while IFS='|' read -r n principal; do
  [[ -z "$n" ]] && continue
  for ra in $(az role assignment list --assignee "$principal" --all --query '[].id' -o tsv 2>/dev/null || true); do
    del "role assignment ${ra##*/} of $n" role assignment delete --ids "$ra"
  done
  del "identity $n" identity delete -g "$RESOURCE_GROUP" -n "$n"
done < <(az identity list -g "$RESOURCE_GROUP" -o json | jq -r '.[] | [.name, .principalId] | join("|")')

hr
ok "Platform services removed. Next: ./destroy/06-destroy-resource-group.sh"
