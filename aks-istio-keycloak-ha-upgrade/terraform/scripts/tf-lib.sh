#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# terraform/scripts/tf-lib.sh — helpers shared by the Terraform scripts.
# Sourced after scripts/lib/common.sh; never run on its own.
# =============================================================================

# Folder that holds the three layers (01-infra, 02-platform, 03-workloads).
TF_DIR="${ROOT_DIR}/terraform"

# Pick the program: the value of TF_BIN when set, else OpenTofu, else Terraform.
if [[ -z "${TF_BIN:-}" ]]; then
  # OpenTofu is tried first; both read the same files.
  if command -v tofu >/dev/null 2>&1; then TF_BIN="tofu"; elif command -v terraform >/dev/null 2>&1; then TF_BIN="terraform"; else fail "Neither 'tofu' nor 'terraform' is installed. See https://opentofu.org/docs/intro/install/"; fi
fi

# Run tofu/terraform inside one layer and log the command.
tf() {
  # $1 = layer folder, the rest = the command and its options.
  local layer="$1"
  # Drop the layer so "$@" holds only the command.
  shift
  # -chdir runs the command as if started inside that folder.
  run "${TF_BIN}" -chdir="${TF_DIR}/${layer}" "$@"
}

# Print one output value of a layer (empty when the layer was not applied yet).
tf_output() {
  # $1 = layer folder, $2 = output name. -raw prints the bare value.
  "${TF_BIN}" -chdir="${TF_DIR}/$1" output -raw "$2" 2>/dev/null || true
}

# Options for "apply" and "destroy": ask for approval unless ASSUME_YES=true.
tf_approve_options() {
  # Start with an empty list: the plan is shown and you type "yes".
  # (The list is read by the scripts that source this file, which shellcheck
  # cannot see - hence the "disable" notes.)
  # shellcheck disable=SC2034
  TF_APPROVE=()
  # -auto-approve skips that question; -input=false makes sure nothing else
  # can stop and wait for the keyboard in an unattended run.
  # shellcheck disable=SC2034
  if [[ "${ASSUME_YES}" == "true" ]]; then TF_APPROVE=(-input=false -auto-approve); fi
}
