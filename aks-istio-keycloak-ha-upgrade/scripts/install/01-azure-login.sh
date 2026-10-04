#!/usr/bin/env bash
# =============================================================================
# 01-azure-login.sh — sign in to Azure, pick the subscription, register the
# resource providers and check the vCPU quota.
# Usage: ./scripts/install/01-azure-login.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Announce the step.
step "Sign in to Azure (skipped when you are already signed in)"
# "az account show" only works with a valid login; otherwise open the login page.
if az account show --output none 2>/dev/null; then info "already signed in"; else run az login --output none; fi

# A subscription was named in config/env.sh: switch to it.
if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  # Announce the step.
  step "Select subscription ${SUBSCRIPTION_ID}"
  # Every later "az" command uses this subscription.
  run az account set --subscription "${SUBSCRIPTION_ID}"
fi

# Announce the step.
step "Show the subscription that will be used (and billed)"
# Print name, id and tenant as a small table.
run az account show --query "{name:name, id:id, tenant:tenantId}" --output table

# Announce the step.
step "Register the Azure resource providers used by this example"
# A provider must be registered once per subscription before its resources can
# be created. Registering again is harmless.
for provider in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.Network Microsoft.Compute Microsoft.Storage; do
  # --wait returns when the registration is complete.
  run az provider register --namespace "${provider}" --wait
done

# Announce the step.
step "Check the regional vCPU quota in ${LOCATION}"
# Read "used" and "limit" of the regional vCPU counter (tab separated).
usage="$(az vm list-usage --location "${LOCATION}" --query "[?name.value=='cores'].[currentValue, limit]" --output tsv)"
# First column: vCPUs in use.
used="$(printf '%s' "${usage}" | cut -f1)"
# Second column: the limit.
limit="$(printf '%s' "${usage}" | cut -f2)"
# vCPUs still free (0 when the numbers could not be read).
free=$(( ${limit:-0} - ${used:-0} ))
# Show the numbers.
info "regional vCPUs: ${used:-?} used of ${limit:-?} (free: ${free})"
# With the default sizes the cluster needs 18 vCPUs, 24 while an upgrade adds
# surge nodes, and 30 for the blue/green node pool variant.
if (( free < 24 )); then warn "Fewer than 24 free vCPUs. The install needs 18, a surge upgrade 24, a blue/green pool upgrade 30. Ask for more quota or use smaller node sizes."; else ok "enough vCPU quota for install and surge upgrades"; fi
# The quota is also counted per VM family (here: DSv5). Show that line too.
run az vm list-usage --location "${LOCATION}" --query "[?contains(name.value, 'DSv5')].{family:name.localizedValue, used:currentValue, limit:limit}" --output table
