#!/usr/bin/env bash
# 07-expose-localhost.sh [app|gateway] [PORT] - opens a port on THIS computer (localhost) that leads to the demo.
#   app      (default, port 8080)  http://localhost:8080  -> straight into one app pod of the live side.
#            Easiest: no hosts file, no certificate. But it skips the gateway and the mesh (no TLS, no /mtls page).
#   gateway  (port 9443)           https://app.fipsdemo.test:9443 -> the Istio gateway, same as the built-in port 8443.
#            Use it when port 8443 is busy or the cluster was made without the port mapping.
# Runs until you press Ctrl+C.  SIDE=blue|green picks a side for "app".  LISTEN_ADDRESS=0.0.0.0 opens it to your network.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init expose-localhost "$@"
need kubectl
what="${1:-app}"; addr="${LISTEN_ADDRESS:-127.0.0.1}"
[ "$addr" = 127.0.0.1 ] || warn "listening on $addr: other computers on your network can reach the demo"
trap 'log "stopped"; exit 0' INT TERM
case "$what" in
  app)
    port="${2:-8080}"; side="${SIDE:-$(live_track)}"
    [ -n "$side" ] || die "the app is not deployed yet (scripts/05-deploy-nonfips.sh)"
    ok "open  http://localhost:$port   (side: $side, no gateway, no mesh)   Ctrl+C stops"
    k -n "$APP_NS" port-forward --address "$addr" "deployment/fipsdemo-$side" "$port:8080"
    ;;
  gateway)
    port="${2:-9443}"
    ok "open  https://$APP_HOSTNAME:$port   (needs '127.0.0.1 $APP_HOSTNAME' in your hosts file)   Ctrl+C stops"
    log "test: curl --cacert work/ipa/ca.crt --resolve $APP_HOSTNAME:$port:127.0.0.1 https://$APP_HOSTNAME:$port/"
    k -n "$INGRESS_NS" port-forward --address "$addr" service/istio-ingressgateway "$port:443"
    ;;
  *) die "usage: 07-expose-localhost.sh [app|gateway] [PORT]" ;;
esac
