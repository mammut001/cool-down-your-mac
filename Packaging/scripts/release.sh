#!/usr/bin/env bash
# Build, sign, notarize, package, verify, and checksum a Cool Down Pro release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="${1:-Release}"
PROFILE="${NOTARY_PROFILE:-cooldown-notary}"
DIST="${ROOT}/dist"
APP="${DIST}/build/Build/Products/${CONFIG}/CoolDownPro.app"
DMG="${DIST}/CoolDownPro.dmg"
CHECKSUM="${DMG}.sha256"

cd "${ROOT}"
mkdir -p "${DIST}"
rm -f "${DMG}" "${CHECKSUM}"

echo "==> 1/6 Build ${CONFIG}"
bash "${ROOT}/Packaging/scripts/build-release.sh" "${CONFIG}"

echo "==> 2/6 Sign + notarize app"
bash "${ROOT}/Packaging/scripts/sign-notarize.sh" "${APP}"

echo "==> 3/6 Create DMG"
bash "${ROOT}/Packaging/scripts/make-dmg.sh" "${APP}" "${DMG}"

echo "==> 4/6 Notarize + staple DMG"
xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${DMG}"

echo "==> 5/6 Verify release artifact"
bash "${ROOT}/Packaging/scripts/verify-release.sh" "${APP}" "${DMG}"

echo "==> 6/6 Write SHA-256"
shasum -a 256 "${DMG}" | tee "${CHECKSUM}"

echo
echo "Release artifact ready:"
echo "  ${DMG}"
echo "  ${CHECKSUM}"
echo
echo "Next: create a GitHub Release, attach both files, and copy the checksum into the release notes."
