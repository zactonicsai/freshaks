#!/usr/bin/env bash
set -euo pipefail

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "MISSING: $1"
    return 1
  fi
  echo "ok  $1  $($1 version 2>/dev/null | head -n 1 || $1 --version 2>/dev/null | head -n 1)"
}

echo "== tools =="
fail=0
need docker || fail=1
need kind || fail=1
need kubectl || fail=1
need helm || fail=1
command -v argocd >/dev/null && need argocd || echo "warn argocd CLI not installed (optional)"
command -v git >/dev/null && need git || echo "warn git not installed (needed to push repos)"

echo
echo "== docker =="
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable"
  fail=1
else
  echo "ok  docker daemon"
fi

echo
if [[ "$fail" -eq 0 ]]; then
  echo "Prerequisites look good."
else
  echo "Fix the missing tools, then re-run."
  exit 1
fi
