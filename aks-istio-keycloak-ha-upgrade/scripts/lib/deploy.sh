#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/lib/deploy.sh — "how to deploy component X at version Y", in ONE place.
# The install, upgrade and rollback scripts all call these functions, so a
# component is always deployed the same way no matter which script does it.
# This file is sourced after common.sh and is never run on its own.
# =============================================================================

# ----------------------------------------------------------------------------
# Small version helpers
# ----------------------------------------------------------------------------

# Print the Istio revision name of a version: 1.28.1 -> 1-28-1
# (revision names may not contain dots).
istio_rev() {
  # tr replaces every "." with "-".
  printf '%s' "$1" | tr '.' '-'
}

# Print "major.minor" of a version: 1.28.1 -> 1.28
minor_of() {
  # cut keeps fields 1 and 2 of the dot-separated string.
  printf '%s' "$1" | cut -d. -f1,2
}

# Print the major number of a version: 18.6 -> 18
major_of() {
  # cut keeps field 1 of the dot-separated string.
  printf '%s' "$1" | cut -d. -f1
}

# Print the first version in the list $2 that is newer than $1.
# Prints nothing when $1 is already the newest.
next_version() {
  # $1 = current version, $2 = space-separated list of versions (oldest first).
  local current="$1" candidate lowest
  # Walk through the list (the unquoted $2 is split at the spaces on purpose).
  for candidate in $2; do
    # "sort -V" sorts version numbers; the first line is the lower of the two.
    lowest="$(printf '%s\n%s\n' "${current}" "${candidate}" | sort -V | head -n 1)"
    # The candidate is newer when it differs from current and current sorts first.
    if [[ "${candidate}" != "${current}" && "${lowest}" == "${current}" ]]; then printf '%s' "${candidate}"; return 0; fi
  done
}

# Print the Kubernetes minor version of the control plane, e.g. 1.34
k8s_server_minor() {
  # /version is answered by the API server itself; sed pulls "1.34" out of
  # "gitVersion":"v1.34.2" after tr removed spaces and line breaks.
  kubectl get --raw /version | tr -d ' \n' | sed -E 's/.*"gitVersion":"v([0-9]+\.[0-9]+).*/\1/'
}

# Print the Kubernetes minors that an Istio version officially supports.
# Source: https://istio.io/latest/docs/releases/supported-releases/ (Oct 2026).
istio_supported_k8s() {
  # $1 = Istio version. Only the minor (1.28, 1.29, ...) matters.
  case "$(minor_of "$1")" in
    # Istio 1.28 supports Kubernetes 1.30 to 1.34.
    1.28) printf '%s' '1.30 1.31 1.32 1.33 1.34' ;;
    # Istio 1.29 supports Kubernetes 1.31 to 1.35.
    1.29) printf '%s' '1.31 1.32 1.33 1.34 1.35' ;;
    # Istio 1.30 supports Kubernetes 1.32 to 1.36.
    1.30) printf '%s' '1.32 1.33 1.34 1.35 1.36' ;;
    # Istio 1.31 supports Kubernetes 1.32 to 1.36.
    1.31) printf '%s' '1.32 1.33 1.34 1.35 1.36' ;;
    # Unknown Istio line: print nothing, the caller warns.
    *) printf '%s' '' ;;
  esac
}

# Stop when Istio version $1 does not support Kubernetes minor $2.
check_istio_k8s() {
  # $1 = Istio version, $2 = Kubernetes minor such as 1.35.
  local istio_version="$1" k8s_minor="$2" supported
  # Look up the supported list.
  supported="$(istio_supported_k8s "${istio_version}")"
  # No data for this Istio line: warn and let the user check by hand.
  if [[ -z "${supported}" ]]; then warn "No support data for Istio ${istio_version}. Check https://istio.io/latest/docs/releases/supported-releases/"; return 0; fi
  # The spaces around both sides make sure 1.3 does not match 1.30.
  if [[ " ${supported} " == *" ${k8s_minor} "* ]]; then ok "Istio ${istio_version} supports Kubernetes ${k8s_minor}"; else fail "Istio ${istio_version} does not support Kubernetes ${k8s_minor} (supported: ${supported})"; fi
}

