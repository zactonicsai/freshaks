#!/usr/bin/env bash
# 30-rollback.sh [--fast|--full] [--snapshot NAME] [--yes] [--no-snapshot] - go back to the non-FIPS (blue) side.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#   --fast (default)  flip the traffic switch back to blue. Takes seconds. Green and the FIPS mesh policy stay.
#   --full            put EVERYTHING back the way a snapshot says (default: the one taken by the last upgrade).
init rollback "$@"
need kubectl jq
MODE=fast; SNAP=""; TAKE_SNAPSHOT=1; T0=$SECONDS
while [ $# -gt 0 ]; do
  case "$1" in
    --fast) MODE=fast; shift ;;
    --full) MODE=full; shift ;;
    --snapshot) SNAP="${2:?--snapshot needs a name}"; shift 2 ;;
    --no-snapshot) TAKE_SNAPSHOT=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    *) die "usage: 30-rollback.sh [--fast|--full] [--snapshot NAME] [--yes] [--no-snapshot]" ;;
  esac
done
if [ "$MODE" = full ] && [ -z "$SNAP" ]; then
  [ -f "$WORK_DIR/last-upgrade.env" ] || die "no work/last-upgrade.env. Name a snapshot: --snapshot NAME (see the state/ folder)"
  SNAP="$(sed -n 's/^PRE_SNAPSHOT=//p' "$WORK_DIR/last-upgrade.env" | tail -1)"
  [ -n "$SNAP" ] || die "work/last-upgrade.env names no snapshot. Use --snapshot NAME"
fi
confirm "ROLLBACK ($MODE): all visitors go back to the NON-FIPS (blue) side." ROLLBACK

if [ "$TAKE_SNAPSHOT" = 1 ]; then
  step "Save how things look right now (for the people who will ask 'what happened?')"
  run_script 10-save-state.sh --label pre-rollback || warn "could not save a pre-rollback snapshot. Going on, because getting back to a working site matters more."
fi

if [ "$MODE" = fast ]; then
  step "FAST ROLLBACK - flip the traffic switch"
  ready="$(k -n "$APP_NS" get deployment fipsdemo-blue -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [ "${ready:-0}" -ge 1 ] || die "there are no ready blue pods to go back to. Use: scripts/30-rollback.sh --full"
  apply_routing blue fipsdemo-tls-v1
  sleep 5
  run_script 06-test.sh nonfips
  step "FAST ROLLBACK DONE in $((SECONDS - T0)) seconds"
  log "Still in place: the green pods and the FIPS mesh policy. To remove them too: scripts/30-rollback.sh --full"
  log "To roll FORWARD again: scripts/20-upgrade-to-fips.sh is not needed, just run  scripts/31-switch-live.sh green"
else
  step "FULL ROLLBACK - back to snapshot $SNAP"
  for n in $(nodes_of_selector "$BLUE_NODE_SELECTOR"); do k uncordon "$n" >/dev/null && log "node $n may run pods again"; done
  run_script 40-restore-state.sh "$SNAP" --in-place --prune
  step "FULL ROLLBACK DONE in $((SECONDS - T0)) seconds"
fi
