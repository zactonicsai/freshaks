#!/usr/bin/env bash
# =============================================================================
#  destroy/90-reset-terraform-state.sh — forget resources Terraform no longer owns
# =============================================================================
#  Use after the CLI destroy path (destroy-all.sh) or whenever the real
#  infrastructure was removed outside Terraform. Otherwise the next
#  `terraform plan` would propose RE-CREATING everything in generated/*.tf.
#
#  What it does
#    1. terraform state pull  -> out/state-backup-<timestamp>.json   (safety copy)
#    2. terraform state rm    for every address in the state         (works with any backend)
#    3. moves generated/*.tf, helm-values/ and imports/*.tf to out/archive-<timestamp>/
#       so the working directory is clean for the next import run
#
#  Nothing in Azure or in the cluster is touched.
#
#  terraform commands used:
#     terraform state pull           dump the current state as JSON
#     terraform state list           every managed address
#     terraform state rm <addr>      drop an address from state without destroying anything
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
require_tools terraform
cd "$TF_DIR" || die "cannot cd to $TF_DIR"

ts="$(date +%Y%m%d-%H%M%S)"
if [[ ! -d .terraform ]]; then
  log "terraform/ was never initialised — only archiving generated files"
else
  count="$(terraform state list 2>/dev/null | wc -l | tr -d ' ')"
  hr
  warn "This removes $count resource(s) from the Terraform state (NOT from Azure)."
  confirm "reset"
  if [[ "$count" -gt 0 ]]; then
    terraform state pull >"$OUT_DIR/state-backup-$ts.json"
    ok "state backed up to out/state-backup-$ts.json"
    while IFS= read -r addr; do
      [[ -z "$addr" ]] && continue
      run terraform state rm "$addr" >/dev/null || warn "could not remove $addr"
    done < <(terraform state list 2>/dev/null)
    ok "state is now empty"
  fi
fi

archive="$OUT_DIR/archive-$ts"
mkdir -p "$archive"
for f in generated imports helm-values; do
  if [[ -d "$f" ]] && [[ -n "$(ls -A "$f" 2>/dev/null)" ]]; then
    mkdir -p "$archive/$f"
    mv "$f"/* "$archive/$f"/ 2>/dev/null || true
  fi
done
rm -f terraform.tfvars import.tfplan
hr
ok "Generated configuration archived to ${archive#$ROOT_DIR/}"
log "terraform/ now only contains versions.tf, providers.tf, variables.tf, backend.tf — ready for a fresh import."
