#!/usr/bin/env bash
# Explicitly publish a verified Cool Down Pro release to GitHub Releases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="${ROOT}/dist"
APP="${DIST}/build/Build/Products/Release/CoolDownPro.app"
APPCAST="${ROOT}/Packaging/Sparkle/appcast.xml"

if [[ ! -d "${APP}" ]]; then
  echo "error: built application not found at ${APP}. Run release.sh first." >&2
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

TAG="v${VERSION}"
DMG="${DIST}/CoolDownPro.dmg"
CHECKSUM="${DIST}/CoolDownPro.dmg.sha256"
SPARKLE_ZIP="${DIST}/CoolDownPro-${VERSION}.zip"
EXPECTED_ZIP_URL="https://github.com/mammut001/cool-down-your-mac/releases/download/v${VERSION}/CoolDownPro-${VERSION}.zip"

# Verify all release artifacts exist
for artifact in "${DMG}" "${CHECKSUM}" "${SPARKLE_ZIP}" "${APPCAST}"; do
  if [[ ! -f "${artifact}" || ! -s "${artifact}" ]]; then
    echo "error: required release artifact missing or empty: ${artifact}" >&2
    exit 1
  fi
done

# Verify DMG SHA-256 matches
(
  cd "${DIST}"
  shasum -a 256 -c "$(basename "${CHECKSUM}")"
)

# Validate appcast matches the payload to be published
bash "${ROOT}/Packaging/scripts/validate-appcast.sh" "${APPCAST}" "${VERSION}" "${BUILD}" "${EXPECTED_ZIP_URL}"

echo "Publishing GitHub Release ${TAG}..."
gh release create "${TAG}" \
  "${DMG}" \
  "${CHECKSUM}" \
  "${SPARKLE_ZIP}" \
  --title "Cool Down Pro ${TAG}" \
  --notes "Cool Down Pro ${TAG} (build ${BUILD}) release with DMG and Sparkle in-app update archive."

echo
echo "=================================================="
echo "GitHub Release ${TAG} published successfully!"
echo "Assets uploaded:"
echo "  - CoolDownPro.dmg"
echo "  - CoolDownPro.dmg.sha256"
echo "  - CoolDownPro-${VERSION}.zip"
echo "=================================================="
echo
echo "FINAL STEP: Publish the new appcast to production feed:"
echo "  git add Packaging/Sparkle/appcast.xml"
echo "  git commit -m \"release: update Sparkle appcast for ${TAG}\""
echo "  git push origin main"
