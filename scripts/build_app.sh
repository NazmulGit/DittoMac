#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) release DittoMac.app into dist/ and
# ad-hoc signs it with the hardened runtime.
#
# Usage: scripts/build_app.sh VERSION [BUILD]
#   VERSION  e.g. 1.2.0          (CFBundleShortVersionString)
#   BUILD    e.g. 42             (CFBundleVersion, defaults to VERSION)
#
# Environment:
#   SIGN_IDENTITY  codesign identity to use instead of ad-hoc "-"
set -euo pipefail

usage() {
    echo "usage: $(basename "$0") VERSION [BUILD]" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
VERSION="$1"
BUILD="${2:-$1}"

VERSION_RE='^[0-9]+(\.[0-9]+)*$'
[[ "${VERSION}" =~ ${VERSION_RE} ]] || { echo "build_app.sh: invalid VERSION '${VERSION}'" >&2; exit 2; }
[[ "${BUILD}" =~ ${VERSION_RE} ]] || { echo "build_app.sh: invalid BUILD '${BUILD}'" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

SCRATCH_PATH="${ROOT}/.build-release"
EXE_NAME="DittoMac"
APP="${ROOT}/dist/${EXE_NAME}.app"
ENTITLEMENTS="${ROOT}/Resources/DittoMac.entitlements"
ICON="${ROOT}/Resources/AppIcon.icns"
PLIST_TEMPLATE="${ROOT}/Resources/Info.plist"
LICENSE_FILE="${ROOT}/LICENSE"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

for required in "${ENTITLEMENTS}" "${ICON}" "${PLIST_TEMPLATE}" "${LICENSE_FILE}"; do
    [[ -f "${required}" ]] || { echo "build_app.sh: missing ${required}" >&2; exit 1; }
done

echo "==> Building universal release binary"
swift build -c release --arch arm64 --arch x86_64 --scratch-path "${SCRATCH_PATH}"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "${SCRATCH_PATH}" --show-bin-path)"
BINARY="${BIN_DIR}/${EXE_NAME}"
[[ -x "${BINARY}" ]] || { echo "build_app.sh: binary not found at ${BINARY}" >&2; exit 1; }

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BINARY}" "${APP}/Contents/MacOS/${EXE_NAME}"
chmod 755 "${APP}/Contents/MacOS/${EXE_NAME}"
cp "${ICON}" "${APP}/Contents/Resources/AppIcon.icns"
cp "${LICENSE_FILE}" "${APP}/Contents/Resources/LICENSE"

# Substitute the version placeholders. VERSION and BUILD were validated above,
# so they contain only digits and dots and are safe in a sed replacement.
sed -e "s/__VERSION__/${VERSION}/g" -e "s/__BUILD__/${BUILD}/g" \
    "${PLIST_TEMPLATE}" > "${APP}/Contents/Info.plist"
plutil -lint "${APP}/Contents/Info.plist" >/dev/null

echo "==> Verifying architectures"
ARCHS="$(lipo -archs "${APP}/Contents/MacOS/${EXE_NAME}")"
echo "    ${ARCHS}"
for arch in arm64 x86_64; do
    case " ${ARCHS} " in
        *" ${arch} "*) ;;
        *) echo "build_app.sh: binary is missing ${arch} slice (got: ${ARCHS})" >&2; exit 1 ;;
    esac
done

echo "==> Signing (identity: ${SIGN_IDENTITY})"
# Ad-hoc signatures cannot be timestamped, so --timestamp=none is used for "-".
# A real Developer ID identity needs a secure timestamp for notarization.
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    TIMESTAMP_FLAG="--timestamp=none"
else
    TIMESTAMP_FLAG="--timestamp"
fi
codesign --force --deep --options runtime "${TIMESTAMP_FLAG}" \
    --entitlements "${ENTITLEMENTS}" --sign "${SIGN_IDENTITY}" "${APP}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"

echo "==> Built ${APP} (version ${VERSION}, build ${BUILD})"
