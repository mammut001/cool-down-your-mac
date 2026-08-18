#!/usr/bin/env bash
# Sign and notarize Cool Down Pro for Developer ID distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_PATH="${1:-}"
IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application: DONG PEI (Z5D5N7CU6L)}"
PROFILE="${NOTARY_PROFILE:-cooldown-notary}"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "Usage: $0 /path/to/CoolDownPro.app"
  exit 1
fi

sign() {
  codesign --force --options runtime --timestamp --sign "${IDENTITY}" "$@"
}

echo "==> Codesign helper"
HELPER="${APP_PATH}/Contents/Library/LaunchServices/com.cooldown.CoolDownPro.PrivilegedHelper"
if [[ ! -f "${HELPER}" ]]; then
  echo "error: privileged helper missing at ${HELPER}" >&2
  exit 1
fi
sign --entitlements "${ROOT}/Pro/Helper/CoolDownHelper.entitlements" "${HELPER}"

echo "==> Codesign CLI"
CLI="${APP_PATH}/Contents/MacOS/cooldown-smc"
if [[ -f "${CLI}" ]]; then
  sign "${CLI}"
fi

echo "==> Codesign frameworks"
find "${APP_PATH}/Contents/Frameworks" -name "*.framework" -maxdepth 1 2>/dev/null | while read -r fw; do
  sign "${fw}"
done

echo "==> Codesign app"
# Sign the bundle last, without --deep, so nested Mach-Os keep their own identity.
sign --entitlements "${ROOT}/Apps/CoolDownPro/CoolDownPro.entitlements" "${APP_PATH}"

echo "==> Verify signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
spctl --assess --type execute --verbose=4 "${APP_PATH}" || true

ZIP="${TMPDIR:-/tmp}/CoolDownPro-notarize.zip"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP}"

echo "==> Notarize (keychain profile: ${PROFILE})"
xcrun notarytool submit "${ZIP}" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${APP_PATH}"
echo "==> Done: ${APP_PATH}"
