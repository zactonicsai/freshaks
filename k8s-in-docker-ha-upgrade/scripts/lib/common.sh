#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034
# =============================================================================
# scripts/lib/common.sh — helpers shared by every script in this project.
# It is "sourced" (loaded) by the other scripts and never run on its own.
# It gives each script: strict error handling, a log file, a step journal,
# a small key/value state store, and wrappers that run kubectl, helm, curl and
# openssl INSIDE the tools container - so your machine only needs Docker.
# =============================================================================

# Stop at the first failing command (-e), treat unset variables as errors (-u),
# fail a pipeline when any command in it fails (pipefail), and let the error
# trap below also fire inside functions (-E).
set -Eeuo pipefail

# Absolute path of the project folder (two levels above this file).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Work from the project folder, so every path in the scripts can be written
# relative to it. The same relative paths are valid inside the tools
# container, where the project folder is mounted as /work.
cd "${ROOT_DIR}"
# Load all version numbers (old and new).
# shellcheck source=../../config/versions.env
source "${ROOT_DIR}/config/versions.env"
# Load names, sizes and switches.
# shellcheck source=../../config/env.sh
source "${ROOT_DIR}/config/env.sh"

# Folder for generated files: kubeconfig, certificates, passwords, backups.
# (Relative on purpose - see the "cd" above.)
STATE_DIR=".state"
# Folder for log files.
LOG_DIR="logs"
# Folder for values files that the scripts generate before calling Helm.
RENDER_DIR="${STATE_DIR}/rendered"
# Folder for the private certificate authority and the server certificate.
TLS_DIR="${STATE_DIR}/tls"
# Folder for database dumps and control-plane backups.
BACKUP_DIR="${STATE_DIR}/backups"
# File that remembers facts between scripts (active versions, ...).
STATE_FILE="${STATE_DIR}/state.env"
# File that holds the generated passwords (never commit it).
SECRETS_FILE="${STATE_DIR}/secrets.env"
# kubeconfig for a kubectl on YOUR machine (server = https://127.0.0.1:<API_PORT>).
KUBECONFIG_HOST="${STATE_DIR}/kubeconfig"
# kubeconfig used inside the tools container (server = https://server:6443).
KUBECONFIG_TOOLS="${STATE_DIR}/kubeconfig-internal"
# One-line-per-step journal across all scripts.
STEPS_LOG="${LOG_DIR}/steps.log"
# Create the folders if this is the first run.
mkdir -p "${LOG_DIR}" "${RENDER_DIR}" "${TLS_DIR}" "${BACKUP_DIR}"
# Only the current user may read the state folder (it contains passwords).
chmod 700 "${STATE_DIR}"

# The worker node names as a list, for loops: ("agent-1" "agent-2" "agent-3").
read -r -a AGENT_LIST <<< "${AGENT_NODES}"
# Names of the containers the scripts talk to (see docker-compose.yml).
TOOLS_CONTAINER="${PROJECT_NAME}-tools"
# The control-plane container.
SERVER_CONTAINER="${PROJECT_NAME}-server"
# Image of the tools container (built by docker compose from docker/tools).
TOOLS_IMAGE="${PROJECT_NAME}-tools:local"

# Load remembered facts from earlier scripts, if there are any. This comes
# AFTER the settings above on purpose: ports and names that were fixed at the
# first install (see state_pin below) win over whatever is set today.
# shellcheck disable=SC1090
if [[ -f "${STATE_FILE}" ]]; then source "${STATE_FILE}"; fi
# Load generated passwords from earlier scripts, if there are any.
# shellcheck disable=SC1090
if [[ -f "${SECRETS_FILE}" ]]; then source "${SECRETS_FILE}"; fi
# Host names as the browser sees them: "localhost:8443", or just the domain
# when the standard https port 443 is used.
if [[ "${HTTPS_PORT}" == "443" ]]; then PUBLIC_DOMAIN="${BASE_DOMAIN}"; else PUBLIC_DOMAIN="${BASE_DOMAIN}:${HTTPS_PORT}"; fi

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

