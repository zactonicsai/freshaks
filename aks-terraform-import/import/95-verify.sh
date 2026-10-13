#!/usr/bin/env bash
# =============================================================================
#  import/95-verify.sh — prove that Terraform state matches reality
# =============================================================================
#  * terraform state list           what Terraform now manages (counted by type)
#  * out/imports.csv                what the import scripts intended
#  * terraform plan -detailed-exitcode
#        exit 0  -> no changes: state == Azure == cluster   (the goal)
#        exit 2  -> plan has changes: generated HCL drifts from reality
#        other   -> plan error (provider auth, kubeconfig, TODOs ...)
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
require_tools terraform
cd "$TF_DIR" || die "cannot cd to $TF_DIR"

hr
log "Resources in state, by type:"
terraform state list 2>/dev/null | sed 's/\..*//' | sort | uniq -c | sort -rn | sed 's/^/    /'
in_state="$(terraform state list 2>/dev/null | wc -l | tr -d ' ')"
intended=0
if [[ -f "$IMPORT_LOG" ]]; then intended="$(tail -n +2 "$IMPORT_LOG" | wc -l | tr -d ' ')"; fi
log "In state: $in_state   Recorded by import scripts: $intended"
if [[ "$in_state" -lt "$intended" ]]; then
  warn "Fewer resources in state than were recorded. Compare 'terraform state list' with out/imports.csv."
fi

hr
log "terraform plan -detailed-exitcode"
set +e
terraform plan -input=false -detailed-exitcode >"$OUT_DIR/plan-verify.log" 2>&1
rc=$?
set -e
case "$rc" in
  0) ok "No changes. Terraform state matches the real infrastructure." ;;
  2) warn "Drift detected — review out/plan-verify.log. Common causes and fixes:"
     warn "  * node_count / replicas managed by autoscalers -> lifecycle { ignore_changes = [...] }"
     warn "  * tags added by Azure policy                   -> add them to HCL or ignore_changes = [tags]"
     warn "  * helm values formatting                        -> paste 'helm get values' output verbatim" ;;
  *) warn "Plan failed — see out/plan-verify.log" ;;
esac
exit "$rc"
