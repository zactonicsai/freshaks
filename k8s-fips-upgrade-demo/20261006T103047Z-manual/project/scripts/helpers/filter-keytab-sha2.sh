#!/usr/bin/env bash
# Makes a copy of a keytab that keeps ONLY the SHA-2 keys
# (aes256-cts-hmac-sha384-192 and aes128-cts-hmac-sha256-128).
# The keys themselves are not changed, so the old keytab keeps working too.
# That is what makes rolling back safe.
#
# usage: filter-keytab-sha2.sh IN_KEYTAB OUT_KEYTAB      (needs ktutil and klist from MIT Kerberos)
set -euo pipefail
in="${1:?input keytab}"
out="${2:?output keytab}"
[ -s "$in" ] || { echo "ERROR: keytab $in is missing or empty" >&2; exit 1; }
rm -f "$out"

# "list -e" prints one line per key:  slot  KVNO  principal (enctype)
listing="$(printf 'rkt %s\nlist -e\nquit\n' "$in" | ktutil)"
keep="$(printf '%s\n' "$listing" | grep -Ec 'hmac-sha256-128|hmac-sha384-192' || true)"
if [ "$keep" -eq 0 ]; then
  echo "ERROR: $in has no SHA-2 keys. Ask the KDC for a new keytab that includes them." >&2
  exit 2
fi
# slots to delete, highest number first so the other numbers do not shift
drop="$(printf '%s\n' "$listing" | awk '{ sub(/^ktutil:[ ]*/, "") } $1 ~ /^[0-9]+$/ && !/hmac-sha256-128|hmac-sha384-192/ { print $1 }' | sort -rn)"
{
  echo "rkt $in"
  for slot in $drop; do echo "delent $slot"; done
  echo "wkt $out"
  echo "quit"
} | ktutil >/dev/null
[ -s "$out" ] || { echo "ERROR: could not write $out" >&2; exit 3; }
chmod 600 "$out"
echo "Keys kept in $out:"
klist -kte "$out" | sed 's/^/  /'
