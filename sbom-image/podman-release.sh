#!/usr/bin/env bash
# podman-release.sh — Generate a release Markdown file for a Podman image from
# its SBOM and image config, and track changes against the previous release.
#
# Usage:
#   ./podman-release.sh IMAGE [options]
#
# Options:
#   --sbom FILE        Use an existing SBOM (SPDX or CycloneDX JSON) instead of running syft
#   --version VER      Release version (default: OCI version label, else image tag, else timestamp)
#   --previous VER     Compare against this release instead of the last one recorded
#   --out DIR          Releases directory (default: ./releases)
#   --force            Overwrite an existing release with the same version
#   -h, --help         Show this help
#
# Output (in --out):
#   <version>/RELEASE.md     Full release notes for this version
#   <version>/sbom.json      SBOM snapshot
#   <version>/config.json    `podman image inspect` snapshot
#   <version>/packages.tsv   Normalized package list (name, version, type, license)
#   <version>/config.txt     Flattened config (key=value) used for diffing
#   CHANGELOG.md             Running changelog, newest first
#   .latest                  Pointer to the most recent release
#
# Requirements: podman, jq, and syft (only if --sbom is not given).
#   Alternative SBOM source: `podman build --sbom=syft --sbom-output=sbom.json ...` then pass --sbom sbom.json

set -euo pipefail

die()  { echo "error: $*" >&2; exit 1; }
info() { echo ">> $*" >&2; }

IMAGE="" SBOM_IN="" VERSION="" PREV="" OUT="./releases" FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sbom)     SBOM_IN="$2"; shift 2 ;;
    --version)  VERSION="$2"; shift 2 ;;
    --previous) PREV="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)          [[ -z "$IMAGE" ]] && IMAGE="$1" || die "unexpected argument: $1"; shift ;;
  esac
done
[[ -n "$IMAGE" ]] || die "missing IMAGE (see --help)"
command -v podman >/dev/null || die "podman not found"
command -v jq >/dev/null     || die "jq not found"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- 1. config
info "Inspecting $IMAGE"
podman image inspect "$IMAGE" > "$TMP/inspect.json" 2>/dev/null \
  || { info "Image not local, pulling"; podman pull "$IMAGE" >/dev/null && podman image inspect "$IMAGE" > "$TMP/inspect.json"; }
jq '.[0]' "$TMP/inspect.json" > "$TMP/config.json"

# ---------------------------------------------------------------- 2. SBOM
if [[ -n "$SBOM_IN" ]]; then
  [[ -f "$SBOM_IN" ]] || die "SBOM not found: $SBOM_IN"
  cp "$SBOM_IN" "$TMP/sbom.json"
else
  command -v syft >/dev/null || die "syft not found; install it or pass --sbom FILE"
  info "Generating SBOM with syft"
  syft "podman:$IMAGE" -o spdx-json="$TMP/sbom.json" -q
fi

# ---------------------------------------------------------------- 3. version
if [[ -z "$VERSION" ]]; then
  VERSION=$(jq -r '.Config.Labels["org.opencontainers.image.version"] // .Labels["org.opencontainers.image.version"] // empty' "$TMP/config.json")
fi
if [[ -z "$VERSION" ]]; then
  ref="${IMAGE##*/}"
  [[ "$ref" == *:* && "$ref" != *@* ]] && VERSION="${ref##*:}"
  [[ "$VERSION" == "latest" ]] && VERSION=""
fi
[[ -n "$VERSION" ]] || VERSION=$(date -u +%Y%m%d-%H%M%S)
VERSION="${VERSION//\//-}"

DEST="$OUT/$VERSION"
if [[ -d "$DEST" && $FORCE -eq 0 ]]; then die "release $VERSION already exists (use --force)"; fi
if [[ -z "$PREV" && -f "$OUT/.latest" ]]; then PREV=$(cat "$OUT/.latest"); fi
[[ "$PREV" == "$VERSION" ]] && PREV=""
if [[ -n "$PREV" && ! -d "$OUT/$PREV" ]]; then info "previous release '$PREV' not found; treating as first release"; PREV=""; fi
mkdir -p "$DEST"
cp "$TMP/sbom.json" "$TMP/config.json" "$DEST/"

