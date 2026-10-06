#!/usr/bin/env bash
# 40-restore-state.sh SNAPSHOT [--in-place|--new-cluster] [--prune] [--no-test] - puts a saved state back.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#   SNAPSHOT        a name in state/, a snapshot folder, or a .zip / .zip.enc made by 10-save-state.sh
#   --in-place      (default) the cluster you already have
#   --new-cluster   build cluster + FreeIPA + Istio first (for another computer; needs a snapshot made with --with-ipa-data)
#   --prune         also DELETE demo objects that are not in the snapshot (needed for a true "back to then")
init restore-state "$@"
need kubectl jq
ARG="${1:-}"; [ -n "$ARG" ] || die "usage: 40-restore-state.sh SNAPSHOT [--in-place|--new-cluster] [--prune] [--no-test]"; shift
MODE=in-place; PRUNE=0; RUN_TEST=1
while [ $# -gt 0 ]; do
  case "$1" in
    --in-place) MODE=in-place; shift ;;
    --new-cluster) MODE=new-cluster; shift ;;
    --prune) PRUNE=1; shift ;;
    --no-test) RUN_TEST=0; shift ;;
    *) die "unknown option $1" ;;
  esac
done

step "1. Find the snapshot and check that nobody changed it (SHA-256)"
if [ -d "$ARG" ]; then DIR="$(cd "$ARG" && pwd)"
elif [ -d "$STATE_DIR/$ARG" ]; then DIR="$STATE_DIR/$ARG"
else
  FILE="$ARG"; [ -f "$FILE" ] || FILE="$STATE_DIR/$ARG"
  [ -f "$FILE" ] || die "no snapshot folder or file called '$ARG'"
  if [ -f "$FILE.sha256" ]; then
    [ "$(sha256_of "$FILE")" = "$(awk '{print $1}' "$FILE.sha256")" ] || die "the checksum of $FILE does not match $FILE.sha256. The file was damaged or changed. Stopping."
    ok "file checksum matches"
  else warn "no .sha256 file next to $FILE, cannot check the zip itself"; fi
  need unzip
  ZIP="$FILE"
  if [[ "$FILE" == *.enc ]]; then
    need openssl; ZIP="${FILE%.enc}"
    if [ -n "${STATE_PASSPHRASE:-}" ]; then
      openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$FILE" -out "$ZIP" -pass env:STATE_PASSPHRASE 2>/dev/null || { rm -f "$ZIP"; die "could not unlock $FILE (wrong passphrase?)"; }
    else
      openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$FILE" -out "$ZIP" || { rm -f "$ZIP"; die "could not unlock $FILE (wrong passphrase?)"; }
    fi
  fi
  unzip -q -o "$ZIP" -d "$STATE_DIR"
  if [[ "$FILE" == *.enc ]]; then rm -f "$ZIP"; fi      # do not leave an unlocked copy of the zip lying around
  DIR="$STATE_DIR/$(basename "${ZIP%.zip}")"
fi
[ -f "$DIR/SHA256SUMS" ] && [ -f "$DIR/meta/snapshot.env" ] || die "$DIR does not look like a snapshot"
bad=0
while read -r sum file; do
  [ "$(sha256_of "$DIR/$file")" = "$sum" ] || { err "changed or damaged: $file"; bad=1; }
done < "$DIR/SHA256SUMS"
[ "$bad" = 0 ] || die "the snapshot failed its checksum test. Not using it."
ok "all $(wc -l < "$DIR/SHA256SUMS" | tr -d ' ') files match their SHA-256 checksums"
while IFS='=' read -r key val; do
  case "$key" in ''|\#*) ;; *) printf -v "SNAP_$key" '%s' "$val" ;; esac
done < "$DIR/meta/snapshot.env"
log "snapshot ${SNAP_SNAPSHOT_NAME:-?} from ${SNAP_CREATED_UTC:-?}: live side '${SNAP_LIVE_TRACK:-}', mesh policy '${SNAP_MESH_POLICY:-}', certificate '${SNAP_TLS_SECRET:-}'"

if [ ! -d "$WORK_DIR/ipa" ] && [ -d "$DIR/secrets-work/ipa" ]; then
  log "copying the saved run-time secrets back into work/"
  (cd "$DIR/secrets-work" && tar cf - .) | (cd "$WORK_DIR" && tar xf -); chmod -R go-rwx "$WORK_DIR"
fi

