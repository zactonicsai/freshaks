#!/usr/bin/env bash
# =============================================================================
# probe-loop.sh — the loop of the availability probe. It runs INSIDE the tools
# container (started by availability-probe.sh), not on your machine, and does
# not use the shared library.
# Once per interval it requests one page of each service through the edge
# load balancer and appends "time,target,http_code,seconds" to a CSV file.
# Usage (inside the container):
#   probe-loop.sh CSV_FILE STOP_FILE INTERVAL HTTPS_PORT PUBLIC_DOMAIN
# =============================================================================
# Treat unset variables as errors. (No "-e": a failed request must not end the loop.)
set -u
# File to append the results to.
csv="$1"
# The loop ends as soon as this file exists.
stop_file="$2"
# Seconds between two rounds.
interval="$3"
# Port the edge load balancer listens on.
https_port="$4"
# Host suffix as the browser sees it, e.g. localhost:8443.
public_domain="$5"

# Loop until availability-probe.sh creates the stop file.
while [[ ! -e "${stop_file}" ]]; do
  # Time stamp of this round.
  now="$(date '+%Y-%m-%dT%H:%M:%S')"
  # One request per service.
  for target in app1 app2 keycloak; do
    # The applications answer on /api/info; Keycloak on its discovery document.
    if [[ "${target}" == "keycloak" ]]; then url="https://keycloak.${public_domain}/realms/demo/.well-known/openid-configuration"; else url="https://${target}.${public_domain}/api/info"; fi
    # --max-time 3: an answer slower than 3 seconds counts as a failure.
    # --connect-to sends every request to the edge container. The output is
    # "status,seconds", for example "200,0.045".
    result="$(curl --silent --max-time 3 --cacert .state/tls/ca.crt --connect-to "::edge:${https_port}" --output /dev/null --write-out '%{http_code},%{time_total}' "${url}" 2>/dev/null || true)"
    # Append one CSV line ("000,0" when curl printed nothing at all).
    printf '%s,%s,%s\n' "${now}" "${target}" "${result:-000,0}" >> "${csv}"
  done
  # Wait before the next round.
  sleep "${interval}"
done
