#!/usr/bin/env bash
# =============================================================================
# in-tools.sh — run any command in the tools container, for your own
# exploring. kubectl and helm are installed there and already point at the
# cluster, so you do not need them on your machine.
# Usage: ./scripts/tools/in-tools.sh kubectl get pods --all-namespaces
#        ./scripts/tools/in-tools.sh helm list --all-namespaces
#        ./scripts/tools/in-tools.sh kubectl --namespace apps logs deployment/app1
# This script does not use the shared library, so its output is not logged
# and interactive commands (kubectl exec -it ...) work.
# =============================================================================
# Stop at the first error, treat unset variables as errors.
set -euo pipefail
# Without a command there is nothing to run.
if [[ $# -eq 0 ]]; then echo "usage: in-tools.sh COMMAND [ARGUMENTS...]   e.g. in-tools.sh kubectl get nodes" >&2; exit 1; fi
# -i passes your keyboard input on; -t adds a terminal when you have one
# (needed for interactive commands, wrong for pipes).
if [[ -t 0 && -t 1 ]]; then exec docker exec -it k8s-ha-demo-tools "$@"; else exec docker exec -i k8s-ha-demo-tools "$@"; fi
