#!/usr/bin/env bash
# Build, sign, notarize, package, verify, checksum, and generate Sparkle updates for Cool Down Pro.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="${1:-Release}"
PROFILE="${NOTARY_PROFILE:-cooldown-notary}"
DIST="${ROOT}/dist"
APP="${DIST}/build/Build/Products/${CONFIG}/CoolDownPro.app"
DMG="${DIST}/CoolDownPro.dmg"
CHECKSUM="${DMG}.sha256"
APPCAST="${ROOT}/Packaging/Sparkle/appcast.xml"

cd "${ROOT}"
mkdir -p "${DIST}"
rm -f "${DMG}" "${CHECKSUM}"

echo "==> 1/8 Build ${CONFIG}"
bash "${ROOT}/Packaging/scripts/build-release.sh" "${CONFIG}"

if [[ ! -d "${APP}" ]]; then
  echo "error: built application not found at ${APP}" >&2
  exit 1
fi

VERSION="$(defaults read "${APP}/Contents/Info.plist" CFBundleShortVersionString | xargs)"
BUILD="$(defaults read "${APP}/Contents/Info.plist" CFBundleVersion | xargs)"

if [[ -z "${VERSION}" || "${VERSION}" =~ [[:space:]] ]]; then
  echo "error: invalid or empty CFBundleShortVersionString: '${VERSION}'" >&2
  exit 1
fi

if [[ -z "${BUILD}" || "${BUILD}" =~ [[:space:]] ]]; then
  echo "error: invalid or empty CFBundleVersion: '${BUILD}'" >&2
  exit 1
fi

echo "==> 2/8 Sign + notarize app (v${VERSION} build ${BUILD})"
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
SPARKLE_ZIP="${DIST}/CoolDownPro-${VERSION}.zip"
rm -f "${SPARKLE_ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${SPARKLE_ZIP}"

if [[ ! -f "${SPARKLE_ZIP}" || ! -s "${SPARKLE_ZIP}" ]]; then
  echo "error: failed to create Sparkle update ZIP at ${SPARKLE_ZIP}" >&2
  exit 1
fi

echo "==> 8/8 Sign Sparkle update and update appcast"
SPARKLE_BIN="${SPARKLE_BIN:-}"
if [[ -z "${SPARKLE_BIN}" ]]; then
  SPARKLE_BIN="${DIST}/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
fi

if [[ ! -x "${SPARKLE_BIN}/generate_appcast" ]]; then
  echo "error: Sparkle generate_appcast tool not found at '${SPARKLE_BIN}'" >&2
  exit 1
fi

mkdir -p "$(dirname "${APPCAST}")"
EXPECTED_ZIP_URL="https://github.com/mammut001/cool-down-your-mac/releases/download/v${VERSION}/CoolDownPro-${VERSION}.zip"

# Stage only update archives for generate_appcast to avoid traversing build directories
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT INT TERM
cp "${SPARKLE_ZIP}" "${STAGING_DIR}/"

"${SPARKLE_BIN}/generate_appcast" \
  --download-url-prefix "https://github.com/mammut001/cool-down-your-mac/releases/download/v${VERSION}/" \
  -o "${APPCAST}" \
  "${STAGING_DIR}"

rm -rf "${STAGING_DIR}"
trap - EXIT INT TERM

echo "==> Validating generated appcast"
bash "${ROOT}/Packaging/scripts/validate-appcast.sh" "${APPCAST}" "${VERSION}" "${BUILD}" "${EXPECTED_ZIP_URL}"

echo
echo "=================================================="
echo "Cool Down Pro Release Summary"
echo "=================================================="
echo "Version:           ${VERSION}"
echo "Build:             ${BUILD}"
echo "DMG:               ${DMG}"
echo "DMG SHA-256:       $(cat "${CHECKSUM}")"
echo "Sparkle ZIP:       ${SPARKLE_ZIP}"
echo "Appcast:           ${APPCAST}"
echo "Feed URL:          https://raw.githubusercontent.com/mammut001/cool-down-your-mac/main/Packaging/Sparkle/appcast.xml"
echo "Release Asset URL: ${EXPECTED_ZIP_URL}"
echo "=================================================="
echo
echo "Next steps:"
echo "  1. Publish release assets to GitHub Releases:"
echo "       bash Packaging/scripts/publish-release.sh"
echo "  2. ONLY after GitHub Release is live with all assets:"
echo "       git add Packaging/Sparkle/appcast.xml"
echo "       git commit -m \"release: update Sparkle appcast for v${VERSION}\""
echo "       git push origin main"
