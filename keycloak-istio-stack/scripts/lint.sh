#!/usr/bin/env bash
# Local, read-only Helm checks. No connection to a Kubernetes cluster is needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v helm >/dev/null || { echo "ERROR: helm CLI not found" >&2; exit 1; }

echo "[1/3] Lint the parent chart and local realm subchart"
helm lint "$CHART_DIR" --strict
helm lint "$CHART_DIR/charts/realm" --strict

echo "[2/3] Render the complete stack"
helm template identity "$CHART_DIR" --namespace identity-demo -f "$CHART_DIR/values-local.yaml" >/dev/null

echo "[3/3] Render the external PostgreSQL variant (no PostgreSQL resources)"
helm template identity "$CHART_DIR" --namespace identity-demo \
  --set postgresql.enabled=false \
  --set database.host=postgresql.external.svc.cluster.local \
  --set postgresql.persistence.enabled=false >/dev/null

echo "PASS: Helm chart lint and template checks succeeded."
