# Cool Down Your Mac

Dual-product macOS menu bar utilities:

- **Cool Down Pro** — independent distribution with SMC fan control, privileged helper, smart curves, notarized DMG + Sparkle
- **Cool Down** — Mac App Store edition that monitors thermal pressure and helps quit hot processes (no fan writes)

## Requirements

- macOS 14+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Generate & build

```bash
xcodegen generate
open CoolDownYourMac.xcodeproj

# or
xcodebuild -project CoolDownYourMac.xcodeproj -scheme CoolDownPro -configuration Debug build
xcodebuild -project CoolDownYourMac.xcodeproj -scheme CoolDownStore -configuration Debug build
```

Release packaging:

```bash
./Packaging/scripts/build-release.sh
```

See [Docs/DISTRIBUTION.md](Docs/DISTRIBUTION.md) for notarization, Sparkle, and App Store steps.

## Architecture (Pro)

```
CoolDownPro.app  --XPC-->  Privileged Helper  --IOKit-->  AppleSMC
                     SmartCurveEngine (temp → fan %)
```

## License

Add your license before shipping.
