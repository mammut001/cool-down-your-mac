#!/usr/bin/env bash
# Validate the signed app and final DMG before publishing a release.
set -euo pipefail

APP_PATH="${1:-}"
DMG_PATH="${2:-}"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "Usage: $0 /path/to/CoolDownPro.app /path/to/CoolDownPro.dmg" >&2
  exit 1
fi

if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
  echo "Usage: $0 /path/to/CoolDownPro.app /path/to/CoolDownPro.dmg" >&2
  exit 1
fi

echo "==> Verify app signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "==> Validate app notarization ticket"
xcrun stapler validate "${APP_PATH}"

echo "==> Gatekeeper assess app"
spctl --assess --type execute --verbose=4 "${APP_PATH}"

echo "==> Verify DMG filesystem"
hdiutil verify "${DMG_PATH}"

echo "==> Validate DMG notarization ticket"
xcrun stapler validate "${DMG_PATH}"

MOUNT_POINT="$(mktemp -d /tmp/cooldown-release.XXXXXX)"
cleanup() {
  if mount | grep -Fq " on ${MOUNT_POINT} "; then
    hdiutil detach "${MOUNT_POINT}" -quiet || true
  fi
  rmdir "${MOUNT_POINT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Mount DMG read-only"
hdiutil attach "${DMG_PATH}" -nobrowse -readonly -mountpoint "${MOUNT_POINT}" -quiet

MOUNTED_APP="${MOUNT_POINT}/CoolDownPro.app"
if [[ ! -d "${MOUNTED_APP}" ]]; then
  echo "error: CoolDownPro.app missing from mounted DMG" >&2
  exit 1
fi

echo "==> Verify app inside DMG"
codesign --verify --deep --strict --verbose=2 "${MOUNTED_APP}"
spctl --assess --type execute --verbose=4 "${MOUNTED_APP}"

echo "==> Release verification passed"
