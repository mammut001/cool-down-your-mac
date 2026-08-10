# Distribution Guide — Cool Down Pro

## Product

| Product | Bundle ID | Channel |
|---------|-----------|---------|
| Cool Down Pro | `com.cooldown.CoolDownPro` | Website download + notarization |

## Requirements

- macOS 14+
- Xcode 15+

## Prerequisites

1. Apple Developer Program membership
2. Certificate: **Developer ID Application**
3. Notary credentials stored as a keychain profile:

```bash
xcrun notarytool store-credentials cooldown-notary \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "app-specific-password"
```

4. Configure the trusted signing team in `Pro/Helper/HelperSecurity.swift`.

## Build (Release)

```bash
./Packaging/scripts/build-release.sh Release
./Packaging/scripts/sign-notarize.sh dist/build/Build/Products/Release/CoolDownPro.app
./Packaging/scripts/make-dmg.sh dist/build/Build/Products/Release/CoolDownPro.app dist/CoolDownPro.dmg
```

## Updates

Cool Down Pro does not perform automatic update checks. Publish each notarized
release manually through GitHub Releases or your download page.

## Helper installation

Cool Down Pro installs its built-in privileged helper using `SMJobBless` after the user
authenticates with macOS:

- Helper label: `com.cooldown.CoolDownPro.PrivilegedHelper`
- Installed location: `/Library/PrivilegedHelperTools/`

The helper is code-signed and validates trusted callers before fan writes.
Release builds enforce Team ID `Z5D5N7CU6L` + bundle ID `com.cooldown.CoolDownPro`.
Debug builds may set `COOLDOWN_HELPER_DEV=1` to relax the check.

## Safety

- Restores system auto fans on quit (with a synchronous fast-path so the fan does not stay pinned if the app is killed).
- Smart curve uses hysteresis, EWMA filtering, and a 10s cooldown hold to avoid RPM oscillation. 88°C forces ≥85% and 92°C forces 100%.
- Helper rejects untrusted callers. All XPC fan writes are validated and logged via `os_log`.
