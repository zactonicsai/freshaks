#!/usr/bin/env bash
set -Eeuo pipefail

required=(docker kind kubectl helm git curl)
missing=0
for cmd in "${required[@]}"; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "%-12s %s\n" "$cmd" "OK: $($cmd version 2>/dev/null | head -n 1 || true)"
  else
    echo "MISSING: $cmd"
    missing=1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but the daemon is not reachable. Start Docker Desktop."
  missing=1
fi

if [[ $missing -ne 0 ]]; then
  echo "Install/start the missing prerequisites, then run this script again."
  exit 1
fi

echo "Prerequisites look ready."