# ----------------------------------------------------------------------------
# Helm repositories
# ----------------------------------------------------------------------------

# Register the Istio chart repository and refresh its index.
ensure_istio_repo() {
  # --force-update replaces an older entry with the same name.
  run helm repo add istio "${ISTIO_HELM_REPO}" --force-update
  # Download the newest chart list of that repository only.
  run helm repo update istio
}

# Fill the array ISTIO_HELM_EXTRA with options that every Istio chart needs.
istio_helm_extra() {
  # Start with an empty list.
  ISTIO_HELM_EXTRA=()
  # Helm 4 applies manifests "server-side" by default. istiod edits two fields
  # of its own webhook objects after the install; with server-side apply a later
  # "helm upgrade" of Istio charts that still template those fields (1.28 does)
  # can stop with a "conflict" error. Client-side apply (what Helm 3 does) has
  # no such problem, so the Istio charts are always applied client-side.
  if (( $(helm_major) >= 4 )); then ISTIO_HELM_EXTRA+=(--server-side=false); fi
}

# ----------------------------------------------------------------------------
# Istio
# ----------------------------------------------------------------------------

# Install or upgrade the "base" chart: Istio's CRDs and the default validator.
deploy_istio_base() {
  # $1 = chart version, $2 = revision whose istiod validates Istio objects.
  local version="$1" default_revision="$2"
  # Make sure Helm knows the Istio repository.
  ensure_istio_repo
  # Collect the Helm-version specific options.
  istio_helm_extra
  # defaultRevision must always name an istiod that is installed: it is the
  # address of the webhook that checks every Istio object you apply.
  # (The odd-looking ${X[@]+"${X[@]}"} expands to nothing for an empty array
  # without tripping "set -u" on the old bash 3.2 that macOS ships.)
  helm_deploy istio-base istio/base istio-system --version "${version}" --set defaultRevision="${default_revision}" ${ISTIO_HELM_EXTRA[@]+"${ISTIO_HELM_EXTRA[@]}"}
}

# Install one istiod control plane as its own Helm release ("revision").
deploy_istiod() {
  # $1 = Istio version.
  local version="$1" rev
  # Revision name, e.g. 1-28-1.
  rev="$(istio_rev "${version}")"
  # Make sure Helm knows the Istio repository.
  ensure_istio_repo
  # Collect the Helm-version specific options.
  istio_helm_extra
  # Pull the images from a mirror when ISTIO_HUB is set.
  if [[ -n "${ISTIO_HUB}" ]]; then ISTIO_HELM_EXTRA+=(--set "global.hub=${ISTIO_HUB}"); fi
  # One release per version: "istiod-1-28-1" and "istiod-1-29-8" can run side
  # by side, which is what makes the canary upgrade and the rollback possible.
  helm_deploy "istiod-${rev}" istio/istiod istio-system --version "${version}" --values "${ROOT_DIR}/helm/values/istiod.yaml" --set revision="${rev}" ${ISTIO_HELM_EXTRA[@]+"${ISTIO_HELM_EXTRA[@]}"}
}

# Point the revision tag (ISTIO_TAG, "stable") at the istiod of a version.
set_revision_tag() {
  # $1 = Istio version the tag should point at.
  local version="$1" rev
  # Revision name, e.g. 1-28-1.
  rev="$(istio_rev "${version}")"
  # Make sure Helm knows the Istio repository.
  ensure_istio_repo
  # Tell the log what happens.
  info "pointing revision tag '${ISTIO_TAG}' at revision ${rev}"
  # Render only the two tag templates of the istiod chart (the injection
  # webhook "istio-revision-tag-<tag>" and the Service "istiod-revision-tag-<tag>")
  # and apply them. Applying again with another revision moves the tag.
  helm template "istiod-${rev}" istio/istiod --version "${version}" --namespace istio-system \
    --show-only templates/revision-tags-mwc.yaml --show-only templates/revision-tags-svc.yaml \
    --set "revisionTags={${ISTIO_TAG}}" --set revision="${rev}" | kubectl apply -f -
  # Show where the tag points now.
  run kubectl get mutatingwebhookconfiguration "istio-revision-tag-${ISTIO_TAG}" --output 'jsonpath={.metadata.labels.istio\.io/rev}{"\n"}'
}

