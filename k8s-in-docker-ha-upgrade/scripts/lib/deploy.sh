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

# Print the Kubernetes minor of a K3s image tag: v1.34.12-k3s1 -> 1.34
k8s_minor_of() {
  # sed drops the leading "v" and everything after the second number.
  printf '%s' "$1" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/'
}

# Print the version a node reports for a K3s image tag: v1.34.12-k3s1 -> v1.34.12+k3s1
# (the real version has a "+", which is not allowed in image tags).
k3s_node_version() {
  # sed replaces the "-" in front of "k3s" with "+".
  printf '%s' "$1" | sed -E 's/-k3s/+k3s/'
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
  # "gitVersion":"v1.34.12+k3s1" after tr removed spaces and line breaks.
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
# Istio
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
  # Helm 4 applies manifests "server-side" by default. istiod edits two fields
  # of its own webhook objects after the install; with server-side apply a
  # later "helm upgrade" of an Istio chart that still templates those fields
  # can stop with a "conflict" error. Client-side apply (what Helm 3 did) has
  # no such problem, so the Istio charts are always applied client-side.
  ISTIO_HELM_EXTRA=(--server-side=false)
  # Pull the images from a mirror when ISTIO_HUB is set.
  if [[ -n "${ISTIO_HUB}" ]]; then ISTIO_HELM_EXTRA+=(--set "global.hub=${ISTIO_HUB}"); fi
}

# Install or upgrade the "base" chart: Istio's CRDs and the default validator.
deploy_istio_base() {
  # $1 = chart version, $2 = revision whose istiod validates Istio objects.
  local version="$1" default_revision="$2"
  # Collect the options every Istio chart needs.
  istio_helm_extra
  # defaultRevision must always name an istiod that is installed: it is the
  # address of the webhook that checks every Istio object you apply.
  helm_deploy istio-base istio/base istio-system --version "${version}" --set defaultRevision="${default_revision}" "${ISTIO_HELM_EXTRA[@]}"
}

# Install one istiod control plane as its own Helm release ("revision").
deploy_istiod() {
  # $1 = Istio version.
  local version="$1" rev
  # Revision name, e.g. 1-28-1.
  rev="$(istio_rev "${version}")"
  # Collect the options every Istio chart needs.
  istio_helm_extra
  # One release per version: "istiod-1-28-1" and "istiod-1-29-8" can run side
  # by side, which is what makes the canary upgrade and the rollback possible.
  helm_deploy "istiod-${rev}" istio/istiod istio-system --version "${version}" --values helm/values/istiod.yaml --set revision="${rev}" "${ISTIO_HELM_EXTRA[@]}"
}

# Point the revision tag (ISTIO_TAG, "stable") at the istiod of a version.
set_revision_tag() {
  # $1 = Istio version the tag should point at.
  local version="$1" rev
  # Revision name, e.g. 1-28-1.
  rev="$(istio_rev "${version}")"
  # Tell the log what happens.
  info "pointing revision tag '${ISTIO_TAG}' at revision ${rev}"
  # Render only the two tag templates of the istiod chart (the injection
  # webhook "istio-revision-tag-<tag>" and the Service "istiod-revision-tag-<tag>")
  # and apply them. Applying again with another revision moves the tag.
  helm template "istiod-${rev}" istio/istiod --version "${version}" --namespace istio-system \
    --show-only templates/revision-tags-mwc.yaml --show-only templates/revision-tags-svc.yaml \
    --set "revisionTags={${ISTIO_TAG}}" --set revision="${rev}" | kubectl_stdin apply -f -
  # Show where the tag points now.
  run kubectl get mutatingwebhookconfiguration "istio-revision-tag-${ISTIO_TAG}" --output 'jsonpath={.metadata.labels.istio\.io/rev}{"\n"}'
}

