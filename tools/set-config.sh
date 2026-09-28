#!/usr/bin/env bash
# =============================================================================
#  tools/set-config.sh — change one setting with sed instead of opening an editor.
#
#    tools/set-config.sh LOCATION westeurope            # edits scripts/00-config.sh
#    tools/set-config.sh --yaml helm/keycloak/values.yaml logLevel debug
#                                                       # edits a top-level YAML key
#
#  The sed pattern for the shell file:  s|^export KEY=.*|export KEY="VALUE"|
#  (^ = start of line, .* = anything after; the | separators avoid clashes with / in URLs)
# =============================================================================
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed_inplace() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }

if [[ "${1:-}" == "--yaml" ]]; then
  file="$2"; key="$3"; value="$4"
  [[ -f "$file" ]] || { echo "no such file: $file" >&2; exit 1; }
  if grep -qE "^${key}:" "$file"; then
    sed_inplace "s|^${key}:.*|${key}: ${value}|" "$file"
  else
    printf '%s: %s\n' "$key" "$value" >> "$file"
  fi
  echo "set ${key}: ${value}  in ${file}"
  exit 0
fi

if [[ $# -ne 2 ]]; then
  sed -n '2,12p' "$0"; exit 1
fi
key="$1"; value="$2"; file="$ROOT_DIR/scripts/00-config.sh"

if grep -qE "^export ${key}=" "$file"; then
  sed_inplace "s|^export ${key}=.*|export ${key}=\"${value}\"|" "$file"
else
  printf 'export %s="%s"\n' "$key" "$value" >> "$file"
fi
echo "set ${key}=\"${value}\"  in scripts/00-config.sh"
