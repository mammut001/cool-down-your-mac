#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="${1:-Release}"
DEST="${ROOT}/dist/build"
mkdir -p "${ROOT}/dist"

cd "${ROOT}"
xcodegen generate
xcodebuild -project CoolDownYourMac.xcodeproj \
  -scheme CoolDownPro \
  -configuration "${CONFIG}" \
  -derivedDataPath "${DEST}" \
  build

APP="${DEST}/Build/Products/${CONFIG}/CoolDownPro.app"
echo "Built: ${APP}"
echo "Next: Packaging/scripts/sign-notarize.sh \"${APP}\""
echo "Then: Packaging/scripts/make-dmg.sh \"${APP}\" \"${ROOT}/dist/CoolDownPro.dmg\""
