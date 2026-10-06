#!/usr/bin/env bash
# End-to-end run of the real scripts on the Docker-less test box (see hooks.sh for what is a stand-in).
# usage: run-e2e.sh [stage ...]     no arguments = all stages in order
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT"
# shellcheck disable=SC1091
source "${SBX_DIR:?}/env.sh"
RESULTS=()
stage() { # name expected_exit command...
  local name="$1" want="$2" rc t0=$SECONDS; shift 2
  echo; echo "################ STAGE $name: $* ################"
  "$@"; rc=$?
  if [ "$rc" -eq "$want" ]; then RESULTS+=("PASS  $name (exit $rc, $((SECONDS - t0))s)"); else RESULTS+=("FAIL  $name (exit $rc, wanted $want)"); echo "STAGE $name FAILED"; summary; exit 1; fi
}
summary() { echo; echo "================ E2E SUMMARY ================"; printf '%s\n' "${RESULTS[@]}"; }
expect() { # description command...   (a check between stages)
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then RESULTS+=("PASS    check: $what"); else RESULTS+=("FAIL    check: $what"); echo "CHECK FAILED: $what"; summary; exit 1; fi
}
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
live() { k -n fipsdemo get virtualservice fipsdemo -o jsonpath='{.metadata.annotations.fipsdemo/live-track}'; }
no_green() { ! k -n fipsdemo get deployment fipsdemo-green >/dev/null 2>&1; }

s_setup()    { stage 02-start-ipa 0 scripts/02-start-ipa.sh; stage 03-install-istio 0 scripts/03-install-istio.sh; }
s_deploy()   { stage 05-deploy-nonfips 0 scripts/05-deploy-nonfips.sh; expect "live side is blue" test "$(live)" = blue; }
s_save()     { stage 10-save-state 0 scripts/10-save-state.sh --label manual --with-images --with-ipa-data; }
s_fail_mesh() { stage "20-upgrade with a forced failure in phase 4 (mesh)" 1 env SBX_FAIL_AT=mesh scripts/20-upgrade-to-fips.sh
               expect "after auto-rollback: live side is blue" test "$(live)" = blue; expect "after auto-rollback: no green deployment" no_green
               expect "after auto-rollback: v2 secrets are gone" bash -c "! kubectl -n fipsdemo get secret fipsdemo-keytab-v2"; }
s_fail_green() { stage "20-upgrade with a forced failure in phase 5 (green pods cannot start)" 1 env APP_IMAGE_FIPS=fipsdemo-app:broken SBX_SKIP_IMAGE_CHECK=1 ROLLOUT_TIMEOUT=45s scripts/20-upgrade-to-fips.sh
               expect "after auto-rollback: live side is blue" test "$(live)" = blue; expect "after auto-rollback: no green deployment" no_green
               expect "after auto-rollback: mesh policy is back to none" test -z "$(k -n istio-system get configmap sandbox-mesh -o jsonpath='{.data.policy}')"; }
s_upgrade()  { stage 20-upgrade-to-fips 0 scripts/20-upgrade-to-fips.sh; expect "live side is green" test "$(live)" = green; }
s_fast()     { stage "30-rollback --fast" 0 scripts/30-rollback.sh --fast --yes; expect "live side is blue" test "$(live)" = blue
               stage "31-switch-live green (roll forward again)" 0 scripts/31-switch-live.sh green; expect "live side is green" test "$(live)" = green; }
s_full()     { stage "30-rollback --full" 0 scripts/30-rollback.sh --full --yes; expect "live side is blue" test "$(live)" = blue; expect "no green deployment" no_green; }
s_finalize() { stage 20-upgrade-again 0 scripts/20-upgrade-to-fips.sh
               stage 50-finalize 0 scripts/50-finalize-fips.sh --yes --keep-blue-nodes
               expect "blue deployment is gone" bash -c "! kubectl -n fipsdemo get deployment fipsdemo-blue"; }
s_transport() {
  local name zip dest=/tmp/moved-snapshot
  name="$(cat state/LATEST)"; zip="state/$name.zip"
  rm -rf "$dest"; mkdir -p "$dest"; unzip -q "$zip" -d "$dest"
  echo "tamper test: change one byte in a copy and expect the restore to refuse it"
  cp -a "$dest/$name" "$dest/tampered"; echo x >> "$dest/tampered/restore/40-fipsdemo-services-fipsdemo.json"
  stage "40-restore refuses a changed snapshot" 1 scripts/40-restore-state.sh "$dest/tampered" --in-place --no-test
  echo "wipe test: delete both namespaces, then rebuild them from the zip using the project copy INSIDE the zip"
  k delete namespace fipsdemo istio-ingress --wait=true >/dev/null
  expect "namespaces are really gone" bash -c "! kubectl get namespace fipsdemo"
  stage "40-restore from the carried-away zip (project copy inside the snapshot)" 0 "$dest/$name/project/scripts/40-restore-state.sh" "$dest/$name" --in-place
  expect "live side is green after restore" test "$(live)" = green
}
s_logs()     { stage 60-collect-logs 0 scripts/60-collect-logs.sh; }
if [ $# -eq 0 ]; then set -- setup deploy save fail_mesh fail_green upgrade fast full finalize transport logs; fi
for s in "$@"; do "s_$s"; done
summary