# Install or upgrade the ingress gateway (public entry point).
deploy_ingress_gateway() {
  # $1 = chart version.
  local version="$1" generated="${RENDER_DIR}/istio-ingressgateway-azure.yaml"
  # The public IP must exist before the gateway can use it.
  require_state PUBLIC_IP "scripts/install/04-create-public-ip.sh"
  # Make sure Helm knows the Istio repository.
  ensure_istio_repo
  # Collect the Helm-version specific options.
  istio_helm_extra
  # Write a small values file with the two Azure annotations that tell the
  # cloud controller: "use the existing static IP <name> in resource group <rg>".
  cat > "${generated}" <<YAML
# Generated by scripts/lib/deploy.sh - do not edit.
service:
  annotations:
    # Resource group that holds the static public IP.
    service.beta.kubernetes.io/azure-load-balancer-resource-group: "${RESOURCE_GROUP}"
    # Name of the static public IP to attach to the load balancer.
    service.beta.kubernetes.io/azure-pip-name: "${PUBLIC_IP_NAME}"
YAML
  # revision=<tag> labels the gateway pods with istio.io/rev=<tag>, so they get
  # their proxy from whatever istiod the tag points at.
  helm_deploy istio-ingressgateway istio/gateway istio-ingress --version "${version}" --values "${ROOT_DIR}/helm/values/istio-ingressgateway.yaml" --values "${generated}" --set revision="${ISTIO_TAG}" ${ISTIO_HELM_EXTRA[@]+"${ISTIO_HELM_EXTRA[@]}"}
}

# Install or upgrade the egress gateway (controlled exit to the internet).
deploy_egress_gateway() {
  # $1 = chart version.
  local version="$1"
  # Make sure Helm knows the Istio repository.
  ensure_istio_repo
  # Collect the Helm-version specific options.
  istio_helm_extra
  # Same chart as the ingress gateway, different release name and values.
  helm_deploy istio-egressgateway istio/gateway istio-egress --version "${version}" --values "${ROOT_DIR}/helm/values/istio-egressgateway.yaml" --set revision="${ISTIO_TAG}" ${ISTIO_HELM_EXTRA[@]+"${ISTIO_HELM_EXTRA[@]}"}
}

# Restart both gateways so their pods are re-created with the current proxy.
restart_gateways() {
  # New pods start before old ones stop (rolling update), so traffic keeps flowing.
  run kubectl --namespace istio-ingress rollout restart deployment/istio-ingressgateway
  # Wait until every ingress pod is replaced.
  wait_rollout istio-ingress deployment/istio-ingressgateway
  # Same for the egress gateway.
  run kubectl --namespace istio-egress rollout restart deployment/istio-egressgateway
  # Wait until every egress pod is replaced.
  wait_rollout istio-egress deployment/istio-egressgateway
}

# Restart every workload in the mesh so it gets the sidecar of the active istiod.
restart_mesh_workloads() {
  # Names used in the loops below.
  local namespace workload
  # 1. PostgreSQL first. It is a single pod, so the database is away for some
  #    seconds; Keycloak reconnects on its own. Only the active release runs.
  run kubectl --namespace postgres rollout restart "statefulset/${POSTGRES_ACTIVE_RELEASE}"
  # Wait until the database pod is ready again.
  wait_rollout postgres "statefulset/${POSTGRES_ACTIVE_RELEASE}"
  # 2. Keycloak, then the applications: two pods each, replaced one by one.
  for namespace in keycloak apps; do
    # Restart all Deployments of the namespace.
    run kubectl --namespace "${namespace}" rollout restart deployment
    # Wait for each of them.
    for workload in $(kubectl --namespace "${namespace}" get deployment --output name); do
      # "workload" looks like deployment.apps/app1.
      wait_rollout "${namespace}" "${workload}"
    done
  done
}

