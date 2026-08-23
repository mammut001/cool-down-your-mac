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

echo "==> 1/8 Build ${CONFIG}"
bash "${ROOT}/Packaging/scripts/build-release.sh" "${CONFIG}"

echo "==> 2/8 Sign + notarize app"
bash "${ROOT}/Packaging/scripts/sign-notarize.sh" "${APP}"

echo "==> 3/8 Create DMG"
bash "${ROOT}/Packaging/scripts/make-dmg.sh" "${APP}" "${DMG}"

echo "==> 4/8 Notarize + staple DMG"
xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${DMG}"

echo "==> 5/8 Verify release artifact"
bash "${ROOT}/Packaging/scripts/verify-release.sh" "${APP}" "${DMG}"

echo "==> 6/8 Write SHA-256"
shasum -a 256 "${DMG}" | tee "${CHECKSUM}"

echo "==> 7/8 Create Sparkle update archive"
VERSION="$(defaults read "${APP}/Contents/Info.plist" CFBundleShortVersionString)"
SPARKLE_ZIP="${DIST}/CoolDownPro-${VERSION}.zip"
rm -f "${SPARKLE_ZIP}"
ditto -c -k --keepParent "${APP}" "${SPARKLE_ZIP}"

echo "==> 8/8 Sign Sparkle update and update appcast"
SPARKLE_BIN="${DIST}/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "${SPARKLE_BIN}/generate_appcast" ]]; then
  SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -1 || true)"
fi

if [[ -n "${SPARKLE_BIN}" && -x "${SPARKLE_BIN}/generate_appcast" ]]; then
  mkdir -p "${ROOT}/Packaging/Sparkle"
  "${SPARKLE_BIN}/generate_appcast" \
    --download-url-prefix "https://github.com/mammut001/cool-down-your-mac/releases/download/v${VERSION}/" \
    -o "${ROOT}/Packaging/Sparkle" \
    "${DIST}"
  echo "Updated: ${ROOT}/Packaging/Sparkle/appcast.xml"
else
  echo "Notice: Sparkle generate_appcast tool not found; skipping automatic appcast generation."
fi

echo
echo "Release artifacts ready:"
echo "  ${DMG}"
echo "  ${CHECKSUM}"
echo "  ${SPARKLE_ZIP}"
echo "  ${ROOT}/Packaging/Sparkle/appcast.xml"
echo
echo "Next: create a GitHub Release, attach DMG, SHA-256, and Sparkle ZIP, then publish/commit appcast.xml."
