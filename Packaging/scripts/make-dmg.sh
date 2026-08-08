#!/usr/bin/env bash
# Create a simple drag-to-Applications DMG for Cool Down Pro.
set -euo pipefail

APP_PATH="${1:-}"
OUT_DMG="${2:-./dist/CoolDownPro.dmg}"
VOLUME_NAME="Cool Down Pro"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "Usage: $0 /path/to/CoolDownPro.app [out.dmg]"
  exit 1
fi

mkdir -p "$(dirname "${OUT_DMG}")"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

cp -R "${APP_PATH}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${OUT_DMG}"
echo "DMG written to ${OUT_DMG}"
