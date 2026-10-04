#!/usr/bin/env bash
# =============================================================================
# 01-check-docker.sh — check that this machine can run the example.
# The only program you need is Docker (with the "docker compose" plugin):
# kubectl, helm, curl and openssl run inside a container.
# It changes nothing.
# Usage: ./scripts/install/01-check-docker.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Announce the step.
step "Check Docker"
# The docker program must be installed.
command -v docker >/dev/null 2>&1 || fail "'docker' is not installed. Install Docker Desktop or Docker Engine: https://docs.docker.com/get-docker/"
# "docker info" only works when the Docker engine is running.
docker info >/dev/null 2>&1 || fail "Docker is installed but not running (or you may not use it). Start Docker Desktop, or check 'docker info'."
# The compose plugin starts the containers described in docker-compose.yml.
docker compose version >/dev/null 2>&1 || fail "The 'docker compose' plugin is missing. See https://docs.docker.com/compose/install/"
# Show the versions for the log.
run docker version --format 'Docker client {{.Client.Version}}, engine {{.Server.Version}}'
# Show the compose version too.
run docker compose version

# Announce the step.
step "Check memory and CPUs that Docker may use"
# Total memory of the Docker engine in bytes (on macOS and Windows this is
# the size of Docker Desktop's virtual machine, not of your computer).
memory_bytes="$(docker info --format '{{.MemTotal}}')"
# Number of CPUs of the Docker engine.
cpus="$(docker info --format '{{.NCPU}}')"
# Convert bytes to whole gibibytes.
memory_gib=$(( memory_bytes / 1024 / 1024 / 1024 ))
# Show both numbers.
info "Docker has ${memory_gib} GiB of memory and ${cpus} CPUs"
# Four Kubernetes nodes, Istio, Keycloak (2 pods), PostgreSQL and four Java
# pods need about 7 GiB.
if (( memory_gib < 7 )); then warn "Less than 8 GiB of memory for Docker. Pods may be killed or stay Pending. Raise the limit in Docker Desktop > Settings > Resources."; else ok "memory is enough"; fi
# Many Java programs start at the same time.
if (( cpus < 4 )); then warn "Fewer than 4 CPUs for Docker. Everything works, but starts slowly."; else ok "CPUs are enough"; fi

# Announce the step.
step "Check how Docker isolates containers"
# "2" on every current system (Docker Desktop, recent Linux), "1" on old ones.
cgroup_version="$(docker info --format '{{.CgroupVersion}}')"
# Kubernetes 1.35 and newer refuse to start a node on the old "cgroup v1"
# layout. The install (1.34) would still work there, but the upgrade - the
# point of this example - would leave the nodes broken. Stop before that.
if [[ "${cgroup_version}" != "2" ]]; then fail "Docker runs with cgroup v${cgroup_version}. Kubernetes 1.35+ needs cgroup v2. Use a current Docker Desktop, or a Linux system that boots with cgroup v2."; fi
# Report success.
ok "cgroup v2"
# "Rootless" Docker cannot give the Kubernetes node containers the rights they need.
if docker info --format '{{.SecurityOptions}}' | grep -q rootless; then warn "Docker runs in rootless mode. The Kubernetes node containers need a normal (rootful) Docker engine and will probably not start."; fi

# Announce the step.
step "Settings that will be used"
# Where the applications will be reachable.
info "applications:  https://app1.${PUBLIC_DOMAIN}  https://app2.${PUBLIC_DOMAIN}  https://keycloak.${PUBLIC_DOMAIN}"
# Ports opened on this machine (only on 127.0.0.1).
info "ports on this machine: ${HTTPS_PORT} (https), ${API_PORT} (Kubernetes API), ${REGISTRY_PORT} (image registry)"
# Private network of the containers.
info "container network: ${SUBNET_PREFIX}.0/24"
# The Kubernetes path.
info "Kubernetes: ${K8S_VERSION_OLD} -> ${K8S_UPGRADE_PATH}"
# The Istio path.
info "Istio:      ${ISTIO_VERSION_OLD} -> ${ISTIO_UPGRADE_PATH}"
# Keycloak old and new.
info "Keycloak:   ${KEYCLOAK_VERSION_OLD} -> ${KEYCLOAK_VERSION_NEW}"
# PostgreSQL old and new.
info "PostgreSQL: ${POSTGRES_VERSION_OLD} -> ${POSTGRES_VERSION_NEW}"
# Application old and new.
info "demo app:   ${APP_VERSION_OLD} -> ${APP_VERSION_NEW}"
# Final message.
ok "this machine can run the example"
