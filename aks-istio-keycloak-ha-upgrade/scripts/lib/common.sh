#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034
# =============================================================================
# scripts/lib/common.sh — helpers shared by every script in this project.
# It is "sourced" (loaded) by the other scripts and never run on its own.
# It gives each script: strict error handling, a log file, a step journal,
# a small key/value state store, and a few wrappers around helm/kubectl/curl.
# =============================================================================

# Stop at the first failing command (-e), treat unset variables as errors (-u),
# fail a pipeline when any command in it fails (pipefail), and let the error
# trap below also fire inside functions (-E).
set -Eeuo pipefail

# Absolute path of the project folder (two levels above this file).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Load all version numbers (old and new).
# shellcheck source=../../config/versions.env
source "${ROOT_DIR}/config/versions.env"
# Load names, sizes and switches.
# shellcheck source=../../config/env.sh
source "${ROOT_DIR}/config/env.sh"

# Folder for generated files: kubeconfig, certificates, passwords, backups.
STATE_DIR="${ROOT_DIR}/.state"
# Folder for log files.
LOG_DIR="${ROOT_DIR}/logs"
# Folder for values files that the scripts generate before calling Helm.
RENDER_DIR="${STATE_DIR}/rendered"
# Folder for the private certificate authority and the wildcard certificate.
TLS_DIR="${STATE_DIR}/tls"
# Folder for local copies of database dumps and cluster snapshots.
BACKUP_DIR="${STATE_DIR}/backups"
# File that remembers facts between scripts (public IP, active versions, ...).
STATE_FILE="${STATE_DIR}/state.env"
# File that holds the generated passwords (never commit it).
SECRETS_FILE="${STATE_DIR}/secrets.env"
# One-line-per-step journal across all scripts.
STEPS_LOG="${LOG_DIR}/steps.log"
# Create the folders if this is the first run.
mkdir -p "${STATE_DIR}/bin" "${LOG_DIR}" "${RENDER_DIR}" "${TLS_DIR}" "${BACKUP_DIR}"
# Only the current user may read the state folder (it contains passwords).
chmod 700 "${STATE_DIR}"

# Use a kubeconfig that belongs to this project only, so the scripts can never
# touch another cluster you happen to be logged in to.
export KUBECONFIG="${STATE_DIR}/kubeconfig"
# Let the scripts find tools they downloaded themselves (istioctl).
export PATH="${STATE_DIR}/bin:${PATH}"

# Load remembered facts from earlier scripts, if there are any.
# shellcheck disable=SC1090
if [[ -f "${STATE_FILE}" ]]; then source "${STATE_FILE}"; fi
# Load generated passwords from earlier scripts, if there are any.
# shellcheck disable=SC1090
if [[ -f "${SECRETS_FILE}" ]]; then source "${SECRETS_FILE}"; fi

# Pick the StorageClass for shared (ReadWriteMany) volumes from the chosen backend.
if [[ "${STORAGE_BACKEND}" == "azurefiles-nfs" ]]; then SHARED_STORAGE_CLASS="azurefile-csi-nfs"; else SHARED_STORAGE_CLASS="nfs"; fi

# Name of the running script without folder and ".sh".
SCRIPT_NAME="$(basename "$0" .sh)"
# Each run of each script gets its own time-stamped log file.
LOG_FILE="${LOG_DIR}/$(date +%Y%m%d-%H%M%S)-${SCRIPT_NAME}.log"
# Remember when the script started, to report how long it took.
START_TS="$(date +%s)"
# Counter used to number the steps inside one script.
STEP_NO=0

# ----------------------------------------------------------------------------
# Logging: copy everything the script prints (stdout and stderr) into LOG_FILE.
# A named pipe plus a background "tee" is used because it works on every bash
# version (macOS still ships bash 3.2) and lets us wait for the last line.
# ----------------------------------------------------------------------------
# Path of the temporary named pipe.
LOG_PIPE="${STATE_DIR}/.log-pipe.$$"
# Create the pipe.
mkfifo "${LOG_PIPE}"
# Start tee: it reads the pipe, prints to the terminal and appends to the log.
# It ignores Ctrl-C so the last lines of an interrupted script are still logged.
(trap '' INT; exec tee -a "${LOG_FILE}" < "${LOG_PIPE}") &
# Remember the process id of tee so we can wait for it at the end.
TEE_PID=$!
# From now on send stdout and stderr of this script into the pipe.
exec > "${LOG_PIPE}" 2>&1
# The file name is no longer needed; the open pipe stays alive until we exit.
rm -f "${LOG_PIPE}"

