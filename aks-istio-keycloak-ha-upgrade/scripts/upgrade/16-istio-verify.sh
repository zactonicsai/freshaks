#!/usr/bin/env bash
# =============================================================================
# 16-istio-verify.sh — prove that the Istio hop is complete: every proxy runs
# the active version and the services still answer. Changes nothing.
# Usage: ./scripts/upgrade/16-istio-verify.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The active Istio version must be known.
require_state ISTIO_ACTIVE_VERSION "scripts/install/12-install-istiod.sh"

# Announce the step.
step "Every proxy must run version ${ISTIO_ACTIVE_VERSION}"
# Old pods can take up to a minute to disappear after a restart, so try
# several times before giving up.
tries=0
# Loop until no outdated proxy is left.
while true; do
  # Lines of the report whose image does not contain ":<active version>".
  outdated="$(mesh_proxy_report | awk -v wanted=":${ISTIO_ACTIVE_VERSION}" 'index($3, wanted) == 0')"
  # None left: done.
  if [[ -z "${outdated}" ]]; then break; fi
  # Count this try.
  tries=$((tries + 1))
  # After 3 minutes show the pods and stop with an error.
  if (( tries >= 18 )); then printf '%s\n' "${outdated}"; fail "These pods still run another proxy version. Run steps 14 and 15 again."; fi
  # Wait before the next try.
  sleep 10
done
# Show the full list.
mesh_proxy_report
# Report success.
ok "all proxies run ${ISTIO_ACTIVE_VERSION}"

# Use istioctl when it is there.
if command -v istioctl >/dev/null 2>&1; then
  # Announce the step.
  step "All sidecars must be in sync with the control plane"
  # SYNCED in every column means the proxy has the newest configuration.
  run istioctl proxy-status || warn "istioctl proxy-status reported a problem"
fi

# Announce the step.
step "The services must still answer through the upgraded mesh"
# Runs the same smoke test as after the install.
bash "${ROOT_DIR}/scripts/install/24-smoke-test.sh"
