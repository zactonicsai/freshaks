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
#
# Script layout:
#   1. Globals          defaults and shared state
#   2. Helpers          logging, usage, small formatting utilities
#   3. Setup            argument parsing, requirement checks
#   4. Collect          image inspect, SBOM, version, release directory
#   5. Normalize        packages.tsv and config.txt
#   6. Diff             packages and config against the previous release
#   7. Render           RELEASE.md, one function per section
#   8. Changelog        CHANGELOG.md and the .latest pointer
#   9. main             runs the steps in order

set -euo pipefail

# ============================================================== 1. globals
# Options
IMAGE=""          # image reference (positional argument)
SBOM_IN=""        # --sbom: existing SBOM file
VERSION=""        # --version: release version
PREV=""           # --previous: release to compare against
OUT="./releases"  # --out: releases directory
FORCE=0           # --force: overwrite an existing release

# State filled in by the steps below
TMP=""            # scratch directory, removed on exit
DEST=""           # $OUT/$VERSION
VERSION_SRC=""    # where the version came from (for logging)
SBOM_FMT=""       # e.g. "SPDX-2.3" or "CycloneDX 1.5"
N_PKG=0 N_ADD=0 N_REM=0 N_CHG=0 N_CFG=0

# ============================================================== 2. helpers
die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
info() { echo ">> $*" >&2; }

# Print the header comment block (everything up to the first non-comment line).
usage() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# Read one value from the flattened config, e.g. `cfg config.user`.
cfg() { grep -m1 "^$1=" "$DEST/config.txt" | cut -d= -f2- || true; }

# Wrap a value in backticks, or show a placeholder when empty.
code() { if [[ -n "$1" ]]; then printf '`%s`' "$1"; else printf '_(not set)_'; fi; }

# Escape pipes so values do not break Markdown tables.
esc() { sed 's/|/\\|/g'; }

# Count lines in a file.
count() { wc -l < "$1" | tr -d ' '; }

# ============================================================== 3. setup
parse_args() {
  need_val() { [[ $# -ge 2 && -n "$2" ]] || die "option $1 requires a value"; }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sbom)     need_val "$@"; SBOM_IN="$2"; shift 2 ;;
      --version)  need_val "$@"; VERSION="$2"; shift 2 ;;
      --previous) need_val "$@"; PREV="$2"; shift 2 ;;
      --out)      need_val "$@"; OUT="$2"; shift 2 ;;
      --force)    FORCE=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      -*)         die "unknown option: $1 (see --help)" ;;
      *)          if [[ -z "$IMAGE" ]]; then IMAGE="$1"; else die "unexpected argument: $1"; fi; shift ;;
    esac
  done
  [[ -n "$IMAGE" ]] || die "missing IMAGE (see --help)"
}

check_requirements() {
  command -v podman >/dev/null || die "podman not found"
  command -v jq >/dev/null     || die "jq not found"
  if [[ -n "$SBOM_IN" ]]; then
    [[ -f "$SBOM_IN" ]] || die "SBOM not found: $SBOM_IN"
  else
    command -v syft >/dev/null || die "syft not found; install it or pass --sbom FILE"
  fi
}

# ============================================================== 4. collect
# Snapshot `podman image inspect` to $TMP/config.json, pulling if needed.
inspect_image() {
  info "Inspecting image $IMAGE"
  if ! podman image inspect "$IMAGE" > "$TMP/inspect.json" 2>/dev/null; then
    info "Image not found locally, pulling"
    podman pull "$IMAGE" >/dev/null || die "could not pull $IMAGE"
    podman image inspect "$IMAGE" > "$TMP/inspect.json"
  fi
  jq '.[0]' "$TMP/inspect.json" > "$TMP/config.json"
}

