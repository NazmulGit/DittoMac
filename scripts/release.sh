#!/usr/bin/env bash
# Full release pipeline: tests, universal app build, signed bundle, DMG.
#
# Usage: scripts/release.sh VERSION [BUILD]
set -euo pipefail

usage() {
    echo "usage: $(basename "$0") VERSION [BUILD]" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
VERSION="$1"
BUILD="${2:-$1}"
[[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "release.sh: invalid VERSION '${VERSION}'" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

echo "==> Running tests"
"${ROOT}/scripts/test.sh"

echo "==> Building app"
"${SCRIPT_DIR}/build_app.sh" "${VERSION}" "${BUILD}"

echo "==> Packaging DMG"
"${SCRIPT_DIR}/make_dmg.sh" "${VERSION}"

echo
echo "Release ${VERSION} (build ${BUILD}) artifacts:"
echo "  App:      ${ROOT}/dist/DittoMac.app"
echo "  DMG:      ${ROOT}/dist/DittoMac-${VERSION}-universal.dmg"
echo "  SHA-256:  ${ROOT}/dist/DittoMac-${VERSION}-universal.dmg.sha256"