# Print "namespace pod proxy-image" for every pod that has an Istio proxy.
mesh_proxy_report() {
  # The proxy is a normal container in older setups and an init container
  # ("native sidecar") in newer ones, so both lists are searched. awk keeps
  # only the lines that really have an image (three columns).
  kubectl get pods --all-namespaces --output jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .spec.initContainers[?(@.name=="istio-proxy")]}{.image}{end}{range .spec.containers[?(@.name=="istio-proxy")]}{.image}{end}{"\n"}{end}' | awk 'NF == 3'
}

# ----------------------------------------------------------------------------
# NFS storage
# ----------------------------------------------------------------------------

# Install or upgrade the NFS server pod and its StorageClass "nfs".
deploy_nfs() {
  # Register the chart repository.
  run helm repo add nfs-ganesha "${NFS_HELM_REPO}" --force-update
  # Download its newest chart list.
  run helm repo update nfs-ganesha
  # The release name equals the chart name, so all objects are simply called
  # "nfs-server-provisioner".
  helm_deploy nfs-server-provisioner nfs-ganesha/nfs-server-provisioner nfs-storage --version "${NFS_CHART_VERSION}" --values "${ROOT_DIR}/helm/values/nfs-server-provisioner.yaml" --set persistence.size="${NFS_DISK_SIZE}"
}

# ----------------------------------------------------------------------------
# PostgreSQL
# ----------------------------------------------------------------------------

# Print the Helm release name for a PostgreSQL version: 14.12 -> postgres-v14
postgres_release() {
  # One release per MAJOR version; minor updates reuse the release.
  printf 'postgres-v%s' "$(major_of "$1")"
}

# Install or upgrade one PostgreSQL release.
deploy_postgres() {
  # $1 = PostgreSQL version, $2 = replicas (1 = running, 0 = parked).
  local version="$1" replicas="${2:-1}"
  # --set-string keeps the tag a string. Plain --set would read 18.10 as the
  # number 18.1 and pull the wrong image.
  helm_deploy "$(postgres_release "${version}")" "${ROOT_DIR}/helm/charts/postgres" postgres --set image.repository="${POSTGRES_IMAGE_REPOSITORY}" --set-string image.tag="${version}" --set replicaCount="${replicas}" --set persistence.storageClass="${SHARED_STORAGE_CLASS}" --set persistence.size="${POSTGRES_DATA_SIZE}"
}

# Run one SQL statement as superuser inside a PostgreSQL pod and print the result.
pg_sql() {
  # $1 = release, $2 = database, $3 = SQL text.
  # No host is given, so psql uses the local socket, which needs no password.
  # --no-align --tuples-only prints bare values, easy to compare in scripts.
  kubectl --namespace postgres exec "$1-0" --container postgres -- psql --username postgres --dbname "$2" --no-align --tuples-only --set ON_ERROR_STOP=1 --command "$3"
}

# Print four numbers that describe the Keycloak database: tables|users|clients|realms
keycloak_db_fingerprint() {
  # $1 = release. Used to compare the old and the new database after a migration.
  pg_sql "$1" keycloak "SELECT (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'), (SELECT count(*) FROM user_entity), (SELECT count(*) FROM client), (SELECT count(*) FROM realm);"
}

