# Distribution Guide — Cool Down Your Mac

## Products

| Product | Bundle ID | Channel |
|---------|-----------|---------|
| Cool Down Pro | `com.cooldown.CoolDownPro` | Website DMG + Notarization + Sparkle |
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

4. Replace placeholders:
   - `Pro/Helper/HelperSecurity.swift` → `allowedTeamIDs`
   - `Apps/CoolDownPro/Info.plist` → `SUFeedURL`, `SUPublicEDKey`
   - `Packaging/Sparkle/appcast-template.xml` → enclosure URL + edSignature

## Build Pro (Release)

```bash
./Packaging/scripts/build-release.sh Release
./Packaging/scripts/sign-notarize.sh dist/build/Build/Products/Release/CoolDownPro.app
./Packaging/scripts/make-dmg.sh dist/build/Build/Products/Release/CoolDownPro.app dist/CoolDownPro.dmg
```

## Sparkle

1. Add [Sparkle 2](https://github.com/sparkle-project/Sparkle) via SPM to the CoolDownPro target.
2. Generate keys: `./bin/generate_keys`
3. Put public key in `SUPublicEDKey`.
4. Sign the DMG/zip: `./bin/sign_update CoolDownPro.dmg`
5. Publish `appcast.xml` and the DMG on HTTPS.

Optional Sparkle wiring (after adding the package):

```swift
import Sparkle
// In AppDelegate:
let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
```

## Helper installation (Pro)

Pro uses `SMAppService` (`macOS 13+`) with:

- Helper binary: `Contents/MacOS/com.cooldown.CoolDownPro.Helper`
- LaunchDaemon plist: `Contents/Library/LaunchDaemons/com.cooldown.CoolDownPro.Helper.plist`

Users approve the daemon under **System Settings → General → Login Items & Extensions**.

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
