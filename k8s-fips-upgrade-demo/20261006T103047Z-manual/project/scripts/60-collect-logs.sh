#!/usr/bin/env bash
# 60-collect-logs.sh - gathers the logs of every moving part into logs/collected-<time>/ (pods, proxies, Istio, FreeIPA, events).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init collect-logs "$@"
need kubectl
OUT="$LOG_DIR/collected-$(utc_stamp)"; mkdir -p "$OUT"
step "Cluster overview and events"
k get pods -A -o wide > "$OUT/pods.txt" 2>&1 || true
k get events -A --sort-by=.lastTimestamp > "$OUT/events.txt" 2>&1 || true
step "Logs of every container (app, sidecar proxies, gateway, istiod)"
for ns in "$APP_NS" "$INGRESS_NS" "$ISTIO_NS"; do
  for pod in $(k -n "$ns" get pods -o name 2>/dev/null || true); do
    k -n "$ns" logs "$pod" --all-containers --prefix --tail=2000 > "$OUT/$ns-${pod##*/}.log" 2>&1 || true
    log "saved $ns/${pod##*/}"
  done
done
step "FreeIPA log"
ipa_logs "$OUT/freeipa.log" || warn "could not read the FreeIPA log"
ok "everything is in $OUT ($(find "$OUT" -type f | wc -l | tr -d ' ') files)"
