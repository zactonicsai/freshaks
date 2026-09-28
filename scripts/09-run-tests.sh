#!/usr/bin/env bash
# =============================================================================
#  09-run-tests.sh — send in the inspectors: Go client, curl client, Playwright.
#  Each runs as a Kubernetes Job in namespace 'testing'; exit code = pass/fail.
#  Usage: 09-run-tests.sh [go|curl|playwright|all]
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
require_cmd kubectl envsubst
need_generated BASE_DOMAIN REGISTRY

WHICH="${1:-all}"
ensure_namespace "$NS_TESTS"
apply_template "$ROOT_DIR/k8s/tests/test-config.yaml"

run_job() { # job-name, manifest
  local name="$1" manifest="$2"
  kubectl -n "$NS_TESTS" delete job "$name" --ignore-not-found >/dev/null
  apply_template "$manifest"
  log "waiting for job/${name} (up to 15 min)..."
  set +e
  kubectl -n "$NS_TESTS" wait --for=condition=complete "job/${name}" --timeout=900s >/dev/null 2>&1
  local ok=$?
  set -e
  echo "----- logs: ${name} -----"
  kubectl -n "$NS_TESTS" logs "job/${name}" --all-containers --tail=-1 || true
  echo "-------------------------"
  if [[ $ok -eq 0 ]]; then log "PASS ${name}"; else warn "FAIL ${name}"; FAILED=$((FAILED+1)); fi
}

FAILED=0
if [[ "$WHICH" == "all" || "$WHICH" == "go" ]]; then
  step "Go inspector"
  run_job go-client-tests "$ROOT_DIR/k8s/tests/go-job.yaml"
fi
if [[ "$WHICH" == "all" || "$WHICH" == "curl" ]]; then
  step "curl inspector"
  kubectl -n "$NS_TESTS" create configmap curl-tests --from-file=run-tests.sh="$ROOT_DIR/tests/curl-client/run-tests.sh" \
    --dry-run=client -o yaml | kubectl apply -f -
  run_job curl-tests "$ROOT_DIR/k8s/tests/curl-job.yaml"
fi
if [[ "$WHICH" == "all" || "$WHICH" == "playwright" ]]; then
  step "Playwright inspector (a robot browser)"
  kubectl -n "$NS_TESTS" create configmap playwright-tests \
    --from-file=package.json="$ROOT_DIR/tests/playwright/package.json" \
    --from-file=playwright.config.js="$ROOT_DIR/tests/playwright/playwright.config.js" \
    --from-file=rbac.spec.js="$ROOT_DIR/tests/playwright/rbac.spec.js" \
    --dry-run=client -o yaml | kubectl apply -f -
  run_job playwright-tests "$ROOT_DIR/k8s/tests/playwright-job.yaml"
fi

if [[ $FAILED -eq 0 ]]; then log "ALL INSPECTORS PASSED"; else die "${FAILED} inspector(s) failed — see logs above and docs/12-troubleshooting.md"; fi
