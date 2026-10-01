#!/usr/bin/env bash
# Record a new image version in Git. This is how a release is "deployed":
# CI commits the change and Argo CD rolls it out.
#   scripts/set-version.sh <app> <tag> [digest] [target]
#     target  "global" (default, every cluster) or a cluster file name (one cluster only)
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need yq

APP="${1:-}" TAG="${2:-}" DIGEST="${3:-}" TARGET="${4:-global}"
[[ -n "$APP" && -n "$TAG" ]] || die "usage: ${0##*/} <app> <tag> [digest] [global|<cluster>]"

file="$ROOT/config/global.yaml"
[[ "$TARGET" == global ]] || file="$ROOT/config/clusters/$TARGET.yaml"
[[ -f "$file" ]] || die "${file#"$ROOT"/} not found"
[[ "$(APP="$APP" yq '.apps | has(strenv(APP))' "$ROOT/config/global.yaml")" == true ]] ||
  die "unknown app '$APP': it has no entry under apps in config/global.yaml"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
APP="$APP" TAG="$TAG" DIGEST="$DIGEST" yq '
  .apps[strenv(APP)].image.tag = strenv(TAG) |
  .apps[strenv(APP)].image.digest = strenv(DIGEST)
' "$file" >"$tmp"

# yq realigns comments and drops blank lines. Apply only the lines that really
# changed, so the release commit stays a two-line diff.
if command -v patch >/dev/null 2>&1; then
  changes="$(diff -B -w "$file" "$tmp" || true)"
  [[ -z "$changes" ]] || patch -s "$file" <<<"$changes"
else
  cat "$tmp" >"$file"
fi
echo "$APP -> $TAG${DIGEST:+ ($DIGEST)} in ${file#"$ROOT"/}"
