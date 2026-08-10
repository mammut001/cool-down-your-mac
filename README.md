# Cool Down Pro

macOS menu bar utility with smart thermal fan control.

- **SMC fan control** via privileged helper (`SMJobBless` + XPC), hardened runtime, notarized DMG
- **Smart Curve** — hysteresis, asymmetric EWMA filtering, cooldown hold, and hot/emergency bypass
- **HID + SMC sensor fusion** — curated CPU/GPU/Battery/Storage/Other views

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
```

Release packaging:

```bash
./Packaging/scripts/build-release.sh
```

See [Docs/DISTRIBUTION.md](Docs/DISTRIBUTION.md) for notarization steps.

## Screenshots

### Overview

![Cool Down Pro overview](Docs/images/cool-down-pro-overview.jpg)

### Smart Fan Curve

![Cool Down Pro smart fan curve](Docs/images/cool-down-pro-fan-curve.jpg)

## Architecture

```
CoolDownPro.app  --XPC-->  Privileged Helper  --IOKit-->  AppleSMC
                     SmartCurveEngine (temp → fan %)
```

## License

This project is licensed under the [GNU General Public License v2.0 only](LICENSE).
