#!/usr/bin/env bash
# Packages dist/DittoMac.app into dist/DittoMac-VERSION-universal.dmg with an
# Applications symlink and a READ ME FIRST.txt, then verifies it and writes a
# SHA-256 checksum file next to it.
#
# Usage: scripts/make_dmg.sh VERSION
set -euo pipefail

usage() {
    echo "usage: $(basename "$0") VERSION" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
VERSION="$1"
[[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "make_dmg.sh: invalid VERSION '${VERSION}'" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST="${ROOT}/dist"
APP="${DIST}/DittoMac.app"
DMG_NAME="DittoMac-${VERSION}-universal.dmg"
DMG="${DIST}/${DMG_NAME}"
CHECKSUM="${DMG}.sha256"

[[ -d "${APP}" ]] || { echo "make_dmg.sh: ${APP} not found; run build_app.sh first" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dittomac-dmg.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT

echo "==> Staging"
# ditto preserves the code signature and extended attributes that cp can drop.
ditto "${APP}" "${STAGE}/DittoMac.app"
ln -s /Applications "${STAGE}/Applications"

cat > "${STAGE}/READ ME FIRST.txt" <<'EOF'
DittoMac - installation notes
=============================

1. Drag DittoMac into the Applications folder.

2. DittoMac is not signed with an Apple Developer ID, so macOS blocks the
   first launch. Use one of these:

   a) Right-click (or Control-click) DittoMac in Applications, choose Open,
      then click Open in the dialog.

   b) Try to open it normally, then go to System Settings > Privacy & Security,
      scroll down to the message about DittoMac, and click Open Anyway.

   c) Or remove the download quarantine flag in Terminal:

        xattr -dr com.apple.quarantine /Applications/DittoMac.app

      Only do this for a copy of DittoMac you downloaded from the official
      project release page.

3. Auto-paste needs Accessibility permission. Without it DittoMac still copies
   the selected clip to the clipboard, and you press Command-V yourself.
   To enable auto-paste, open System Settings > Privacy & Security >
   Accessibility and turn DittoMac on.

   Because this build is not signed with a stable identity, you may need to
   turn it off and on again after each update.

DittoMac is free software under the GNU GPL v3 (see the LICENSE file inside
the app bundle). It is based on Ditto by Scott Brogden.
EOF

echo "==> Creating ${DMG_NAME}"
rm -f "${DMG}" "${CHECKSUM}"
hdiutil create -volname "DittoMac ${VERSION}" -srcfolder "${STAGE}" \
    -ov -format UDZO -fs HFS+ "${DMG}"

echo "==> Verifying disk image"
hdiutil verify "${DMG}"

echo "==> Writing checksum"
# Relative file name in the checksum file so `shasum -c` works from dist/.
(cd "${DIST}" && shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256")
cat "${CHECKSUM}"

echo "==> DMG ready: ${DMG}"
