#!/usr/bin/env bash
# Explicitly publish a prepared release to GitHub Releases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="${ROOT}/dist"
APP="${DIST}/build/Build/Products/Release/CoolDownPro.app"

if [[ ! -d "${APP}" ]]; then
  echo "error: built app not found at ${APP}. Run release.sh first." >&2
  exit 1
fi

VERSION="$(defaults read "${APP}/Contents/Info.plist" CFBundleShortVersionString)"
TAG="v${VERSION}"
DMG="${DIST}/CoolDownPro.dmg"
CHECKSUM="${DIST}/CoolDownPro.dmg.sha256"
SPARKLE_ZIP="${DIST}/CoolDownPro-${VERSION}.zip"

if [[ ! -f "${DMG}" || ! -f "${CHECKSUM}" || ! -f "${SPARKLE_ZIP}" ]]; then
  echo "error: required distribution artifacts missing in ${DIST}" >&2
  exit 1
fi

echo "Publishing GitHub Release ${TAG}..."
gh release create "${TAG}" \
  "${DMG}" \
  "${CHECKSUM}" \
  "${SPARKLE_ZIP}" \
  --title "Cool Down Pro ${TAG}" \
  --notes "Cool Down Pro ${TAG} release with in-app update archive."

echo "Release ${TAG} published successfully."
echo "Now commit and push any updated Packaging/Sparkle/appcast.xml to main."