# Put the SBOM at $TMP/sbom.json (copied from --sbom or generated by syft)
# and check its format before anything is written to the releases directory.
obtain_sbom() {
  if [[ -n "$SBOM_IN" ]]; then
    info "Using existing SBOM $SBOM_IN"
    cp "$SBOM_IN" "$TMP/sbom.json"
  else
    info "Generating SBOM with syft (this can take a while)"
    syft "podman:$IMAGE" -o spdx-json="$TMP/sbom.json" -q
  fi

  SBOM_FMT=$(jq -r '
    if .spdxVersion then .spdxVersion
    elif .bomFormat == "CycloneDX" then "CycloneDX " + (.specVersion // "")
    else "unknown" end' "$TMP/sbom.json") || die "SBOM is not valid JSON"
  [[ "$SBOM_FMT" != "unknown" ]] || die "unrecognized SBOM format (need SPDX or CycloneDX JSON)"
  info "SBOM format: $SBOM_FMT"
}

# Version precedence: --version, OCI version label, image tag, UTC timestamp.
resolve_version() {
  VERSION_SRC="--version"
  if [[ -z "$VERSION" ]]; then
    VERSION=$(jq -r '.Config.Labels["org.opencontainers.image.version"] // .Labels["org.opencontainers.image.version"] // empty' "$TMP/config.json")
    VERSION_SRC="image label"
  fi
  if [[ -z "$VERSION" ]]; then
    local ref="${IMAGE##*/}"
    if [[ "$ref" == *:* && "$ref" != *@* ]]; then VERSION="${ref##*:}"; fi
    if [[ "$VERSION" == "latest" ]]; then VERSION=""; fi
    VERSION_SRC="image tag"
  fi
  if [[ -z "$VERSION" ]]; then
    VERSION=$(date -u +%Y%m%d-%H%M%S)
    VERSION_SRC="timestamp"
  fi
  VERSION="${VERSION//\//-}"
  info "Release version: $VERSION (from $VERSION_SRC)"
}

# Decide which release to compare against (empty PREV means baseline).
resolve_previous() {
  if [[ -z "$PREV" && -f "$OUT/.latest" ]]; then PREV=$(cat "$OUT/.latest"); fi
  if [[ "$PREV" == "$VERSION" ]]; then PREV=""; fi
  if [[ -n "$PREV" && ! -d "$OUT/$PREV" ]]; then
    warn "previous release '$PREV' not found; treating as first release"
    PREV=""
  fi
  if [[ -n "$PREV" ]]; then
    info "Previous release: $PREV"
  else
    info "No previous release; this one is the baseline"
  fi
}

# Create $OUT/$VERSION and store the raw snapshots.
prepare_release_dir() {
  DEST="$OUT/$VERSION"
  if [[ -d "$DEST" ]]; then
    [[ $FORCE -eq 1 ]] || die "release $VERSION already exists (use --force)"
    info "Overwriting existing release $VERSION (--force)"
  fi
  mkdir -p "$DEST"
  cp "$TMP/sbom.json" "$TMP/config.json" "$DEST/"
  info "Release directory: $DEST"
}

# ============================================================== 5. normalize
# SBOM -> packages.tsv: name<TAB>version<TAB>type<TAB>license (SPDX or CycloneDX)
normalize_packages() {
  info "Normalizing package list"
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

  N_PKG=$(count "$DEST/packages.tsv")
  info "Found $N_PKG packages"
  if [[ $N_PKG -eq 0 ]]; then warn "SBOM contains no versioned packages"; fi
}

# Image config -> config.txt: flattened key=value lines (env as a map, secrets masked)
flatten_config() {
  info "Flattening image configuration"
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
}

# ============================================================== 6. diff
# Writes $TMP/pkg_added, pkg_removed, pkg_changed (tab-separated).
diff_packages() {
  # key = type|name ; value = sorted, comma-joined versions
  awk -F'\t' -v OFS='\t' '
    { k=$3"|"$1
      if (FILENAME==ARGV[1]) { if (k in o) v=o[k]","$2; else v=$2; o[k]=v }
      else                   { if (k in n) v=n[k]","$2; else v=$2; n[k]=v; lic[k]=$4 } }
    END {
      for (k in n) { split(k, p, "|")
        if (!(k in o))         print "A", p[2], n[k], p[1], lic[k]
        else if (o[k] != n[k]) print "C", p[2], o[k], n[k], p[1] }
      for (k in o) if (!(k in n)) { split(k, p, "|"); print "R", p[2], o[k], p[1] }
    }' "$OUT/$PREV/packages.tsv" "$DEST/packages.tsv" | sort -t$'\t' -k2,2 > "$TMP/pkgdiff"

  awk -F'\t' -v OFS='\t' '$1=="A"{print $2,$3,$4,$5}' "$TMP/pkgdiff" > "$TMP/pkg_added"
  awk -F'\t' -v OFS='\t' '$1=="R"{print $2,$3,$4}'    "$TMP/pkgdiff" > "$TMP/pkg_removed"

  # Label each change as an upgrade or downgrade using version sort.
  local name old new type hi dir
  while IFS=$'\t' read -r _ name old new type; do
    hi=$(printf '%s\n%s\n' "${old##*,}" "${new##*,}" | sort -V | tail -1)
    if [[ "$hi" == "${new##*,}" ]]; then dir="⬆ upgrade"; else dir="⬇ downgrade"; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$old" "$new" "$type" "$dir"
  done < <(awk -F'\t' '$1=="C"' "$TMP/pkgdiff") > "$TMP/pkg_changed"
}

# Writes $TMP/cfg_diff: key<TAB>before<TAB>after (the digest always changes, so it is skipped).
diff_config() {
  awk -v OFS='\t' '
    { i=index($0,"="); k=substr($0,1,i-1); v=substr($0,i+1)
      if (k=="image.digest") next
      if (FILENAME==ARGV[1]) o[k]=v; else n[k]=v }
    END {
      for (k in n) if (!(k in o)) print k, "_(none)_", n[k]; else if (o[k]!=n[k]) print k, o[k], n[k]
      for (k in o) if (!(k in n)) print k, o[k], "_(removed)_"
    }' "$OUT/$PREV/config.txt" "$DEST/config.txt" | sort > "$TMP/cfg_diff"
}

# Run both diffs (or leave empty results for a baseline) and set the counters.
compute_diff() {
  : > "$TMP/pkg_added"; : > "$TMP/pkg_removed"; : > "$TMP/pkg_changed"; : > "$TMP/cfg_diff"
  if [[ -n "$PREV" ]]; then
    info "Comparing with previous release $PREV"
    diff_packages
    diff_config
  fi
  N_ADD=$(count "$TMP/pkg_added")
  N_REM=$(count "$TMP/pkg_removed")
  N_CHG=$(count "$TMP/pkg_changed")
  N_CFG=$(count "$TMP/cfg_diff")
  if [[ -n "$PREV" ]]; then
    info "Packages: +$N_ADD added, -$N_REM removed, $N_CHG changed; config: $N_CFG changes"
  fi
}

# ============================================================== 7. render
render_header() {
  echo "# Release $VERSION"
  echo
  echo "> Image \`$IMAGE\` · generated $(date -u +"%Y-%m-%d %H:%M UTC")"
  echo
}

render_summary() {
  echo "## Summary"
  echo
  if [[ -n "$PREV" ]]; then
    echo "Compared with **$PREV**: $N_ADD packages added, $N_REM removed, $N_CHG version changes, $N_CFG configuration changes. $N_PKG packages total."
  else
    echo "First tracked release (baseline). $N_PKG packages total."
  fi
  echo
}

render_image() {
  local size_mb
  size_mb=$(jq -r '((.Size // 0) / 1048576 * 10 | floor) / 10' "$DEST/config.json")

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
  echo "| Size | ${size_mb} MB |"
  echo "| Layers | $(jq -r '(.RootFS.Layers // []) | length' "$DEST/config.json") |"
  echo "| SBOM format | $SBOM_FMT |"
  echo
}

render_changes() {
  echo "## Changes"
  echo
  if [[ -z "$PREV" ]]; then
    echo "_No previous release to compare with. This release is the baseline._"
    echo
    return 0
  fi

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
  echo
}

render_runtime() {
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
    grep '^env\.' "$DEST/config.txt" | sed 's/^env\.//' | esc \
      | awk '{i=index($0,"="); printf "| `%s` | `%s` |\n", substr($0,1,i-1), substr($0,i+1)}'
    echo
  fi

  if grep -q '^label\.' "$DEST/config.txt"; then
    echo "### Labels"
    echo
    echo "| Label | Value |"; echo "|---|---|"
    grep '^label\.' "$DEST/config.txt" | sed 's/^label\.//' | esc \
      | awk '{i=index($0,"="); printf "| `%s` | %s |\n", substr($0,1,i-1), substr($0,i+1)}'
    echo
  fi
}

render_inventory() {
  echo "## Software inventory"
  echo
  echo "| Type | Packages |"; echo "|---|---|"
  cut -f3 "$DEST/packages.tsv" | sort | uniq -c | sort -rn | awk '{printf "| %s | %s |\n",$2,$1}'
  echo

  echo "### Licenses"
  echo
  echo "| License | Packages |"; echo "|---|---|"
  cut -f4 "$DEST/packages.tsv" | sed 's/^$/(unknown)/' | sort | uniq -c | sort -rn | sed -n '1,15p' \
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
}

render_reproduce() {
  echo "## Reproduce"
  echo
  echo '```bash'
  echo "podman pull $IMAGE"
  echo "podman image inspect $IMAGE"
  echo "syft podman:$IMAGE -o spdx-json"
  echo '```'
}

# Assemble RELEASE.md. Section order is defined here.
render_release() {
  local out="$DEST/RELEASE.md"
  info "Rendering release notes"
  {
    render_header
    render_summary
    render_image
    render_changes
    render_runtime
    render_inventory
    render_reproduce
  } > "$out"
  info "Wrote $out"
}

# ============================================================== 8. changelog
render_changelog_entry() {
  echo "## [$VERSION]($VERSION/RELEASE.md) — $(date -u +%Y-%m-%d)"
  echo
  echo "- Image: \`$IMAGE\` ($(cfg image.digest | cut -c1-19))"
  if [[ -n "$PREV" ]]; then
    echo "- Since $PREV: +$N_ADD added, −$N_REM removed, $N_CHG updated packages; $N_CFG config changes"
    sed -n '1,10p' "$TMP/pkg_changed" | awk -F'\t' '{printf "  - %s `%s` → `%s`\n",$1,$2,$3}'
    if [[ $N_CHG -gt 10 ]]; then echo "  - …and $((N_CHG-10)) more"; fi
    sed -n '1,5p' "$TMP/cfg_diff" | awk -F'\t' '{printf "  - config `%s`: %s → %s\n",$1,$2,$3}'
  else
    echo "- Baseline release, $N_PKG packages"
  fi
  echo
}

# Insert the new entry at the top of CHANGELOG.md, replacing any earlier
# entry for the same version (e.g. after --force).
update_changelog() {
  local cl="$OUT/CHANGELOG.md" entry="$TMP/entry.md"
  render_changelog_entry > "$entry"

  if [[ -f "$cl" ]]; then
    awk -v v="## [$VERSION]" 'index($0,v)==1{skip=1;next} /^## \[/{skip=0} !skip' "$cl" > "$TMP/cl_old"
    { sed -n '1,2p' "$TMP/cl_old"; cat "$entry"; tail -n +3 "$TMP/cl_old"; } > "$cl"
  else
    { echo "# Changelog"; echo; cat "$entry"; } > "$cl"
  fi
  info "Updated $cl"
}

update_latest() {
  echo "$VERSION" > "$OUT/.latest"
  info "Marked $VERSION as latest"
}

print_result() {
  info "Done: release $VERSION, $N_PKG packages"
  if [[ -n "$PREV" ]]; then
    info "  vs $PREV: +$N_ADD / -$N_REM / $N_CHG changed packages, $N_CFG config changes"
  fi
  info "  notes:     $DEST/RELEASE.md"
  info "  changelog: $OUT/CHANGELOG.md"
}

# ============================================================== 9. main
main() {
  parse_args "$@"
  check_requirements

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  # Collect (nothing is written to $OUT until the inputs are known to be good)
  inspect_image
  obtain_sbom
  resolve_version
  resolve_previous
  prepare_release_dir

  # Normalize and compare
  normalize_packages
  flatten_config
  compute_diff

  # Write outputs
  render_release
  update_changelog
  update_latest
  print_result
}

main "$@"
