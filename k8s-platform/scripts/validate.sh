#!/usr/bin/env bash
# Offline checks, safe to run on every pull request.
#   scripts/validate.sh [cluster ...]      default: every file in config/clusters
# For each cluster it checks the merged config and renders exactly what Argo CD
# will create, so a bad value fails here and not in the cluster.
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need yq helm "$TF"

if [[ $# -gt 0 ]]; then
  clusters=("$@")
else
  clusters=()
  for file in "$ROOT"/config/clusters/*.yaml; do
    clusters+=("$(basename "$file" .yaml)")
  done
fi

REQUIRED=".platform.name .platform.minKubernetesVersion .cluster.type .cluster.kubernetesVersion
  .gitops.repoURL .gitops.revision .gitops.argocd.chartVersion .gitops.argocd.appsChartVersion"

for cluster in "${clusters[@]}"; do
  load_config "$cluster"
  log "$cluster: config"
  for key in $REQUIRED; do
    [[ "$(cfg "$key // \"\"")" != "" ]] || die "$cluster: $key is missing"
  done

  log "$cluster: render what Argo CD will create"
  helm template platform "$ROOT/gitops/platform" \
    -f "$ROOT/config/global.yaml" -f "$ROOT/config/clusters/$cluster.yaml" >"$BUILD_DIR/applications.yaml"
  yq -N -r 'select(.kind == "Application") | "  " + .metadata.labels."platform/layer" + "/" + .metadata.name' "$BUILD_DIR/applications.yaml"

  # Render every app that uses the in-repo chart with its real values.
  for app in $(yq -N -r 'select(.spec.source.path == "charts/generic-app") | .metadata.name' "$BUILD_DIR/applications.yaml"); do
    APP="$app" yq 'select(.metadata.name == strenv(APP)) | .spec.source.helm.valuesObject' "$BUILD_DIR/applications.yaml" |
      helm template "$app" "$ROOT/charts/generic-app" -f - >"$BUILD_DIR/app-$app.yaml"
  done
done

log "terraform fmt"
"$TF" fmt -check -recursive "$ROOT/terraform"

# Optional: check every rendered manifest against the Kubernetes and CRD schemas.
if command -v kubeconform >/dev/null 2>&1; then
  log "kubeconform"
  kubeconform -strict -summary -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$ROOT"/.build/*/applications.yaml "$ROOT"/.build/*/app-*.yaml
fi

if command -v shellcheck >/dev/null 2>&1; then
  log "shellcheck"
  (cd "$ROOT" && shellcheck -x scripts/*.sh scripts/lib/*.sh terraform/clusters/*/kubeconfig.sh)
fi
log "All checks passed."
