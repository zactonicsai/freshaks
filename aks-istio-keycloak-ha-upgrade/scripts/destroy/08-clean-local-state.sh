#!/usr/bin/env bash
# =============================================================================
# 08-clean-local-state.sh — delete the local .state folder: remembered names,
# generated passwords, the private CA, the kubeconfig and the local copies of
# the database dumps. The log files in logs/ are kept.
# Run it only after the Azure resources are gone - without the state file the
# scripts no longer know the name of your registry.
# Usage: ./scripts/destroy/08-clean-local-state.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Ask before deleting.
confirm "Delete ${STATE_DIR} (passwords, certificates, kubeconfig, local backups)?" || fail "stopped by user"

# Announce the step.
step "Stop the availability probe if it is still running"
# "|| true": it is fine when no probe runs.
bash "${ROOT_DIR}/scripts/tools/availability-probe.sh" stop >/dev/null 2>&1 || true

# Announce the step.
step "Delete ${STATE_DIR}"
# ":?" stops the command if the variable were ever empty - a guard against "rm -rf /".
rm -rf "${STATE_DIR:?}"
# Final message.
ok "local state deleted; logs are kept in ${LOG_DIR}"
