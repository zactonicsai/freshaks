#!/usr/bin/env bash
# =============================================================================
# 00-preflight-checks.sh — find problems BEFORE an upgrade starts.
# An upgrade restarts every pod and replaces every node. Anything that is
# already unhealthy, or that cannot be moved, will turn into an outage or a
# stuck upgrade. This script changes nothing; it stops with an error when it
# finds a blocker.
# Usage: ./scripts/upgrade/00-preflight-checks.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# Load the "how to deploy each component" functions.
# shellcheck source=../lib/deploy.sh
source "${ROOT_DIR}/scripts/lib/deploy.sh"

# Stop when the kubeconfig is missing.
require_cluster
# The Istio version must be known for the replica check below.
require_state ISTIO_ACTIVE_VERSION "scripts/install/12-install-istiod.sh"

# Number of blockers found so far.
problems=0

# Announce the step.
step "Every node must be Ready"
# Column 2 of "kubectl get nodes" is the status; count the lines that are not "Ready".
not_ready="$(kubectl get nodes --no-headers | awk '$2 != "Ready"' | wc -l | tr -d ' ')"
# Report and count.
if (( not_ready > 0 )); then warn "${not_ready} node(s) are not Ready"; problems=$((problems + 1)); else ok "all nodes are Ready"; fi
# Show the nodes with zone and pool.
run kubectl get nodes --label-columns topology.kubernetes.io/zone,agentpool

# Announce the step.
step "Every pod of the example must be running and ready"
# Check the namespaces one by one.
for namespace in istio-system istio-ingress istio-egress nfs-storage postgres keycloak apps; do
  # Column 2 is READY ("2/2"), column 3 is STATUS. A pod is fine when it is
  # Completed, or Running with all containers ready.
  unhealthy="$(kubectl --namespace "${namespace}" get pods --no-headers 2>/dev/null | awk '{ split($2, r, "/"); if ($3 != "Completed" && ($3 != "Running" || r[1] != r[2])) print $1 }')"
  # Report and count.
  if [[ -n "${unhealthy}" ]]; then warn "unhealthy pods in ${namespace}: $(printf '%s' "${unhealthy}" | tr '\n' ' ')"; problems=$((problems + 1)); else ok "namespace ${namespace}: all pods healthy"; fi
done

# Announce the step.
step "Every PodDisruptionBudget must allow at least one disruption"
# A budget with 0 allowed disruptions blocks "drain", and with it every node
# upgrade. Print "namespace/name" for each budget that allows none.
blocking="$(kubectl get poddisruptionbudgets --all-namespaces --output jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.status.disruptionsAllowed}{"\n"}{end}' | awk '$2 == 0 { print $1 }')"
# Report and count.
if [[ -n "${blocking}" ]]; then warn "these budgets allow 0 disruptions and will block node drains: $(printf '%s' "${blocking}" | tr '\n' ' ')"; problems=$((problems + 1)); else ok "all PodDisruptionBudgets allow a disruption"; fi
# Show them.
run kubectl get poddisruptionbudgets --all-namespaces

# Announce the step.
step "Highly available components must have at least two ready pods"
# "namespace/deployment" of everything that is meant to survive a node drain.
for item in "istio-system/istiod-$(istio_rev "${ISTIO_ACTIVE_VERSION}")" istio-ingress/istio-ingressgateway istio-egress/istio-egressgateway keycloak/keycloak apps/app1 apps/app2; do
  # Part before the slash: namespace.
  namespace="${item%%/*}"
  # Part after the slash: Deployment name.
  name="${item##*/}"
  # Number of ready pods (empty when the Deployment is missing).
  ready="$(kubectl --namespace "${namespace}" get deployment "${name}" --output jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  # Report and count.
  if (( ${ready:-0} < 2 )); then warn "${item} has ${ready:-0} ready pod(s); with fewer than 2 a node drain causes downtime"; problems=$((problems + 1)); else ok "${item}: ${ready} ready pods"; fi
done

# Announce the step.
step "No Helm release may be in a failed or pending state"
# --failed --pending lists only broken releases; --short prints just the names.
broken="$(helm list --all-namespaces --failed --pending --short)"
# Report and count.
if [[ -n "${broken}" ]]; then warn "broken Helm releases: $(printf '%s' "${broken}" | tr '\n' ' ')"; problems=$((problems + 1)); else ok "all Helm releases are deployed"; fi

# istioctl is optional; use it when it is installed.
if command -v istioctl >/dev/null 2>&1; then
  # Announce the step.
  step "All sidecars must be in sync with the control plane"
  # Lists every proxy; a proxy that is STALE has not received the newest config.
  run istioctl proxy-status || warn "istioctl proxy-status reported a problem"
fi

# Announce the step.
step "Known single points of failure (information only)"
# These are accepted in this example; the README explains the alternatives.
warn "PostgreSQL is one pod: when its node is drained the database is away for about a minute."
# Only relevant for the default storage backend.
if [[ "${STORAGE_BACKEND}" == "nfs-pod" ]]; then warn "The NFS server is one pod: when its node is drained all NFS volumes pause until it is back."; fi

# Announce the step.
step "Result"
# Any blocker stops the script with an error, so upgrade-all.sh stops too.
if (( problems > 0 )); then fail "${problems} problem(s) found. Fix them before you upgrade."; fi
# Everything is fine.
ok "no blockers found - the cluster is ready for an upgrade"
