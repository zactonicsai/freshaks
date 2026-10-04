#!/usr/bin/env bash
# =============================================================================
# availability-probe.sh — measure what users would notice during an upgrade.
# Once per second a loop in the tools container requests one page of each
# service through the edge load balancer and writes the result to a CSV file
# in logs/.
# Usage: ./scripts/tools/availability-probe.sh start    start it in the background
#        ./scripts/tools/availability-probe.sh stop     stop it
#        ./scripts/tools/availability-probe.sh report   print availability per service
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The loop ends when this file appears (see probe-loop.sh).
stop_file="${STATE_DIR}/probe.stop"
# What to do: first argument.
mode="${1:-}"

# Pick the action.
case "${mode}" in
  start)
    # Stop when the cluster is not running.
    require_cluster
    # The probe needs the CA certificate to verify the gateway.
    [[ -s "${TLS_DIR}/ca.crt" ]] || fail "No certificate yet. Run scripts/install/05-apply-mesh-rules.sh first."
    # Do not start a second probe when one is still running in the container.
    if in_tools pgrep -f probe-loop.sh >/dev/null 2>&1; then ok "probe already running"; exit 0; fi
    # A stop file from an earlier run would end the new loop at once.
    rm -f "${stop_file}"
    # One CSV file per probe run.
    csv="${LOG_DIR}/availability-$(date +%Y%m%d-%H%M%S).csv"
    # Write the header line.
    printf 'time,target,http_code,seconds\n' > "${csv}"
    # Remember the file for "report".
    state_set PROBE_CSV "${csv}"
    # Start the loop inside the tools container. -d = detached: it keeps
    # running after this script has ended.
    run docker exec -d "${TOOLS_CONTAINER}" bash scripts/tools/probe-loop.sh "${csv}" "${stop_file}" "${PROBE_INTERVAL}" "${HTTPS_PORT}" "${PUBLIC_DOMAIN}"
    # Report success.
    ok "probe started, writing to ${csv}"
    ;;
  stop)
    # Creating the stop file ends the loop after its current round.
    touch "${stop_file}"
    # Report success.
    ok "probe stopped"
    ;;
  report)
    # The newest CSV file is remembered in the state file.
    require_state PROBE_CSV "scripts/tools/availability-probe.sh start"
    # Announce the step.
    step "Availability per service from ${PROBE_CSV}"
    # awk reads the CSV: column 2 = service, column 3 = HTTP status.
    # A request counts as good when the status is 200. "streak" counts failed
    # requests in a row; the longest streak shows the longest outage.
    awk -F, -v interval="${PROBE_INTERVAL}" '
      NR > 1 {
        total[$2]++
        if ($3 == 200) { good[$2]++; streak[$2] = 0 }
        else { streak[$2]++; if (streak[$2] > worst[$2]) worst[$2] = streak[$2] }
      }
      END {
        for (t in total) printf "%-9s requests=%d failed=%d availability=%.3f%% longest_failure_streak=%d (about %ds)\n", t, total[t], total[t] - good[t], 100 * good[t] / total[t], worst[t], worst[t] * interval
      }' "${PROBE_CSV}"
    ;;
  *)
    # Unknown or missing argument: explain the usage and stop with an error.
    fail "usage: availability-probe.sh start | stop | report"
    ;;
esac
