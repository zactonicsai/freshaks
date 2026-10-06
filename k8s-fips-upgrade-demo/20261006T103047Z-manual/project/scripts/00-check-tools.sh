#!/usr/bin/env bash
# 00-check-tools.sh - checks that your computer has what the demo needs. Changes nothing.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init check-tools "$@"
missing=0
have() { # tool "how to get it"
  if command -v "$1" >/dev/null 2>&1; then ok "found $1"; else err "MISSING $1  ->  $2"; missing=$((missing + 1)); fi
}
step "Programs"
have docker   "https://docs.docker.com/get-docker/"
have kind     "https://kind.sigs.k8s.io/docs/user/quick-start/#installation (v0.33.0 or newer)"
have kubectl  "https://kubernetes.io/docs/tasks/tools/"
have istioctl "curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -   then add istio-$ISTIO_VERSION/bin to PATH"
have openssl  "install the 'openssl' package"
have curl     "install the 'curl' package"
have jq       "install the 'jq' package"
have zip      "install the 'zip' package"
have unzip    "install the 'unzip' package"
[ "$missing" -eq 0 ] || die "$missing program(s) missing. Install them and run this script again."

step "Versions"
log "docker   : $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'daemon not reachable')"
log "kind     : $(kind version 2>/dev/null)"
log "kubectl  : $(kubectl version --client 2>/dev/null | head -1)"
log "istioctl : $(istioctl version --remote=false 2>/dev/null | head -1)"
log "openssl  : $(openssl version)"
docker info >/dev/null 2>&1 || die "Docker is installed but not running (or you may not use it). Start Docker first."
if ! istioctl version --remote=false 2>/dev/null | grep -q "$ISTIO_VERSION"; then
  warn "istioctl is not version $ISTIO_VERSION. The demo was written for $ISTIO_VERSION (fips-140-3 needs 1.31 or newer)."
fi

step "Docker resources"
mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
mem_gb=$((mem_bytes / 1024 / 1024 / 1024))
if [ "$mem_gb" -lt 10 ]; then warn "Docker has about ${mem_gb} GB of memory. FreeIPA + 3 Kubernetes nodes + Istio want 10 GB or more."
else ok "Docker memory: about ${mem_gb} GB"; fi
cg="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo '?')"
if [ "$cg" = 2 ]; then ok "cgroup version 2"; else warn "cgroup version is '$cg'. Kubernetes 1.35+ needs cgroup v2."; fi
log "CPU type: $(uname -m)   (the demo was designed on x86_64)"

step "Is THIS computer's kernel in FIPS mode?"
if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)" = 1 ]; then ok "yes: kernel FIPS mode is ON. kind nodes will report FIPS = true."
else warn "no: kernel FIPS mode is OFF. The demo still runs, in PRACTICE mode (you learn the steps; it is not real FIPS)."; fi
ok "all checks done"