# ----------------------------------------------------------------------------
# State: small facts and passwords that later scripts need
# ----------------------------------------------------------------------------

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

# Remember a setting the first time, and never change it afterwards. Used for
# ports and names that end up inside Keycloak and the certificates: a later
# run with other values (or in a new terminal without them) would break logins.
state_pin() {
  # $1 = variable name. Store its current value unless one is stored already.
  grep -q "^$1=" "${STATE_FILE}" 2>/dev/null || state_set "$1" "${!1}"
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
  # 12 random bytes from the operating system, printed as 24 hex characters
  # (safe to pass through YAML, JSON and URLs). od prints the bytes as hex,
  # tr removes the spaces and line breaks od adds.
  local value
  # Optional prefix + random part.
  value="${prefix}$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
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

# ----------------------------------------------------------------------------
# Docker: the cluster is a set of containers described in docker-compose.yml
# ----------------------------------------------------------------------------

# Print the state key that holds the version of a node: agent-1 -> K8S_AGENT_1_VERSION
node_version_key() {
  # tr turns lowercase into uppercase and "-" into "_".
  printf 'K8S_%s_VERSION' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

# Write the file ".env" that docker-compose.yml reads: versions, ports and the
# cluster token. It is rewritten whenever a node version changes, so a plain
# "docker compose up -d" always describes the cluster as the scripts left it.
write_compose_env() {
  # The token and the server version must exist before the file makes sense.
  [[ -n "${K3S_TOKEN:-}" && -n "${K8S_SERVER_VERSION:-}" ]] || fail "The cluster is not set up yet. Run scripts/install/02-start-cluster.sh first."
  # The subshell with "umask 077" makes the file readable for you alone
  # (it contains the cluster token).
  (
    # New files are created without any rights for "group" and "others".
    umask 077
    # Write the file; the shell fills in the variables.
    cat > .env <<ENV
# Generated by scripts/lib/common.sh - do not edit, do not commit.
# docker-compose.yml reads these values.
K3S_TOKEN=${K3S_TOKEN}
K3S_IMAGE=${K3S_IMAGE}
K3S_SERVER_VERSION=${K8S_SERVER_VERSION}
K3S_AGENT_1_VERSION=${K8S_AGENT_1_VERSION}
K3S_AGENT_2_VERSION=${K8S_AGENT_2_VERSION}
K3S_AGENT_3_VERSION=${K8S_AGENT_3_VERSION}
SUBNET_PREFIX=${SUBNET_PREFIX}
HTTPS_PORT=${HTTPS_PORT}
API_PORT=${API_PORT}
REGISTRY_PORT=${REGISTRY_PORT}
HOST_UID=$(id -u)
HOST_GID=$(id -g)
KUBECTL_VERSION=${KUBECTL_VERSION}
HELM_VERSION=${HELM_VERSION}
HAPROXY_IMAGE=${HAPROXY_IMAGE}
REGISTRY_IMAGE=${REGISTRY_IMAGE}
DOCKERHUB_USERNAME=${DOCKERHUB_USERNAME}
DOCKERHUB_TOKEN=${DOCKERHUB_TOKEN}
ENV
  )
}

# Run a command inside the tools container (no keyboard/pipe input).
in_tools() {
  # "docker exec" starts the command in the running container, in /work.
  docker exec "${TOOLS_CONTAINER}" "$@"
}

# The same, but pass this script's standard input on to the command
# (-i), for "something | kubectl apply -f -".
in_tools_stdin() {
  # -i keeps standard input open.
  docker exec -i "${TOOLS_CONTAINER}" "$@"
}

# kubectl, helm and openssl: the scripts call them like normal programs, and
# these three functions quietly run them in the tools container.
kubectl() { in_tools kubectl "$@"; }
# Helm 4 (see config/versions.env).
helm() { in_tools helm "$@"; }
# OpenSSL creates the certificates.
openssl() { in_tools openssl "$@"; }
# kubectl that reads a manifest from standard input.
kubectl_stdin() { in_tools_stdin kubectl "$@"; }

# Stop when the cluster containers are not running yet.
require_cluster() {
  # The kubeconfig is written by install/02-start-cluster.sh.
  [[ -s "${KUBECONFIG_TOOLS}" ]] || fail "No cluster yet. Run scripts/install/02-start-cluster.sh first."
  # "docker inspect" prints true when the tools container is running.
  [[ "$(docker inspect --format '{{.State.Running}}' "${TOOLS_CONTAINER}" 2>/dev/null || true)" == "true" ]] || fail "The container ${TOOLS_CONTAINER} is not running. Start the cluster with: docker compose up -d"
}

# ----------------------------------------------------------------------------
# Helm and kubectl helpers
# ----------------------------------------------------------------------------

# Install a Helm release, or upgrade it when it already exists.
helm_deploy() {
  # $1 = release name, $2 = chart, $3 = namespace, the rest = extra Helm options.
  local release="$1" chart="$2" namespace="$3"
  # Drop the three named arguments so "$@" holds only the extra options.
  shift 3
  # --wait: do not return before the pods are ready. --rollback-on-failure
  # (called --atomic in Helm 3): if the upgrade fails, Helm puts the previous
  # version back, so a broken release never stays half-applied.
  run helm upgrade --install "${release}" "${chart}" --namespace "${namespace}" --wait --timeout "${HELM_TIMEOUT}" --rollback-on-failure "$@"
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

# Print the current revision number of a Helm release (empty if not installed).
helm_revision() {
  # $1 = release, $2 = namespace.
  local revision
  # "helm history --max 1" prints the newest revision as JSON. tr joins the
  # lines; sed pulls the number out of "revision":3 - with or without spaces
  # or quotes around the number.
  revision="$(helm history "$1" --namespace "$2" --max 1 --output json 2>/dev/null | tr -d '\n' | sed -E 's/.*"revision":[[:space:]]*"?([0-9]+)"?.*/\1/')"
  # Print it only when it really is a number.
  if [[ "${revision}" =~ ^[0-9]+$ ]]; then printf '%s' "${revision}"; fi
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
  sed -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
      -e "s|__HTTPS_PORT__|${HTTPS_PORT}|g" \
      -e "s|__EGRESS_HOST__|${EGRESS_TEST_HOST}|g" \
      -e "s|__ISTIO_TAG__|${ISTIO_TAG}|g" \
      -e "s|__POSTGRES_ACTIVE_RELEASE__|${POSTGRES_ACTIVE_RELEASE:-}|g" \
      -e "s|__NFS_DISK_SIZE__|${NFS_DISK_SIZE}|g" \
      -e "s|__BACKUP_VOLUME_SIZE__|${BACKUP_VOLUME_SIZE}|g" \
      -e "s|__SHARED_NOTES_SIZE__|${SHARED_NOTES_SIZE}|g" "$1"
}

# Render a manifest and apply it to the cluster.
kapply() {
  # Show which file is applied.
  info "applying $1"
  # Replace placeholders and hand the result to kubectl through standard input.
  render "$1" | kubectl_stdin apply -f -
}

# ----------------------------------------------------------------------------
# HTTP checks: curl runs in the tools container and enters through the edge
# load balancer - the same path a browser takes, minus the port on your machine.
# ----------------------------------------------------------------------------

# curl that trusts our private CA and connects to the edge container whatever
# host name is in the URL.
curl_mesh() {
  # --connect-to "::edge:PORT" = "for every host and port, connect to edge:PORT
  # instead". The URL's host name is still used for TLS and the Host header.
  in_tools curl --silent --show-error --max-time 20 --cacert "${TLS_DIR}/ca.crt" --connect-to "::edge:${HTTPS_PORT}" "$@"
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