# Print one log line with a time stamp and a level (INFO, WARN, ...).
log() { printf '%s [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }
# Normal progress message.
info() { log INFO "$*"; }
# Something looks odd but the script continues.
warn() { log WARN "$*"; }
# Success message.
ok() { log OK "$*"; }
# Append one line to the cross-script journal (UTC time | script | text).
journal() { printf '%s | %s | %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${SCRIPT_NAME}" "$*" >> "${STEPS_LOG}"; }
# Print an error, write it to the journal and stop the script.
fail() { log ERROR "$*"; journal "ERROR $*"; exit 1; }

# Announce a numbered step on screen and in the journal.
step() {
  # Increase the step counter.
  STEP_NO=$((STEP_NO + 1))
  # Print a visible separator with the step text.
  log STEP "---- ${STEP_NO}. $* ----"
  # Record the step in the journal.
  journal "STEP ${STEP_NO}: $*"
}

# Print a command and then run it, so the log shows exactly what was executed.
# Never use it for commands that carry a password on the command line.
run() {
  # Show the command line.
  log CMD "$*"
  # Execute it unchanged.
  "$@"
}

# Called automatically when any command fails.
on_error() {
  # $1 = line number, $2 = the command that failed.
  log ERROR "line $1: command failed: $2"
  # Tell the user where the full output is.
  log ERROR "full log: ${LOG_FILE}"
}
# Register the error handler.
trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR

# Temporary files that must be deleted when the script ends.
CLEANUP_PATHS=()
# Register a temporary file for deletion at the end of the script.
cleanup_add() {
  # Append the path to the list.
  CLEANUP_PATHS+=("$1")
}

# Called automatically when the script ends, successfully or not.
on_exit() {
  # Exit code of the script.
  local code=$?
  # Delete the registered temporary files. (The odd-looking expansion yields
  # nothing for an empty list without tripping "set -u" on bash 3.2.)
  local path
  # Remove them one by one.
  for path in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do rm -f "${path}"; done
  # Seconds since the script started.
  local took=$(( $(date +%s) - START_TS ))
  # Write the result to the journal and to the screen.
  if (( code == 0 )); then journal "DONE in ${took}s"; ok "${SCRIPT_NAME} finished in ${took}s (log: ${LOG_FILE})"; else journal "FAILED exit=${code} after ${took}s log=${LOG_FILE}"; fi
  # Close stdout and stderr so tee sees "end of file" ...
  exec 1>&- 2>&-
  # ... and wait until tee has written the last line.
  wait "${TEE_PID}" 2>/dev/null || true
}
# Register the exit handler.
trap on_exit EXIT

# Write the first journal line for this script.
journal "START (log=${LOG_FILE})"

# Stop with a helpful message when a required program is missing.
require_cmd() {
  # $1 = program name, $2 = hint how to install it.
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is not installed. ${2:-}"
}

# Store KEY=VALUE in a file, replacing an older value of the same key.
kv_set() {
  # $1 = file, $2 = key, $3 = value.
  local file="$1" key="$2" value="$3"
  # Make sure the file exists.
  touch "${file}"
  # Copy every line except the old value of this key.
  grep -v "^${key}=" "${file}" > "${file}.tmp" || true
  # Add the new value (single quotes keep it literal when the file is sourced).
  printf "%s='%s'\n" "${key}" "${value}" >> "${file}.tmp"
  # Replace the file in one move.
  mv "${file}.tmp" "${file}"
  # Keep the file private.
  chmod 600 "${file}"
}

# Remember a fact for later scripts and make it available right now.
state_set() {
  # Save it to the state file.
  kv_set "${STATE_FILE}" "$1" "$2"
  # Set the shell variable with the same name.
  printf -v "$1" '%s' "$2"
  # Note the change in the journal.
  journal "STATE $1=$2"
}

# Print a remembered fact, or the default given as second argument.
state_get() {
  # Read the variable whose name is in $1 (empty if it does not exist).
  local value="${!1:-}"
  # Print it, falling back to the default.
  printf '%s' "${value:-${2:-}}"
}

# Read the state file again (a script that was started with run_script may
# have changed it in the meantime).
state_reload() {
  # Source the file when it exists.
  # shellcheck disable=SC1090
  if [[ -f "${STATE_FILE}" ]]; then source "${STATE_FILE}"; fi
}

# Stop when a fact that an earlier script should have stored is missing.
require_state() {
  # $1 = key, $2 = which script creates it.
  [[ -n "${!1:-}" ]] || fail "'$1' is not known yet. Run $2 first."
}

# Create a random password once and remember it; later calls reuse it.
secret_ensure() {
  # $1 = variable name, $2 = optional readable prefix.
  local name="$1" prefix="${2:-}"
  # Nothing to do when the secret already exists.
  if [[ -n "${!name:-}" ]]; then return 0; fi
  # 24 random hex characters are safe to pass through YAML, JSON and URLs.
  local value
  # Optional prefix + random part.
  value="${prefix}$(openssl rand -hex 12)"
  # Save it to the secrets file.
  kv_set "${SECRETS_FILE}" "${name}" "${value}"
  # Set the shell variable with the same name.
  printf -v "${name}" '%s' "${value}"
}

# Ask a yes/no question; returns success only for "y".
confirm() {
  # Skip the question when ASSUME_YES=true.
  if [[ "${ASSUME_YES}" == "true" ]]; then return 0; fi
  # Show the question.
  printf '%s [y/N] ' "$1"
  # Read the answer from the keyboard.
  local answer=""
  # "|| true": pressing Ctrl-D (no answer) counts as "no" instead of an error.
  read -r answer || true
  # Succeed only for y or Y.
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

# Stop when the project kubeconfig does not exist yet.
require_cluster() {
  # The file is written by install/08-get-credentials.sh.
  [[ -s "${KUBECONFIG}" ]] || fail "No kubeconfig yet. Run scripts/install/08-get-credentials.sh first."
}

# Print the major version of the installed Helm (3 or 4).
helm_major() {
  # "helm version --short" prints for example v4.3.0+gabc123.
  local major
  # sed keeps only the digits after the leading "v".
  major="$(helm version --short 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
  # Fall back to 3 when the output could not be read.
  if [[ "${major}" =~ ^[0-9]+$ ]]; then printf '%s' "${major}"; else printf '%s' '3'; fi
}

# Print "--rollback-on-failure" for Helm 4 and "--atomic" for Helm 3.
# Both do the same: if an upgrade fails, Helm puts the previous version back.
helm_rollback_flag() {
  # Choose the flag name by major version.
  if (( $(helm_major) >= 4 )); then printf '%s' '--rollback-on-failure'; else printf '%s' '--atomic'; fi
}

# Install a Helm release, or upgrade it when it already exists.
helm_deploy() {
  # $1 = release name, $2 = chart, $3 = namespace, the rest = extra Helm options.
  local release="$1" chart="$2" namespace="$3"
  # Drop the three named arguments so "$@" holds only the extra options.
  shift 3
  # --wait: do not return before the pods are ready. The rollback flag makes a
  # failed upgrade undo itself, so a broken release never stays half-applied.
  run helm upgrade --install "${release}" "${chart}" --namespace "${namespace}" --wait --timeout "${HELM_TIMEOUT}" "$(helm_rollback_flag)" "$@"
}

# Uninstall a Helm release when it exists; do nothing otherwise.
helm_remove() {
  # $1 = release, $2 = namespace.
  if helm status "$1" --namespace "$2" >/dev/null 2>&1; then
    # --wait returns only after all objects of the release are gone.
    run helm uninstall "$1" --namespace "$2" --wait --timeout "${HELM_TIMEOUT}"
  else
    # Nothing to remove.
    info "Helm release $1 is not installed in namespace $2 - nothing to do"
  fi
}

# Wait until no pod matches a label selector any more.
wait_pods_gone() {
  # $1 = namespace, $2 = label selector, $3 = seconds to wait.
  local namespace="$1" selector="$2" timeout="${3:-300}" waited=0 left
  # Check every 5 seconds.
  while true; do
    # Count the pods that still exist (tr removes the spaces macOS wc prints).
    left="$(kubectl --namespace "${namespace}" get pods --selector "${selector}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    # None left: done.
    if (( left == 0 )); then ok "no pods with ${selector} left in ${namespace}"; return 0; fi
    # Out of time: stop the script with an error.
    if (( waited >= timeout )); then fail "${left} pod(s) with ${selector} still exist in ${namespace} after ${timeout}s"; fi
    # Wait a little before the next check.
    sleep 5
    # Count the waiting time.
    waited=$((waited + 5))
  done
}

# Print the current revision number of a Helm release (empty if not installed).
helm_revision() {
  # $1 = release, $2 = namespace.
  local revision
  # "helm history --max 1" prints the newest revision as JSON. tr joins the
  # lines; sed pulls the number out of "revision":3 - with or without spaces
  # or quotes around the number, so every Helm version is understood.
  revision="$(helm history "$1" --namespace "$2" --max 1 --output json 2>/dev/null | tr -d '\n' | sed -E 's/.*"revision":[[:space:]]*"?([0-9]+)"?.*/\1/')"
  # Print it only when it really is a number.
  if [[ "${revision}" =~ ^[0-9]+$ ]]; then printf '%s' "${revision}"; fi
}

# Run another script of this project as its own step (used by the "-all" scripts).
run_script() {
  # $1 = path below scripts/, the rest = arguments for that script.
  local script="$1"
  # Drop the script name so "$@" holds only its arguments.
  shift
  # Announce it in this script's log and in the journal.
  step "run ${script} $*"
  # Start it with bash; a failure stops the calling script too (set -e).
  bash "${ROOT_DIR}/scripts/${script}" "$@"
}

# Wait until a Deployment or StatefulSet has finished rolling out.
wait_rollout() {
  # $1 = namespace, $2 = kind/name, $3 = optional timeout.
  run kubectl --namespace "$1" rollout status "$2" --timeout="${3:-10m}"
}

# Print a manifest with the __PLACEHOLDERS__ replaced by real values.
render() {
  # $1 = path of the manifest template. "|" is the sed delimiter because the
  # values contain dots and slashes.
  sed -e "s|__BASE_DOMAIN__|${BASE_DOMAIN:-}|g" \
      -e "s|__EGRESS_HOST__|${EGRESS_TEST_HOST}|g" \
      -e "s|__ISTIO_TAG__|${ISTIO_TAG}|g" \
      -e "s|__POSTGRES_ACTIVE_RELEASE__|${POSTGRES_ACTIVE_RELEASE:-}|g" \
      -e "s|__SHARED_STORAGE_CLASS__|${SHARED_STORAGE_CLASS}|g" \
      -e "s|__NFS_BACKING_DISK_SKU__|${NFS_BACKING_DISK_SKU}|g" \
      -e "s|__BACKUP_VOLUME_SIZE__|${BACKUP_VOLUME_SIZE}|g" \
      -e "s|__SHARED_NOTES_SIZE__|${SHARED_NOTES_SIZE}|g" "$1"
}

# Render a manifest and apply it to the cluster.
kapply() {
  # Show which file is applied.
  info "applying $1"
  # Replace placeholders and hand the result to kubectl.
  render "$1" | kubectl apply -f -
}

# curl that trusts our private CA and reaches the three host names through the
# public IP directly, so the scripts work even where nip.io DNS is blocked.
curl_mesh() {
  # --resolve maps "host:port" to the load balancer IP without asking DNS.
  curl --silent --show-error --max-time 20 --cacert "${TLS_DIR}/ca.crt" \
    --resolve "app1.${BASE_DOMAIN}:443:${PUBLIC_IP}" --resolve "app1.${BASE_DOMAIN}:80:${PUBLIC_IP}" \
    --resolve "app2.${BASE_DOMAIN}:443:${PUBLIC_IP}" --resolve "app2.${BASE_DOMAIN}:80:${PUBLIC_IP}" \
    --resolve "keycloak.${BASE_DOMAIN}:443:${PUBLIC_IP}" --resolve "keycloak.${BASE_DOMAIN}:80:${PUBLIC_IP}" "$@"
}

# Print only the HTTP status code of a URL ("000" when the connection failed).
http_code() {
  # -o /dev/null drops the body; -w prints the status code.
  curl_mesh --output /dev/null --write-out '%{http_code}' "$@" 2>/dev/null || true
}

# Compare an HTTP status code with the expected one and log the result.
expect_code() {
  # $1 = description, $2 = expected code, the rest = curl arguments.
  local what="$1" want="$2"
  # Drop the two named arguments.
  shift 2
  # Fetch the real status code.
  local got
  # http_code prints the three-digit status.
  got="$(http_code "$@")"
  # Pass or fail.
  if [[ "${got}" == "${want}" ]]; then ok "${what}: HTTP ${got}"; else fail "${what}: expected HTTP ${want} but got ${got}"; fi
}

# Wait until a URL answers with the expected HTTP status code.
wait_http() {
  # $1 = description, $2 = expected code, $3 = seconds to wait, the rest = curl arguments.
  local what="$1" want="$2" timeout="$3" waited=0 got
  # Drop the three named arguments.
  shift 3
  # Try every 5 seconds until the code matches or the time is up.
  while true; do
    # Fetch the current status code.
    got="$(http_code "$@")"
    # Success: report and return.
    if [[ "${got}" == "${want}" ]]; then ok "${what}: HTTP ${got}"; return 0; fi
    # Out of time: stop the script with an error.
    if (( waited >= timeout )); then fail "${what}: expected HTTP ${want} but still got ${got} after ${timeout}s"; fi
    # Wait a little before the next try.
    sleep 5
    # Count the waiting time.
    waited=$((waited + 5))
  done
}
