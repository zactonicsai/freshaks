#!/usr/bin/env bash
# =============================================================================
# availability-probe.sh — measure what users would notice during an upgrade.
# Once per second it requests one page of each service through the public
# load balancer and writes the result to a CSV file in logs/.
# Usage: ./scripts/tools/availability-probe.sh start    start it in the background
#        ./scripts/tools/availability-probe.sh stop     stop it
#        ./scripts/tools/availability-probe.sh report   print availability per service
#        ./scripts/tools/availability-probe.sh run FILE run in the foreground (used by "start")
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# File that remembers the process id of the background probe.
pid_file="${STATE_DIR}/probe.pid"
# What to do: first argument.
mode="${1:-}"

# Pick the action.
case "${mode}" in
  start)
    # The public address and the host names must be known.
    require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"
    # Same script creates both.
    require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
    # Do not start a second probe when one is still running.
    if [[ -s "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then ok "probe already running (pid $(cat "${pid_file}"))"; exit 0; fi
    # One CSV file per probe run.
    csv="${LOG_DIR}/availability-$(date +%Y%m%d-%H%M%S).csv"
    # Write the header line.
    printf 'time,target,http_code,seconds\n' > "${csv}"
    # Remember the file for "report".
    state_set PROBE_CSV "${csv}"
    # Start this same script in "run" mode in the background. nohup keeps it
    # alive when the terminal closes; its output goes to /dev/null so it does
    # not hold on to the log of the script that started it.
    nohup bash "$0" run "${csv}" >/dev/null 2>&1 &
    # Remember its process id.
    printf '%s' "$!" > "${pid_file}"
    # Report success.
    ok "probe started (pid $!), writing to ${csv}"
    ;;
  run)
    # The public address and the host names must be known.
    require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"
    # Same script creates both.
    require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
    # The CSV file is the second argument.
    csv="${2:?usage: availability-probe.sh run FILE}"
    # "stop" ends this process with a TERM signal; treat that as a normal end.
    trap 'exit 0' TERM
    # Loop until the process is stopped.
    while true; do
      # Time stamp of this round.
      now="$(date '+%Y-%m-%dT%H:%M:%S')"
      # One request per service.
      for target in app1 app2 keycloak; do
        # The applications answer on /api/info; Keycloak on its discovery document.
        if [[ "${target}" == "keycloak" ]]; then url="https://keycloak.${BASE_DOMAIN}/realms/demo/.well-known/openid-configuration"; else url="https://${target}.${BASE_DOMAIN}/api/info"; fi
        # --max-time 3: an answer slower than 3 seconds counts as a failure.
        # The output is "status,seconds", for example "200,0.045".
        result="$(curl_mesh --max-time 3 --output /dev/null --write-out '%{http_code},%{time_total}' "${url}" 2>/dev/null || true)"
        # Append one CSV line ("000,0" when curl printed nothing at all).
        printf '%s,%s,%s\n' "${now}" "${target}" "${result:-000,0}" >> "${csv}"
      done
      # Wait before the next round.
      sleep "${PROBE_INTERVAL}"
    done
    ;;
  stop)
    # Nothing to stop when no pid file exists.
    if [[ ! -s "${pid_file}" ]]; then ok "probe is not running"; exit 0; fi
    # Ask the background process to end ("|| true": it may be gone already).
    kill "$(cat "${pid_file}")" 2>/dev/null || true
    # Forget the process id.
    rm -f "${pid_file}"
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