# ---------------------------------------------------------------- 4. normalize
# Packages -> name<TAB>version<TAB>type<TAB>license (SPDX or CycloneDX)
jq -r '
  def ptype: (capture("^pkg:(?<t>[^/]+)/").t) // "unknown";
  def clean: if . == null or . == "NOASSERTION" or . == "NONE" then "" else . end;
  if .spdxVersion then
    .packages[]
    | select((.versionInfo // "") != "")
    | select((.SPDXID // "") | test("DocumentRoot") | not)
    | [ .name, .versionInfo,
        ([.externalRefs[]? | select(.referenceType=="purl") | .referenceLocator][0] // "" | ptype),
        ((.licenseDeclared | clean) as $d | if $d != "" then $d else (.licenseConcluded | clean) end) ]
  elif .bomFormat == "CycloneDX" then
    .components[]?
    | select((.version // "") != "")
    | [ .name, .version,
        ((.purl // "") | ptype),
        ([.licenses[]? | .license.id // .license.name // .expression] | map(select(.)) | join(" OR ")) ]
  else error("Unrecognized SBOM format (need SPDX or CycloneDX JSON)") end
  | map(gsub("[\t\n|]"; " ")) | @tsv' "$DEST/sbom.json" | sort -u > "$DEST/packages.tsv"

# Config -> flattened key=value lines (env as a map, secrets masked)
jq -r '
  def mask: if (.k | test("PASS|SECRET|TOKEN|KEY|CREDENTIAL"; "i")) then .v = "****" else . end;
  {
    "image.os":          .Os,
    "image.arch":        (.Architecture + (if .Variant then "/" + .Variant else "" end)),
    "image.digest":      .Digest,
    "config.user":       (.Config.User // ""),
    "config.workdir":    (.Config.WorkingDir // ""),
    "config.entrypoint": ((.Config.Entrypoint // []) | join(" ")),
    "config.cmd":        ((.Config.Cmd // []) | join(" ")),
    "config.stopsignal": (.Config.StopSignal // ""),
    "config.ports":      ((.Config.ExposedPorts // {}) | keys | join(", ")),
    "config.volumes":    ((.Config.Volumes // {}) | keys | join(", "))
  } as $base
  | ($base | to_entries[] | select(.value != null and .value != "") | "\(.key)=\(.value)"),
    ((.Config.Env // [])[] | split("=") | {k: .[0], v: (.[1:] | join("="))} | mask | "env.\(.k)=\(.v)"),
    ((.Config.Labels // .Labels // {}) | to_entries[] | "label.\(.key)=\(.value)")
' "$DEST/config.json" | sort > "$DEST/config.txt"

# ---------------------------------------------------------------- 5. diff
: > "$TMP/pkg_added"; : > "$TMP/pkg_removed"; : > "$TMP/pkg_changed"; : > "$TMP/cfg_diff"
if [[ -n "$PREV" ]]; then
  info "Comparing with previous release $PREV"
  # key = type|name ; value = sorted, comma-joined versions
  awk -F'\t' -v OFS='\t' '
    FNR==1 { f++ }
    { k=$3"|"$1
      if (f==1) { if (k in o) v=o[k]","$2; else v=$2; o[k]=v }
      else      { if (k in n) v=n[k]","$2; else v=$2; n[k]=v; lic[k]=$4 } }
    END {
      for (k in n) { split(k, p, "|")
        if (!(k in o))        print "A", p[2], n[k], p[1], lic[k]
        else if (o[k] != n[k]) print "C", p[2], o[k], n[k], p[1] }
      for (k in o) if (!(k in n)) { split(k, p, "|"); print "R", p[2], o[k], p[1] }
    }' "$OUT/$PREV/packages.tsv" "$DEST/packages.tsv" | sort -t$'\t' -k2,2 > "$TMP/pkgdiff"
  awk -F'\t' -v OFS='\t' '$1=="A"{print $2,$3,$4,$5}' "$TMP/pkgdiff" > "$TMP/pkg_added"
  awk -F'\t' -v OFS='\t' '$1=="R"{print $2,$3,$4}'    "$TMP/pkgdiff" > "$TMP/pkg_removed"
  while IFS=$'\t' read -r _ name old new type; do
    hi=$(printf '%s\n%s\n' "${old##*,}" "${new##*,}" | sort -V | tail -1)
    [[ "$hi" == "${new##*,}" ]] && dir="⬆ upgrade" || dir="⬇ downgrade"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$old" "$new" "$type" "$dir"
  done < <(awk -F'\t' '$1=="C"' "$TMP/pkgdiff") > "$TMP/pkg_changed"

  # config: key | before | after
  awk -v OFS='\t' '
    FNR==1 { f++ }
    { i=index($0,"="); k=substr($0,1,i-1); v=substr($0,i+1); if (k=="image.digest") next; if (f==1) o[k]=v; else n[k]=v }
    END {
      for (k in n) if (!(k in o)) print k, "_(none)_", n[k]; else if (o[k]!=n[k]) print k, o[k], n[k]
      for (k in o) if (!(k in n)) print k, o[k], "_(removed)_"
    }' "$OUT/$PREV/config.txt" "$DEST/config.txt" | sort > "$TMP/cfg_diff"
fi

# ---------------------------------------------------------------- 6. render
cfg() { grep -m1 "^$1=" "$DEST/config.txt" | cut -d= -f2- || true; }
code() { [[ -n "$1" ]] && printf '`%s`' "$1" || printf '_(not set)_'; }
esc() { sed 's/|/\\|/g'; }

N_PKG=$(wc -l < "$DEST/packages.tsv" | tr -d ' ')
N_ADD=$(wc -l < "$TMP/pkg_added" | tr -d ' ')
N_REM=$(wc -l < "$TMP/pkg_removed" | tr -d ' ')
N_CHG=$(wc -l < "$TMP/pkg_changed" | tr -d ' ')
N_CFG=$(wc -l < "$TMP/cfg_diff" | tr -d ' ')
NOW=$(date -u +"%Y-%m-%d %H:%M UTC")
SBOM_FMT=$(jq -r 'if .spdxVersion then .spdxVersion elif .bomFormat then "CycloneDX " + .specVersion else "unknown" end' "$DEST/sbom.json")
SIZE_MB=$(jq -r '((.Size // 0) / 1048576 * 10 | floor) / 10' "$DEST/config.json")

R="$DEST/RELEASE.md"
{
  echo "# Release $VERSION"
  echo
  echo "> Image \`$IMAGE\` · generated $NOW"
  echo
  echo "## Summary"
  echo
  if [[ -n "$PREV" ]]; then
    echo "Compared with **$PREV**: $N_ADD packages added, $N_REM removed, $N_CHG version changes, $N_CFG configuration changes. $N_PKG packages total."
  else
    echo "First tracked release (baseline). $N_PKG packages total."
  fi
  echo
  echo "## Image"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Reference | \`$IMAGE\` |"
  echo "| Tags | $(jq -r '(.RepoTags // []) | map("`"+.+"`") | join(", ") | if .=="" then "_(none)_" else . end' "$DEST/config.json") |"
  echo "| Digest | $(code "$(cfg image.digest)") |"
  echo "| Image ID | \`$(jq -r '.Id | sub("^sha256:";"") | .[0:12]' "$DEST/config.json")\` |"
  echo "| OS / Arch | $(cfg image.os) / $(cfg image.arch) |"
  echo "| Created | $(jq -r '.Created // "unknown"' "$DEST/config.json") |"
  echo "| Size | ${SIZE_MB} MB |"
  echo "| Layers | $(jq -r '(.RootFS.Layers // []) | length' "$DEST/config.json") |"
  echo "| SBOM format | $SBOM_FMT |"
  echo

  echo "## Changes"
  echo
  if [[ -z "$PREV" ]]; then
    echo "_No previous release to compare with. This release is the baseline._"
  else
    echo "### Package updates ($N_CHG)"
    echo
    if [[ $N_CHG -gt 0 ]]; then
      echo "| Package | From | To | Type | Direction |"; echo "|---|---|---|---|---|"
      esc < "$TMP/pkg_changed" | awk -F'\t' '{printf "| %s | `%s` | `%s` | %s | %s |\n",$1,$2,$3,$4,$5}'
    else echo "_None._"; fi
    echo
    echo "### Packages added ($N_ADD)"
    echo
    if [[ $N_ADD -gt 0 ]]; then
      echo "| Package | Version | Type | License |"; echo "|---|---|---|---|"
      esc < "$TMP/pkg_added" | awk -F'\t' '{printf "| %s | `%s` | %s | %s |\n",$1,$2,$3,($4==""?"—":$4)}'
    else echo "_None._"; fi
    echo
    echo "### Packages removed ($N_REM)"
    echo
    if [[ $N_REM -gt 0 ]]; then
      echo "| Package | Version | Type |"; echo "|---|---|---|"
      esc < "$TMP/pkg_removed" | awk -F'\t' '{printf "| %s | `%s` | %s |\n",$1,$2,$3}'
    else echo "_None._"; fi
    echo
    echo "### Configuration changes ($N_CFG)"
    echo
    if [[ $N_CFG -gt 0 ]]; then
      echo "| Setting | Before | After |"; echo "|---|---|---|"
      esc < "$TMP/cfg_diff" | awk -F'\t' '{printf "| `%s` | %s | %s |\n",$1,$2,$3}'
    else echo "_None._"; fi
  fi
  echo

  echo "## Runtime configuration"
  echo
  echo "| Setting | Value |"
  echo "|---|---|"
  echo "| User | $(code "$(cfg config.user)") |"
  echo "| Working dir | $(code "$(cfg config.workdir)") |"
  echo "| Entrypoint | $(code "$(cfg config.entrypoint)") |"
  echo "| Cmd | $(code "$(cfg config.cmd)") |"
  echo "| Exposed ports | $(code "$(cfg config.ports)") |"
  echo "| Volumes | $(code "$(cfg config.volumes)") |"
  echo "| Stop signal | $(code "$(cfg config.stopsignal)") |"
  echo
  if grep -q '^env\.' "$DEST/config.txt"; then
    echo "### Environment"
    echo
    echo "| Variable | Value |"; echo "|---|---|"
    grep '^env\.' "$DEST/config.txt" | sed 's/^env\.//' | esc | awk '{i=index($0,"="); printf "| `%s` | `%s` |\n", substr($0,1,i-1), substr($0,i+1)}'
    echo
  fi
  if grep -q '^label\.' "$DEST/config.txt"; then
    echo "### Labels"
    echo
    echo "| Label | Value |"; echo "|---|---|"
    grep '^label\.' "$DEST/config.txt" | sed 's/^label\.//' | esc | awk '{i=index($0,"="); printf "| `%s` | %s |\n", substr($0,1,i-1), substr($0,i+1)}'
    echo
  fi

  echo "## Software inventory"
  echo
  echo "| Type | Packages |"; echo "|---|---|"
  cut -f3 "$DEST/packages.tsv" | sort | uniq -c | sort -rn | awk '{printf "| %s | %s |\n",$2,$1}'
  echo
  echo "### Licenses"
  echo
  echo "| License | Packages |"; echo "|---|---|"
  cut -f4 "$DEST/packages.tsv" | sed 's/^$/(unknown)/' | sort | uniq -c | sort -rn | head -15 \
    | esc | awk '{n=$1; $1=""; sub(/^ /,""); printf "| %s | %s |\n",$0,n}'
  echo
  echo "<details>"
  echo "<summary>All $N_PKG packages</summary>"
  echo
  echo "| Package | Version | Type | License |"; echo "|---|---|---|---|"
  esc < "$DEST/packages.tsv" | awk -F'\t' '{printf "| %s | `%s` | %s | %s |\n",$1,$2,$3,($4==""?"—":$4)}'
  echo
  echo "</details>"
  echo
  echo "## Reproduce"
  echo
  echo '```bash'
  echo "podman pull $IMAGE"
  echo "podman image inspect $IMAGE"
  echo "syft podman:$IMAGE -o spdx-json"
  echo '```'
} > "$R"

# ---------------------------------------------------------------- 7. changelog
CL="$OUT/CHANGELOG.md"
ENTRY="$TMP/entry.md"
{
  echo "## [$VERSION]($VERSION/RELEASE.md) — $(date -u +%Y-%m-%d)"
  echo
  echo "- Image: \`$IMAGE\` ($(cfg image.digest | cut -c1-19))"
  if [[ -n "$PREV" ]]; then
    echo "- Since $PREV: +$N_ADD added, −$N_REM removed, $N_CHG updated packages; $N_CFG config changes"
    head -10 "$TMP/pkg_changed" | awk -F'\t' '{printf "  - %s `%s` → `%s`\n",$1,$2,$3}'
    [[ $N_CHG -gt 10 ]] && echo "  - …and $((N_CHG-10)) more"
    awk -F'\t' '{printf "  - config `%s`: %s → %s\n",$1,$2,$3}' "$TMP/cfg_diff" | head -5
  else
    echo "- Baseline release, $N_PKG packages"
  fi
  echo
} > "$ENTRY"

if [[ -f "$CL" ]]; then
  # drop any earlier entry for this version (e.g. --force), then insert new entry after the header
  awk -v v="## [$VERSION]" 'index($0,v)==1{skip=1;next} /^## \[/{skip=0} !skip' "$CL" > "$TMP/cl_old"
  { head -2 "$TMP/cl_old"; cat "$ENTRY"; tail -n +3 "$TMP/cl_old"; } > "$CL"
else
  { echo "# Changelog"; echo; cat "$ENTRY"; } > "$CL"
fi

echo "$VERSION" > "$OUT/.latest"
info "Wrote $R"
info "Updated $CL"
