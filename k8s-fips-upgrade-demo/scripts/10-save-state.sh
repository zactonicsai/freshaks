#!/usr/bin/env bash
# 10-save-state.sh [--label NAME] [--with-images] [--with-ipa-data] [--encrypt] - saves the current state into state/<time>-<label>/ and a zip you can carry away.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init save-state "$@"
need kubectl jq zip
LABEL=manual; WITH_IMAGES=0; WITH_IPA=0; ENCRYPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="${2:?--label needs a name}"; shift 2 ;;
    --with-images) WITH_IMAGES=1; shift ;;
    --with-ipa-data) WITH_IPA=1; shift ;;
    --encrypt) ENCRYPT=1; shift ;;
    *) die "usage: 10-save-state.sh [--label NAME] [--with-images] [--with-ipa-data] [--encrypt]" ;;
  esac
done
NAME="$(utc_stamp)-$LABEL"; DIR="$STATE_DIR/$NAME"
mkdir -p "$DIR"/{meta,raw,restore,istio,rollout,project,secrets-work,logs}; chmod 700 "$DIR"
if [ -f "$WORK_DIR/ipa/ipa.env" ]; then
  # shellcheck disable=SC1091
  source "$WORK_DIR/ipa/ipa.env"
fi

step "1. Facts about the cluster"
{
  echo "SNAPSHOT_NAME=$NAME"; echo "CREATED_UTC=$(ts)"; echo "LABEL=$LABEL"
  echo "KUBE_CONTEXT=$KUBE_CONTEXT"; echo "CLUSTER_NAME=$CLUSTER_NAME"; echo "APP_NS=$APP_NS"; echo "INGRESS_NS=$INGRESS_NS"
  echo "LIVE_TRACK=$(live_track)"; echo "TLS_SECRET=$(tls_secret_now)"; echo "MESH_POLICY=$(mesh_policy_now)"
  echo "IPA_IP=${IPA_IP:-}"; echo "HAS_IMAGES=$WITH_IMAGES"; echo "HAS_IPA_DATA=$WITH_IPA"
} > "$DIR/meta/snapshot.env"
cat "$DIR/meta/snapshot.env"
k version -o yaml > "$DIR/meta/kubernetes-version.yaml" 2>/dev/null || true
k get nodes -o wide --show-labels > "$DIR/meta/nodes.txt"
k get nodes -o json | jq '[.items[] | {name: .metadata.name, labels: .metadata.labels, unschedulable: (.spec.unschedulable // false), taints: (.spec.taints // []), kernel: .status.nodeInfo.kernelVersion, os: .status.nodeInfo.osImage}]' > "$DIR/meta/nodes.json"

step "2. Every object of the demo, twice: raw (exactly as it is) and clean (ready to put back)"
count=0
while read -r ns; do
  k get namespace "$ns" >/dev/null 2>&1 || { warn "namespace $ns does not exist, skipping"; continue; }
  mkdir -p "$DIR/raw/$ns"
  k get namespace "$ns" -o json | jq "$JQ_CLEAN" > "$DIR/restore/00-$ns-namespace-$ns.json"
  for kind in "${STATE_KINDS[@]}"; do
    list="$(k -n "$ns" get "$kind" -l "$PART_OF_LABEL" -o json 2>/dev/null || echo '{"items":[]}')"
    n="$(jq '.items | length' <<<"$list")"
    [ "$n" -gt 0 ] || continue
    printf '%s\n' "$list" > "$DIR/raw/$ns/$kind.json"
    while read -r name; do
      jq --arg name "$name" ".items[] | select(.metadata.name == \$name) | $JQ_CLEAN" <<<"$list" \
        > "$DIR/restore/$(kind_order "$kind")-$ns-${kind%%.*}-$name.json"
      count=$((count + 1))
    done < <(jq -r '.items[] | select((.metadata.ownerReferences // []) | length == 0) | .metadata.name' <<<"$list")
    log "saved $n x $kind in $ns"
  done
done < <(state_namespaces)
ok "$count objects saved"

step "3. Rollout history and what is running right now"
for d in $(k -n "$APP_NS" get deployments -l "$PART_OF_LABEL" -o name 2>/dev/null || true); do
  k -n "$APP_NS" rollout history "$d" > "$DIR/rollout/${d##*/}.history.txt" 2>&1 || true
done
k -n "$APP_NS" get pods,replicasets -o wide > "$DIR/rollout/pods-and-replicasets.txt" 2>&1 || true
k -n "$APP_NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' > "$DIR/rollout/images-in-use.txt" 2>/dev/null || true

step "4. Istio settings"
cp "$ROOT_DIR/k8s/istio/istio-operator.yaml" "$DIR/istio/"
mesh_policy_now > "$DIR/istio/compliance-policy.txt"
k -n "$ISTIO_NS" get deployment istiod -o json 2>/dev/null | jq "$JQ_CLEAN" > "$DIR/istio/istiod-deployment.json" || true
k -n "$ISTIO_NS" get configmap istio -o json 2>/dev/null | jq "$JQ_CLEAN" > "$DIR/istio/mesh-config.json" || true
if command -v istioctl >/dev/null 2>&1; then istioctl --context "$KUBE_CONTEXT" version > "$DIR/istio/version.txt" 2>&1 || true; fi

step "5. The project itself, run-time secrets and logs (so the zip is complete on its own)"
(cd "$ROOT_DIR" && tar cf - --exclude=./state --exclude=./logs --exclude=./work .) | (cd "$DIR/project" && tar xf -)
if [ -d "$WORK_DIR" ]; then (cd "$WORK_DIR" && tar cf - .) | (cd "$DIR/secrets-work" && tar xf -); fi
cp "$LOG_DIR"/*.log "$DIR/logs/" 2>/dev/null || true

if [ "$WITH_IMAGES" = 1 ]; then step "6a. Container images (docker save)"; mkdir -p "$DIR/images"; save_images "$DIR/images/app-images.tar"; fi
if [ "$WITH_IPA" = 1 ]; then step "6b. FreeIPA data (users, keys, CA)"; mkdir -p "$DIR/ipa"; ipa_backup_data "$DIR/ipa/ipa-data.tgz"; fi

step "7. Checksums (SHA-256) and zip"
(cd "$DIR" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done > SHA256SUMS)
(cd "$STATE_DIR" && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME")
ZIP="$STATE_DIR/$NAME.zip"
if [ "$ENCRYPT" = 1 ]; then
  need openssl
  if [ -n "${STATE_PASSPHRASE:-}" ]; then openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in "$ZIP" -out "$ZIP.enc" -pass env:STATE_PASSPHRASE
  else openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in "$ZIP" -out "$ZIP.enc"; fi
  rm -f "$ZIP"; ZIP="$ZIP.enc"
fi
printf '%s  %s\n' "$(sha256_of "$ZIP")" "$(basename "$ZIP")" > "$ZIP.sha256"
printf '%s\n' "$NAME" > "$STATE_DIR/LATEST"
ok "snapshot folder : $DIR"
ok "portable file   : $ZIP  ($(du -h "$ZIP" | awk '{print $1}'))"
ok "its checksum    : $(cat "$ZIP.sha256")"
warn "The snapshot holds SECRETS (private keys, keytab, demo passwords). Guard it like a house key."
log "Put it back here     : scripts/40-restore-state.sh $NAME --in-place --prune"
log "Rebuild elsewhere    : unzip, then  project/scripts/40-restore-state.sh <folder> --new-cluster"
