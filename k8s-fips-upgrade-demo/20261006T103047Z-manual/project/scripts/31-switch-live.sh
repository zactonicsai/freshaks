#!/usr/bin/env bash
# 31-switch-live.sh blue|green - the traffic switch on its own (used to roll forward again after a fast rollback).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init switch-live "$@"
need kubectl
side="${1:-}"
case "$side" in
  blue)  secret=fipsdemo-tls-v1; expect=nonfips ;;
  green) secret=fipsdemo-tls-v2; expect=fips ;;
  *) die "usage: 31-switch-live.sh blue|green" ;;
esac
ready="$(k -n "$APP_NS" get deployment "fipsdemo-$side" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
[ "${ready:-0}" -ge 1 ] || die "side '$side' has no ready pods"
k -n "$INGRESS_NS" get secret "$secret" >/dev/null 2>&1 || die "certificate secret $secret is missing"
log "live side now: '$(live_track)'  ->  switching to: '$side'"
apply_routing "$side" "$secret"
sleep 5
run_script 06-test.sh "$expect"
