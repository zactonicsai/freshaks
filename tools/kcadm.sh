#!/usr/bin/env bash
# =============================================================================
#  tools/kcadm.sh — run any Keycloak admin-CLI command inside the Keycloak pod.
#
#    tools/kcadm.sh get users -r grocery --fields username
#    tools/kcadm.sh get clients -r grocery --fields clientId
#    tools/kcadm.sh get roles -r grocery --fields name
#
#  It logs in first with the admin user from 00-config.sh, so you never type a password.
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
require_cmd kubectl
kcadm_login
kcadm "$@"
