# Cool Down Pro

**Smart thermal fan control for macOS without the constant ramp-up / ramp-down cycle.**

[![Latest Release](https://img.shields.io/github/v/release/mammut001/cool-down-your-mac?label=latest)](https://github.com/mammut001/cool-down-your-mac/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://github.com/mammut001/cool-down-your-mac/releases/latest)
[![License GPL-2.0](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)

### [⬇️ Download the latest notarized DMG](https://github.com/mammut001/cool-down-your-mac/releases/latest/download/CoolDownPro.dmg)

Cool Down Pro is a native macOS menu bar utility that combines Apple SMC fan control with filtered thermal signals and a smarter control curve. Instead of reacting to every short temperature spike, it uses hysteresis, asymmetric EWMA filtering, cooldown hold, and hot/emergency bypass logic to stay responsive without causing constant fan-speed oscillation.

[**Release notes**](https://github.com/mammut001/cool-down-your-mac/releases/latest) · [Distribution guide](Docs/DISTRIBUTION.md) · [License](LICENSE)

![Cool Down Pro overview](Docs/images/cool-down-pro-overview.jpg)

## Why this project exists

Most simple fan curves map the current temperature directly to a fan percentage. On a real Mac, temperatures move quickly under bursty workloads, so the result can be an annoying loop:

```text
load rises → temperature rises → fan jumps → temperature drops → fan falls → repeat
```

Cool Down Pro adds state and filtering around that feedback loop so short spikes do not immediately become audible fan changes, while genuinely hot conditions can still bypass the smoothing path.

## Highlights

- **Native SMC fan control** through a privileged helper using `SMJobBless` + XPC
- **Smart Curve engine** with hysteresis, asymmetric EWMA filtering, cooldown hold, and hot/emergency bypass
- **HID + SMC sensor fusion** with curated CPU, GPU, Battery, Storage, and Other sensor groups
- **Menu bar workflow** designed for quick status checks and fan-curve adjustments
- **Hardened runtime + notarized DMG pipeline** for website / GitHub distribution

## Smart Fan Curve

![Cool Down Pro smart fan curve](Docs/images/cool-down-pro-fan-curve.jpg)

The controller separates fast “getting hot” behavior from slower “cooling down” behavior. That asymmetry is intentional: it can respond quickly when thermals deteriorate, but it does not immediately drop the fans after a brief recovery.

## Architecture

```text
┌─────────────────────┐
│   CoolDownPro.app   │
│  menu bar + sensors │
└─────────┬───────────┘
          │ XPC
          ▼
┌─────────────────────┐
│ Privileged Helper   │
│    SMJobBless       │
└─────────┬───────────┘
          │ IOKit / AppleSMC
          ▼
┌─────────────────────┐
│  Mac thermal / fan  │
│      hardware       │
└─────────────────────┘

Sensor stream → SmartCurveEngine → target fan % → privileged helper
```

## Requirements

- macOS 14+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Install XcodeGen with Homebrew:

```bash
brew install xcodegen
```

## Build

```bash
xcodegen generate
open CoolDownYourMac.xcodeproj
```

Or build from the command line:

```bash
xcodebuild \
  -project CoolDownYourMac.xcodeproj \
  -scheme CoolDownPro \
  -configuration Debug \
  build
```

## Build a distributable release

On a Mac configured with a Developer ID Application identity and a `notarytool` keychain profile:

```bash
bash Packaging/scripts/release.sh Release
```

The release pipeline builds, signs, notarizes, creates and notarizes the DMG, verifies Gatekeeper / stapler state, and writes a SHA-256 checksum.

Expected output:

```text
dist/CoolDownPro.dmg
dist/CoolDownPro.dmg.sha256
```

See [`Docs/DISTRIBUTION.md`](Docs/DISTRIBUTION.md) for prerequisites and the complete release checklist.

## Project focus

This repository is intentionally focused on **stable thermal control**, not simply exposing a manual fan slider. The interesting part is the feedback controller: sensor selection, smoothing, hysteresis, cooldown behavior, safety bypasses, and the privileged macOS boundary required to apply fan targets.

## License

Licensed under the [GNU General Public License v2.0 only](LICENSE).