if [ "$MODE" = new-cluster ]; then
  step "2. Build the surroundings: cluster, FreeIPA, Istio, images"
  need docker kind istioctl
  run_script 01-create-cluster.sh
  if ! ipa_exists; then
    [ -f "$DIR/ipa/ipa-data.tgz" ] || die "this snapshot has no FreeIPA data (it was not saved with --with-ipa-data), and there is no FreeIPA container here. The saved keytab and certificates only fit the FreeIPA they came from."
    ipa_restore_data "$DIR/ipa/ipa-data.tgz"
  fi
  ipa_start; ipa_wait_ready
  printf 'IPA_IP=%s\n' "$(ipa_ip)" > "$WORK_DIR/ipa/ipa.env"
  mesh_install "${SNAP_MESH_POLICY:-}"
  gateway_install
  if [ -f "$DIR/images/app-images.tar" ]; then load_images "$DIR/images/app-images.tar"
  else build_and_load_image nonfips; if [ "${SNAP_LIVE_TRACK:-}" = green ] || ls "$DIR"/restore/*deployments-fipsdemo-green.json >/dev/null 2>&1; then build_and_load_image fips; fi; fi
fi

MESH_CHANGED=0
if [ "$MODE" = in-place ] && [ "$(mesh_policy_now)" != "${SNAP_MESH_POLICY:-}" ]; then
  step "2. Mesh first: put the Istio compliance policy back to '${SNAP_MESH_POLICY:-none}'"
  mesh_install "${SNAP_MESH_POLICY:-}"
  MESH_CHANGED=1
fi

step "3. Put the saved objects back (settings first, pods later, traffic rules last)"
NEW_IP=""; if [ -f "$WORK_DIR/ipa/ipa.env" ]; then NEW_IP="$(sed -n 's/^IPA_IP=//p' "$WORK_DIR/ipa/ipa.env" | tail -1)"; fi
OLD_IP="${SNAP_IPA_IP:-}"
if [ -n "$OLD_IP" ] && [ -n "$NEW_IP" ] && [ "$OLD_IP" != "$NEW_IP" ]; then log "FreeIPA address changed: $OLD_IP -> $NEW_IP (rewriting it while applying)"; fi
for f in "$DIR"/restore/*.json; do
  if [ -n "$OLD_IP" ] && [ -n "$NEW_IP" ] && [ "$OLD_IP" != "$NEW_IP" ]; then sed "s/${OLD_IP//./\\.}/$NEW_IP/g" "$f" | k apply -f -
  else k apply -f "$f"; fi
done

if [ "$PRUNE" = 1 ]; then
  step "4. Remove demo objects that did not exist when the snapshot was taken"
  keep="$(for f in "$DIR"/restore/*.json; do jq -r '[(.metadata.namespace // ""), .kind, .metadata.name] | join("/")' "$f"; done)"
  while read -r ns; do
    for kind in "${STATE_KINDS[@]}"; do
      while read -r kd name; do
        [ -n "${name:-}" ] || continue
        if ! grep -qxF "$ns/$kd/$name" <<<"$keep"; then
          log "removing $kd '$name' in $ns"
          k -n "$ns" delete "$kind" "$name" --wait=false >/dev/null
        fi
      done < <(k -n "$ns" get "$kind" -l "$PART_OF_LABEL" -o json 2>/dev/null | jq -r '.items[] | select((.metadata.ownerReferences // []) | length == 0) | "\(.kind) \(.metadata.name)"' || true)
    done
  done < <(state_namespaces)
fi

step "5. Wait until the pods are ready"
for f in "$DIR"/restore/*-deployments-*.json; do
  [ -f "$f" ] || continue
  rollout_wait "$(jq -r .metadata.namespace "$f")" "deployment/$(jq -r .metadata.name "$f")"
done
if [ "$MESH_CHANGED" = 1 ]; then
  log "restarting proxies so that they match the restored mesh policy"
  gateway_restart
  k -n "$APP_NS" rollout restart deployment -l "$PART_OF_LABEL" >/dev/null
  for d in $(k -n "$APP_NS" get deployments -l "$PART_OF_LABEL" -o name); do rollout_wait "$APP_NS" "$d"; done
fi
ok "state '${SNAP_SNAPSHOT_NAME:-?}' is back. Live side: '$(live_track)'"

if [ "$RUN_TEST" = 1 ]; then step "6. Test"; sleep 5; run_script 06-test.sh auto; fi
