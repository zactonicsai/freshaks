#!/usr/bin/env bash
# 04-build-images.sh [nonfips|fips|all] - builds the app image(s) with Docker and loads them into the kind nodes.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
init build-images "$@"
need docker kind
what="${1:-nonfips}"
case "$what" in
  nonfips|fips) step "Build the $what image"; build_and_load_image "$what" ;;
  all) for p in nonfips fips; do step "Build the $p image"; build_and_load_image "$p"; done ;;
  *) die "usage: 04-build-images.sh [nonfips|fips|all]" ;;
esac
