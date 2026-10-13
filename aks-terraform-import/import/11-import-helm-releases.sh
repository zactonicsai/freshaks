#!/usr/bin/env bash
# =============================================================================
#  import/11-import-helm-releases.sh — Helm releases
# =============================================================================
#   Object          Terraform resource type   Import ID
#   -------------   -----------------------   ----------------------
#   Helm release    helm_release              <namespace>/<release>
#
#  Unlike the Azure scripts, this one writes the resource {} blocks itself
#  (terraform/generated/helm_releases.tf) instead of relying on
#  -generate-config-out, because Terraform cannot recover two things from a
#  running release:
#    * the chart REPOSITORY — Helm only stores the chart name and version, not
#      where it was downloaded from. The script guesses it from the repos
#      configured on this machine (`helm search repo`), then from HELM_REPO_MAP
#      in config.env, and otherwise leaves a TODO you must fill in before
#      `terraform plan` will succeed.
#    * the user-supplied VALUES — exported with `helm get values` into
#      terraform/helm-values/<ns>__<release>.yaml and referenced via file().
#
#  helm commands used:
#     helm list -A -o json                        every release: name, namespace, chart, status
#     helm get metadata <rel> -n <ns> -o json     chart name and version split cleanly (helm >= 3.13)
#     helm get values <rel> -n <ns> -o yaml       the values the installer supplied (not the chart defaults)
#     helm search repo <chart> --version <v>      which configured repo offers that chart/version
#     helm repo list -o json                      repo name -> URL
# =============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_config
az_check
require_tools kubectl helm
aks_credentials
tf_import_begin helm

HELM_TF_FILE="$GENERATED_DIR/helm_releases.tf"
if [[ -f "$HELM_TF_FILE" ]]; then
  backup="$OUT_DIR/helm_releases.$(date +%Y%m%d-%H%M%S).tf.bak"
  cp "$HELM_TF_FILE" "$backup"
  warn "Existing generated/helm_releases.tf backed up to ${backup#$ROOT_DIR/} (it will be rewritten)"
fi
cat >"$HELM_TF_FILE" <<'EOF'
# -----------------------------------------------------------------------------
# helm_releases.tf — written by import/11-import-helm-releases.sh
#
# One helm_release per release found with `helm list -A`. Values were exported
# with `helm get values` into helm-values/. Any `repository = "TODO..."` must be
# replaced by the real chart repository (https://...) — or set
#   chart = "oci://<registry>/<path>/<chart>"   and drop `repository`
# for charts that came from an OCI registry — before `terraform plan` can run.
# -----------------------------------------------------------------------------

EOF

repos_json="$(helm repo list -o json 2>/dev/null || echo '[]')"

# guess_repository <chart> <version>  -> prints a repo URL or nothing
guess_repository() {
  local chart="$1" version="$2" pair key
  # 1. explicit mapping from config.env
  for pair in $HELM_REPO_MAP; do
    key="${pair%%=*}"
    if [[ "$key" == "$chart" ]]; then printf '%s' "${pair#*=}"; return 0; fi
  done
  # 2. a configured local repo that offers exactly this chart
  local hits repo_name
  hits="$(helm search repo "$chart" --version "$version" -o json 2>/dev/null || echo '[]')"
  repo_name="$(jq -r --arg c "$chart" '
      [ .[] | select((.name | split("/") | .[1]) == $c) ]
      | if length == 1 then (.[0].name | split("/") | .[0]) else empty end' <<<"$hits")"
  if [[ -n "$repo_name" ]]; then
    jq -r --arg r "$repo_name" '.[] | select(.name == $r) | .url' <<<"$repos_json"
  fi
}

todo_count=0
releases="$(helm list -A -o json)"
while IFS='|' read -r ns name chartver status; do
  [[ -z "$name" ]] && continue
  if is_system_ns "$ns"; then log "skip $ns/$name (system namespace)"; continue; fi
  # shellcheck disable=SC2086
  if in_list "$ns/$name" $HELM_SKIP_RELEASES; then log "skip $ns/$name (HELM_SKIP_RELEASES)"; continue; fi
  if [[ -n "$K8S_NAMESPACES" ]] && ! in_list "$ns" $K8S_NAMESPACES; then continue; fi
  hr
  log "Release $ns/$name ($chartver, $status)"

  # Chart name + version. `helm get metadata` (helm >= 3.13) separates them
  # cleanly; the fallback splits "<chart>-<version>" on the last dash.
  if meta="$(helm get metadata "$name" -n "$ns" -o json 2>/dev/null)"; then
    chart="$(jq -r '.chart' <<<"$meta")"
    version="$(jq -r '.version' <<<"$meta")"
  else
    chart="${chartver%-*}"
    version="${chartver##*-}"
  fi

  # User-supplied values -> helm-values/<ns>__<name>.yaml
  values_file=""
  vals="$(helm get values "$name" -n "$ns" -o yaml 2>/dev/null || true)"
  if [[ -n "$vals" && "$vals" != "null" ]]; then
    values_file="${ns}__${name}.yaml"
    printf '%s\n' "$vals" >"$HELM_VALUES_DIR/$values_file"
    ok "values -> terraform/helm-values/$values_file"
  fi

  repo="$(guess_repository "$chart" "$version")"
  if [[ -n "$repo" ]]; then ok "repository: $repo"; else warn "repository unknown for chart '$chart' — TODO left in helm_releases.tf"; todo_count=$((todo_count + 1)); fi

  label="$(tf_name "${ns}__${name}")"
  {
    printf '# Release %s/%s — chart %s %s (status: %s)\n' "$ns" "$name" "$chart" "$version" "$status"
    printf 'resource "helm_release" "%s" {\n' "$label"
    printf '  name       = "%s"\n' "$name"
    printf '  namespace  = "%s"\n' "$ns"
    printf '  chart      = "%s"\n' "$chart"
    printf '  version    = "%s"\n' "$version"
    if [[ -n "$repo" ]]; then
      printf '  repository = "%s"\n' "$repo"
    else
      printf '  # TODO: set the chart repository URL, or use chart = "oci://..." and remove this line\n'
      printf '  repository = "TODO-CHART-REPOSITORY-URL"\n'
    fi
    if [[ -n "$values_file" ]]; then
      printf '  values     = [file("${path.module}/helm-values/%s")]\n' "$values_file"
    fi
    printf '}\n\n'
  } >>"$HELM_TF_FILE"

  tf_import_add helm_release "$label" "${ns}/${name}" "Helm release $ns/$name"
done < <(jq -r '.[] | [.namespace, .name, .chart, .status] | join("|")' <<<"$releases")

hr
log "Resource blocks -> ${HELM_TF_FILE#$ROOT_DIR/}"
if [[ "$todo_count" -gt 0 ]]; then
  warn "$todo_count release(s) have an unknown chart repository. Fill in the TODOs (or HELM_REPO_MAP in config.env) before running import/90-apply-imports.sh."
fi
tf_import_end
