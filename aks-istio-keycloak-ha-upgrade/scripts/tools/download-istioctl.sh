#!/usr/bin/env bash
# =============================================================================
# download-istioctl.sh — download the istioctl command-line tool of one Istio
# version into .state/bin (the scripts put that folder first in PATH).
# istioctl is optional: the upgrade scripts use it for extra checks when it is
# there ("istioctl x precheck", "istioctl proxy-status", "istioctl analyze").
# Usage: ./scripts/tools/download-istioctl.sh [VERSION]   (default: the active Istio version)
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Version: first argument, or the active version, or the old version.
version="${1:-${ISTIO_ACTIVE_VERSION:-${ISTIO_VERSION_OLD}}}"

# Announce the step.
step "Work out which build fits this computer"
# Operating system name as used in the Istio file names.
case "$(uname -s)" in
  # Linux builds are called "linux".
  Linux) os="linux" ;;
  # macOS builds are called "osx".
  Darwin) os="osx" ;;
  # Anything else is not supported by this helper.
  *) fail "Unsupported operating system $(uname -s). Download istioctl by hand from https://github.com/istio/istio/releases" ;;
esac
# Processor type as used in the Istio file names.
case "$(uname -m)" in
  # 64-bit Intel/AMD.
  x86_64 | amd64) arch="amd64" ;;
  # 64-bit ARM (Apple Silicon, Graviton, ...).
  arm64 | aarch64) arch="arm64" ;;
  # Anything else is not supported by this helper.
  *) fail "Unsupported processor $(uname -m)." ;;
esac
# File name and download address on GitHub.
file="istioctl-${version}-${os}-${arch}.tar.gz"
# Release assets of the Istio project.
url="https://github.com/istio/istio/releases/download/${version}/${file}"
# Show what will be downloaded.
info "${url}"

# Announce the step.
step "Download the archive and its checksum"
# --fail: treat HTTP errors as errors; --location: follow GitHub's redirect.
run curl --fail --silent --show-error --location --output "${STATE_DIR}/${file}" "${url}"
# The .sha256 file holds the expected checksum.
run curl --fail --silent --show-error --location --output "${STATE_DIR}/${file}.sha256" "${url}.sha256"
# Remove both downloads when the script ends.
cleanup_add "${STATE_DIR}/${file}"
# Second temporary file.
cleanup_add "${STATE_DIR}/${file}.sha256"

# Announce the step.
step "Verify the checksum"
# First word of the .sha256 file = expected value.
expected="$(cut -d' ' -f1 "${STATE_DIR}/${file}.sha256")"
# Linux has sha256sum, macOS has "shasum -a 256"; both print the value first.
if command -v sha256sum >/dev/null 2>&1; then actual="$(sha256sum "${STATE_DIR}/${file}" | cut -d' ' -f1)"; else actual="$(shasum -a 256 "${STATE_DIR}/${file}" | cut -d' ' -f1)"; fi
# Refuse a file that does not match.
[[ "${expected}" == "${actual}" ]] || fail "Checksum mismatch for ${file}: the download is damaged or was tampered with."
# Report success.
ok "checksum matches"

# Announce the step.
step "Unpack istioctl into ${STATE_DIR}/bin"
# The archive contains a single file called istioctl.
run tar -xzf "${STATE_DIR}/${file}" -C "${STATE_DIR}/bin" istioctl
# Make sure it may be executed.
chmod +x "${STATE_DIR}/bin/istioctl"
# Print the client version (--remote=false: do not ask the cluster).
run "${STATE_DIR}/bin/istioctl" version --remote=false