# Install or upgrade both gateways: ingress (the way in) and egress (the way out).
deploy_gateways() {
  # $1 = chart version.
  local version="$1"
  # Collect the options every Istio chart needs.
  istio_helm_extra
  # revision=<tag> labels the gateway pods with istio.io/rev=<tag>, so they get
  # their proxy from whatever istiod the tag points at.
  helm_deploy istio-ingressgateway istio/gateway istio-ingress --version "${version}" --values helm/values/istio-ingressgateway.yaml --set revision="${ISTIO_TAG}" "${ISTIO_HELM_EXTRA[@]}"
  # Same chart, different release name and values.
  helm_deploy istio-egressgateway istio/gateway istio-egress --version "${version}" --values helm/values/istio-egressgateway.yaml --set revision="${ISTIO_TAG}" "${ISTIO_HELM_EXTRA[@]}"
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

# Wait (up to 3 minutes) until every proxy in the mesh runs the given Istio
# version; stop with an error when some never do.
wait_proxy_versions() {
  # $1 = expected Istio version.
  local version="$1" outdated tries=0
  # Old pods that are still shutting down show up for a short while, so retry.
  while true; do
    # Lines whose proxy image does not contain ":<version>".
    outdated="$(mesh_proxy_report | awk -v wanted=":${version}" 'index($3, wanted) == 0')"
    # Nothing outdated: done.
    if [[ -z "${outdated}" ]]; then break; fi
    # Count the attempt.
    tries=$((tries + 1))
    # After 18 attempts (3 minutes) show the offenders and stop.
    if (( tries >= 18 )); then printf '%s\n' "${outdated}"; fail "These pods still run another proxy version."; fi
    # Wait before the next look.
    sleep 10
  done
  # Show the final list.
  mesh_proxy_report
  # Report success.
  ok "every proxy runs Istio ${version}"
}

# Wait until every Deployment and StatefulSet of the example is fully ready.
wait_workloads_ready() {
  # Names used in the loops below.
  local namespace workload
  # Namespace by namespace.
  for namespace in istio-system istio-ingress istio-egress nfs-storage postgres keycloak apps; do
    # "rollout status" returns at once for a workload that is already complete.
    for workload in $(kubectl --namespace "${namespace}" get deployments,statefulsets --output name 2>/dev/null); do
      # "workload" looks like deployment.apps/app1.
      run kubectl --namespace "${namespace}" rollout status "${workload}" --timeout=10m
    done
  done
}

# ----------------------------------------------------------------------------
# Kubernetes nodes (containers) and the edge load balancer
# ----------------------------------------------------------------------------

# Wait until the Kubernetes API answers again (after the server was replaced).
wait_api_ready() {
  # $1 = seconds to wait.
  local timeout="${1:-180}" waited=0
  # K3s contains its own kubectl ("k3s kubectl"); /readyz answers "ok" when
  # the API is up. Asking inside the server container needs no kubeconfig.
  until docker exec "${SERVER_CONTAINER}" k3s kubectl get --raw /readyz >/dev/null 2>&1; do
    # Give up after the timeout and show the last log lines of the server.
    if (( waited >= timeout )); then docker logs --tail 30 "${SERVER_CONTAINER}" || true; fail "The Kubernetes API did not come back within ${timeout}s."; fi
    # Wait a little before the next try.
    sleep 5
    # Count the waiting time.
    waited=$((waited + 5))
  done
  # Report success.
  ok "the Kubernetes API answers"
}

# Wait until a node reports the expected version and is Ready.
wait_node_version() {
  # $1 = node name, $2 = K3s image tag it should run, $3 = seconds to wait.
  local node="$1" wanted timeout="${3:-300}" waited=0 version ready
  # The node reports v1.35.9+k3s1 for the tag v1.35.9-k3s1.
  wanted="$(k3s_node_version "$2")"
  # Ask every 5 seconds.
  while true; do
    # Version of the kubelet on that node (empty while the API is not reachable).
    version="$(kubectl get node "${node}" --output jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || true)"
    # "True" when the node is Ready.
    ready="$(kubectl get node "${node}" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    # Both must match.
    if [[ "${version}" == "${wanted}" && "${ready}" == "True" ]]; then ok "node ${node} runs ${version} and is Ready"; return 0; fi
    # Out of time: stop the script with an error.
    if (( waited >= timeout )); then fail "Node ${node} did not become Ready with ${wanted} within ${timeout}s (version now: ${version:-unknown}, Ready: ${ready:-unknown}). Check: docker logs ${PROJECT_NAME}-${node}"; fi
    # Wait a little before the next check.
    sleep 5
    # Count the waiting time.
    waited=$((waited + 5))
  done
}

# Tell the edge load balancer to stop ("drain") or resume ("ready") sending
# new connections to one worker node.
edge_node_state() {
  # $1 = node name, $2 = drain or ready.
  local node="$1" state="$2"
  # HAProxy has an admin port inside the Docker network (docker/edge/haproxy.cfg).
  # The command is sent with "nc" from the tools container. A failure here is
  # not fatal: the health check of the load balancer notices a stopped node too.
  if in_tools sh -c "echo 'set server ingress_nodes/${node} state ${state}' | nc -w 3 edge 9999" >/dev/null 2>&1; then ok "edge load balancer: ${node} is now '${state}'"; else warn "could not tell the edge load balancer about ${node} (its health check will handle it)"; fi
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
  helm_deploy "$(postgres_release "${version}")" helm/charts/postgres postgres --set image.repository="${POSTGRES_IMAGE_REPOSITORY}" --set-string image.tag="${version}" --set replicaCount="${replicas}" --set persistence.size="${POSTGRES_DATA_SIZE}"
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
# volume and copy the file into .state/backups on this machine.
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

# Replace the Keycloak database of the ACTIVE PostgreSQL with a dump from the
# shared backup volume. Keycloak must be stopped.
pg_restore_keycloak() {
  # $1 = file name in /backups.
  local file="$1" pod
  # Pod of the active release.
  pod="${POSTGRES_ACTIVE_RELEASE}-0"
  # WITH (FORCE) also closes connections that are still open.
  run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "DROP DATABASE IF EXISTS keycloak WITH (FORCE);"
  # Same owner and encoding as at install time.
  run pg_sql "${POSTGRES_ACTIVE_RELEASE}" postgres "CREATE DATABASE keycloak OWNER keycloak ENCODING 'UTF8';"
  # All or nothing (--single-transaction). The password comes from the pod's environment.
  run kubectl --namespace postgres exec "${pod}" --container postgres -- bash -c "PGPASSWORD=\"\${KEYCLOAK_DB_PASSWORD}\" pg_restore --host 127.0.0.1 --username keycloak --dbname keycloak --no-owner --no-acl --single-transaction /backups/${file}"
  # Fresh statistics for the query planner.
  run pg_sql "${POSTGRES_ACTIVE_RELEASE}" keycloak "ANALYZE;"
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
  # The client secrets and the test password must exist.
  [[ -n "${APP1_CLIENT_SECRET:-}" && -n "${APP2_CLIENT_SECRET:-}" && -n "${TEST_USER_PASSWORD:-}" ]] || fail "Secrets are missing. Run scripts/install/06-install-postgres.sh first."
  # Keycloak 25 changed many setting names; pick the matching values file.
  if (( $(major_of "${version}") >= 25 )); then style="keycloak-current-v26.yaml"; else style="keycloak-legacy-v24.yaml"; fi
  # Write the generated values (public address, client secrets, test password)
  # to a private file. Passing them in a file keeps them out of the command
  # line. The subshell with "umask 077" makes the file readable for you alone.
  (
    # New files are created without any rights for "group" and "others".
    umask 077
    # Write the file; the shell fills in the variables.
    cat > "${generated}" <<YAML
# Generated by scripts/lib/deploy.sh - contains secrets, never commit it.
publicDomain: "${PUBLIC_DOMAIN}"
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
  helm_deploy keycloak helm/charts/keycloak keycloak --values "helm/values/${style}" --values "${generated}" --set image.repository="${KEYCLOAK_IMAGE_REPOSITORY}" --set-string image.tag="${version}" "$@"
}

# ----------------------------------------------------------------------------
# The demo application (one image, two releases: app1 and app2)
# ----------------------------------------------------------------------------

# Install or upgrade one application.
deploy_app() {
  # $1 = release name (app1 or app2), $2 = image tag.
  local name="$1" tag="$2"
  # Rolling update: the chart starts a new pod before it stops an old one.
  # "registry:5000" is the address of the local registry as the nodes see it.
  helm_deploy "${name}" helm/charts/spring-app apps --values "helm/values/${name}.yaml" --set image.repository="registry:5000/demo-app" --set-string image.tag="${tag}" --set publicDomain="${PUBLIC_DOMAIN}" --set egress.allowedHost="${EGRESS_TEST_HOST}" --set egress.blockedHost="${EGRESS_BLOCKED_HOST}"
}
