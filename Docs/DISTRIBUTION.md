# Distribution Guide — Cool Down Pro

## Product

| Product | Bundle ID | Channel |
|---------|-----------|---------|
| Cool Down Pro | `com.cooldown.CoolDownPro` | Website / GitHub download + notarization |

Current project versioning is defined in `project.yml` (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`). Update those values before cutting a release.

## Requirements

- macOS 14+
- Xcode 15+
- XcodeGen
- Apple Developer Program membership
- A **Developer ID Application** certificate installed in Keychain

## One-time notarization setup

Store App Store Connect notarization credentials as a keychain profile:

```bash
xcrun notarytool store-credentials cooldown-notary \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "app-specific-password"
```

The release scripts default to profile `cooldown-notary`. Override with:

```bash
export NOTARY_PROFILE=another-profile
```

If your Developer ID identity differs from the project default, set:

```bash
export CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

Also verify the trusted signing team in `Pro/Helper/HelperSecurity.swift` before distribution.

## Recommended release flow

Run the complete pipeline from the repository root:

```bash
bash Packaging/scripts/release.sh Release
```

That performs, in order:

1. XcodeGen project generation and Release build.
2. Explicit signing of the privileged helper, CLI, frameworks, and app bundle.
3. App notarization + stapling.
4. Drag-to-Applications DMG creation.
5. DMG notarization + stapling.
6. Signature / Gatekeeper / stapler / DMG verification.
7. SHA-256 generation for the final DMG.

Expected artifacts:

```text
dist/CoolDownPro.dmg
dist/CoolDownPro.dmg.sha256
```

## Manual flow

The individual steps remain available for debugging:

```bash
bash Packaging/scripts/build-release.sh Release
bash Packaging/scripts/sign-notarize.sh dist/build/Build/Products/Release/CoolDownPro.app
bash Packaging/scripts/make-dmg.sh dist/build/Build/Products/Release/CoolDownPro.app dist/CoolDownPro.dmg
xcrun notarytool submit dist/CoolDownPro.dmg --keychain-profile cooldown-notary --wait
xcrun stapler staple dist/CoolDownPro.dmg
bash Packaging/scripts/verify-release.sh \
  dist/build/Build/Products/Release/CoolDownPro.app \
  dist/CoolDownPro.dmg
shasum -a 256 dist/CoolDownPro.dmg
```

## Pre-release checklist

Before publishing a GitHub Release:

- [ ] Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
- [ ] Generate the Xcode project and confirm the release build succeeds.
- [ ] Run the unit tests for `CoolDownProTests`.
- [ ] Run `bash Packaging/scripts/release.sh Release` on a Mac with the distribution identity and notarization profile configured.
- [ ] Confirm `verify-release.sh` passes without bypassing Gatekeeper checks.
- [ ] Test the DMG on a second / clean macOS user or machine if available.
- [ ] Confirm the privileged helper installs, fan control works, and quitting restores automatic fan control.
- [ ] Attach `CoolDownPro.dmg` and `CoolDownPro.dmg.sha256` to the GitHub Release.
- [ ] Include the SHA-256 value in the release notes.
- [ ] Add a short changelog and known-issues section.

## Release notes template

```markdown
## Cool Down Pro vX.Y.Z

### Highlights
- ...

### Fixes
- ...

### Requirements
- macOS 14+
- Apple Silicon / supported Intel Macs as validated by the project

### Verification
SHA-256 (`CoolDownPro.dmg`):
`<paste checksum>`

### Install
1. Download `CoolDownPro.dmg`.
2. Open it and drag **CoolDownPro** to **Applications**.
3. Launch the app and approve the privileged helper prompt when you first enable fan control.
```

## Updates

Cool Down Pro does not currently perform automatic update checks. Publish each notarized release manually through GitHub Releases or your download page.

## Helper installation

Cool Down Pro installs its built-in privileged helper using `SMJobBless` after the user authenticates with macOS:

- Helper label: `com.cooldown.CoolDownPro.PrivilegedHelper`
- Installed location: `/Library/PrivilegedHelperTools/`

The helper is code-signed and validates trusted callers before fan writes.
Release builds enforce Team ID `Z5D5N7CU6L` + bundle ID `com.cooldown.CoolDownPro`.
Debug builds may set `COOLDOWN_HELPER_DEV=1` to relax the check.

## Safety

- Restores system auto fans on quit (with a synchronous fast-path so the fan does not stay pinned if the app is killed).
- Smart Curve uses hysteresis, asymmetric EWMA temperature filtering, a 10-second cooldown hold, and gradual fan decrease to avoid RPM oscillation.
- Safety floors:
  - `≥ 80°C`: immediate minimum 85% fan target
  - `≥ 85°C`: immediate minimum 95% fan target
  - `≥ 90°C`: immediate 100% fan target
- The helper rejects untrusted callers. All XPC fan writes are validated and logged via `os_log`.
- Intel compatibility: builds universal `arm64` + `x86_64` binaries with optimized polling cadences; full Intel runtime performance remains pending dedicated Intel hardware validation.
