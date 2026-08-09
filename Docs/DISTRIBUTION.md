# Distribution Guide — Cool Down Your Mac

## Products

| Product | Bundle ID | Channel |
|---------|-----------|---------|
| Cool Down Pro | `com.cooldown.CoolDownPro` | Website download + notarization |
| Cool Down (Store) | `com.cooldown.CoolDown` | Mac App Store (sandboxed, no fan writes) |

## Requirements

- macOS 14+
- Xcode 15+

## Prerequisites

1. Apple Developer Program membership
2. Certificates:
   - **Developer ID Application** (Pro)
   - **Mac App Distribution** / App Store Connect (Store)
3. Notary credentials stored as a keychain profile:

```bash
xcrun notarytool store-credentials cooldown-notary \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "app-specific-password"
```

4. Configure the trusted signing team in `Pro/Helper/HelperSecurity.swift`.

## Build Pro (Release)

```bash
./Packaging/scripts/build-release.sh Release
./Packaging/scripts/sign-notarize.sh dist/build/Build/Products/Release/CoolDownPro.app
./Packaging/scripts/make-dmg.sh dist/build/Build/Products/Release/CoolDownPro.app dist/CoolDownPro.dmg
```

## Updates

Cool Down Pro does not perform automatic update checks. Publish each notarized
release manually through GitHub Releases or your download page.

## Helper installation (Pro)

Pro installs its built-in privileged helper using `SMJobBless` after the user
authenticates with macOS:

- Helper label: `com.cooldown.CoolDownPro.PrivilegedHelper`
- Installed location: `/Library/PrivilegedHelperTools/`

The helper is code-signed and validates trusted callers before fan writes.

## App Store (Cool Down)

1. Open `CoolDownYourMac.xcodeproj`, select **CoolDownStore**.
2. Set your Development Team and unique bundle ID if needed.
3. Archive → Distribute App → App Store Connect.
4. App Review notes (suggested text):

> This app is a menu bar utility that displays macOS thermal pressure and lists hot processes. It does not read or write SMC fan keys, does not install privileged helpers, and does not modify hardware fan speeds. Users may quit processes they select to reduce load.

5. Privacy nutrition labels: no tracking; notifications optional; no account.

## Safety

- Pro restores system auto fans on quit when it had been overriding speeds.
- Smart curve uses hysteresis to avoid RPM oscillation.
- Helper rejects untrusted callers when Team ID is configured (set `COOLDOWN_HELPER_DEV=1` only for local debugging).
