#!/usr/bin/env bash
# =============================================================================
# 03-install-storage.sh — namespaces and shared storage:
#   1. create the namespaces
#   2. install the NFS server pod (its "disk" is a Docker volume that every
#      worker node has mounted, so the pod can run on any node)
#   3. create the two shared volumes (database dumps, application notes)
#   4. prove that a pod can really mount and write an NFS volume
# Usage: ./scripts/install/03-install-storage.sh
# =============================================================================
# Load the shared helpers (logging, state, wrappers).
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Stop when the cluster is not running.
require_cluster

# Announce the step.
step "Create the namespaces"
# Three of them carry the label that asks Istio to add a sidecar to every pod.
kapply k8s/namespaces.yaml

# Announce the step.
step "Prepare the NFS server's disk"
# Copy our start configuration onto the disk unless one is there already
# (the server appends to it later, so it must never be overwritten). The file
# travels through standard input into the first worker node, which has the
# disk mounted at /mnt/nfs-disk. Why this file matters: docker/nfs/vfs.conf.
docker exec -i "${PROJECT_NAME}-${AGENT_LIST[0]}" sh -c 'test -s /mnt/nfs-disk/vfs.conf || cat > /mnt/nfs-disk/vfs.conf' < docker/nfs/vfs.conf
# Tell Kubernetes about the disk (a PersistentVolume).
kapply k8s/storage/nfs-disk-pv.yaml

# Announce the step.
step "Install the NFS server pod (chart nfs-server-provisioner ${NFS_CHART_VERSION})"
# Register the chart repository; --force-update replaces an older entry.
run helm repo add nfs-ganesha "${NFS_HELM_REPO}" --force-update
# Download its newest chart list.
run helm repo update nfs-ganesha
# The release name equals the chart name, so all objects are simply called
# "nfs-server-provisioner".
helm_deploy nfs-server-provisioner nfs-ganesha/nfs-server-provisioner nfs-storage --version "${NFS_CHART_VERSION}" --values helm/values/nfs-server-provisioner.yaml --set persistence.size="${NFS_DISK_SIZE}"

# Announce the step.
step "Create the shared volumes"
# Database dumps; mounted by every PostgreSQL pod.
kapply k8s/storage/pvc-pg-backups.yaml
# Notes; mounted by all application pods.
kapply k8s/storage/pvc-shared-notes.yaml
# The NFS server creates a folder and an export for each claim.
run kubectl --namespace postgres wait --for=jsonpath='{.status.phase}'=Bound persistentvolumeclaim/pg-backups --timeout=120s
# Same for the notes volume.
run kubectl --namespace apps wait --for=jsonpath='{.status.phase}'=Bound persistentvolumeclaim/shared-notes --timeout=120s

# Announce the step.
step "Test: can a pod mount the NFS volume and own its files? (up to 5 minutes)"
# Remove a test pod left over from an earlier run.
run kubectl --namespace postgres delete pod nfs-mount-test --ignore-not-found
# A one-shot pod that runs as user 999 (like PostgreSQL), writes a file to the
# backup volume and checks that the file belongs to user 999. If the node
# cannot mount NFS, or the server reports owners wrongly, it fails HERE with a
# clear message instead of later inside PostgreSQL.
kubectl_stdin apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: nfs-mount-test
  namespace: postgres
  labels:
    # No Istio sidecar for this helper pod (matters when the script is run
    # again after Istio is installed).
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 999
    runAsGroup: 999
  containers:
    - name: test
      # The PostgreSQL image is needed in a minute anyway.
      image: ${POSTGRES_IMAGE_REPOSITORY}:${POSTGRES_VERSION_OLD}
      command:
        - sh
        - -c
        - touch /backups/.mount-test && test "\$(stat -c %u /backups/.mount-test)" = "999" && rm /backups/.mount-test && echo NFS-OK
      volumeMounts:
        - name: backups
          mountPath: /backups
  volumes:
    - name: backups
      persistentVolumeClaim:
        claimName: pg-backups
YAML
# Seconds waited so far.
waited=0
# Ask for the pod's phase until it is Succeeded or Failed.
while true; do
  # Pending, Running, Succeeded or Failed.
  phase="$(kubectl --namespace postgres get pod nfs-mount-test --output jsonpath='{.status.phase}' 2>/dev/null || true)"
  # Success: leave the loop.
  if [[ "${phase}" == "Succeeded" ]]; then break; fi
  # Failure or timeout: show what Kubernetes knows, then stop with advice.
  if [[ "${phase}" == "Failed" ]] || (( waited >= 300 )); then
    # Events show mount errors; the log shows a failed owner check.
    kubectl --namespace postgres describe pod nfs-mount-test | tail -n 25 || true
    # The container log, if the container ever started.
    kubectl --namespace postgres logs nfs-mount-test || true
    # Explain the two usual causes.
    fail "The NFS test pod did not succeed (phase: ${phase:-unknown}). 'MountVolume.SetUp failed' above means the Docker host's kernel cannot mount NFS 4.1 (on Linux try: sudo modprobe nfsv4). A failed owner check means docker/nfs/vfs.conf was not used."
  fi
  # Wait a little before the next check.
  sleep 5
  # Count the waiting time.
  waited=$((waited + 5))
done
# Remove the test pod.
run kubectl --namespace postgres delete pod nfs-mount-test
# Show the result.
run kubectl get storageclass,persistentvolume,persistentvolumeclaim --all-namespaces
# Final message.
ok "shared NFS storage works"
