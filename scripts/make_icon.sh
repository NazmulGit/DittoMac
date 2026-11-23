#!/usr/bin/env bash
# Renders the 1024 px master icon, builds AppIcon.iconset with sips and packs it
# into Resources/AppIcon.icns with iconutil.
#
# Outputs:
#   docs/assets/icon.png        1024x1024 master PNG
#   Resources/AppIcon.icns      app icon used by build_app.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MASTER="${ROOT}/docs/assets/icon.png"
ICNS="${ROOT}/Resources/AppIcon.icns"
GENERATOR="${SCRIPT_DIR}/make_icon.swift"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dittomac-icon.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "$(dirname "${MASTER}")" "$(dirname "${ICNS}")"

# Render the master PNG. Fall back to swiftc if script mode is unavailable.
if ! swift "${GENERATOR}" "${MASTER}"; then
    echo "make_icon.sh: 'swift' script mode failed, retrying with swiftc" >&2
    swiftc -O -o "${WORK}/make_icon" "${GENERATOR}"
    "${WORK}/make_icon" "${MASTER}"
fi

[[ -s "${MASTER}" ]] || { echo "make_icon.sh: ${MASTER} was not created" >&2; exit 1; }

ICONSET="${WORK}/AppIcon.iconset"
mkdir -p "${ICONSET}"

# name pixel-size pairs for a standard macOS iconset.
ENTRIES=(
    "icon_16x16.png 16"
    "icon_16x16@2x.png 32"
    "icon_32x32.png 32"
    "icon_32x32@2x.png 64"
    "icon_128x128.png 128"
    "icon_128x128@2x.png 256"
    "icon_256x256.png 256"
    "icon_256x256@2x.png 512"
    "icon_512x512.png 512"
    "icon_512x512@2x.png 1024"
)

for entry in "${ENTRIES[@]}"; do
    name="${entry% *}"
    px="${entry#* }"
    sips -s format png -z "${px}" "${px}" "${MASTER}" --out "${ICONSET}/${name}" >/dev/null
done

iconutil -c icns "${ICONSET}" -o "${ICNS}"

[[ -s "${ICNS}" ]] || { echo "make_icon.sh: ${ICNS} was not created" >&2; exit 1; }
echo "Wrote ${MASTER}"
echo "Wrote ${ICNS}"