# Dump the Keycloak database of the ACTIVE PostgreSQL to the shared backup
# volume and copy the file to this machine.
pg_backup() {
  # $1 = short label that becomes part of the file name.
  local label="$1" pod file
  # Pod of the active release.
  pod="${POSTGRES_ACTIVE_RELEASE}-0"
  # File name with label and time stamp.
  file="keycloak-${label}-$(date +%Y%m%d-%H%M%S).dump"
  # -Fc = compressed "custom" format that pg_restore understands. The password
  # is read from an environment variable inside the pod, so it never shows up
  # in this command line or in the log.
  run kubectl --namespace postgres exec "${pod}" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_dump --host 127.0.0.1 --username keycloak --dbname keycloak --format custom --file /backups/${file}"
  # Show the size of the dump.
  run kubectl --namespace postgres exec "${pod}" --container postgres -- ls -l "/backups/${file}"
  # Keep a second copy outside the cluster.
  run kubectl --namespace postgres cp --container postgres "${pod}:/backups/${file}" "${BACKUP_DIR}/${file}"
  # Remember the file name for the rollback scripts.
  state_set LAST_PG_BACKUP "${file}"
}

# ----------------------------------------------------------------------------
# Keycloak
# ----------------------------------------------------------------------------

# Install or upgrade Keycloak.
deploy_keycloak() {
  # $1 = Keycloak version, the rest = extra Helm options (for example
  # --set replicaCount=0 or --set updateStrategy=Recreate).
  local version="$1" style generated="${RENDER_DIR}/keycloak-generated.yaml"
  # Drop the version so "$@" holds only the extra options.
  shift
  # The public host names must be known.
  require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
  # The client secrets and the test password must exist.
  [[ -n "${APP1_CLIENT_SECRET:-}" && -n "${APP2_CLIENT_SECRET:-}" && -n "${TEST_USER_PASSWORD:-}" ]] || fail "Secrets are missing. Run scripts/install/18-create-secrets.sh first."
  # Keycloak 25 changed many setting names; pick the matching values file.
  if (( $(major_of "${version}") >= 25 )); then style="keycloak-current-v26.yaml"; else style="keycloak-legacy-v24.yaml"; fi
  # Write the generated values (host name, client secrets, test password) to a
  # private file. Passing them in a file keeps them out of the command line.
  # The subshell with "umask 077" makes the file readable for you alone.
  (
    # New files are created without any rights for "group" and "others".
    umask 077
    # Write the file; the shell fills in the variables.
    cat > "${generated}" <<YAML
# Generated by scripts/lib/deploy.sh - contains secrets, never commit it.
baseDomain: "${BASE_DOMAIN}"
realm:
  clients:
    app1:
      secret: "${APP1_CLIENT_SECRET}"
    app2:
      secret: "${APP2_CLIENT_SECRET}"
  testUserPassword: "${TEST_USER_PASSWORD}"
YAML
  )
  # Later --values files win over earlier ones; "$@" may add more options.
  helm_deploy keycloak "${ROOT_DIR}/helm/charts/keycloak" keycloak --values "${ROOT_DIR}/helm/values/${style}" --values "${generated}" --set image.repository="${KEYCLOAK_IMAGE_REPOSITORY}" --set-string image.tag="${version}" "$@"
}

# ----------------------------------------------------------------------------
# The two Spring Boot applications
# ----------------------------------------------------------------------------

# Install or upgrade one application.
deploy_app() {
  # $1 = release name (app1 or app2), $2 = image tag.
  local name="$1" tag="$2"
  # The registry and the host names must be known.
  require_state ACR_LOGIN_SERVER "scripts/install/03-create-acr.sh"
  # The public host names are passed to the applications.
  require_state BASE_DOMAIN "scripts/install/04-create-public-ip.sh"
  # Rolling update: the chart starts a new pod before it stops an old one.
  helm_deploy "${name}" "${ROOT_DIR}/helm/charts/spring-app" apps --values "${ROOT_DIR}/helm/values/${name}.yaml" --set image.repository="${ACR_LOGIN_SERVER}/${name}" --set-string image.tag="${tag}" --set baseDomain="${BASE_DOMAIN}" --set egress.allowedHost="${EGRESS_TEST_HOST}" --set egress.blockedHost="${EGRESS_BLOCKED_HOST}"
}
