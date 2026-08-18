# Cool Down Pro

**Smart thermal fan control for macOS without the constant ramp-up / ramp-down cycle.**

Cool Down Pro is a native macOS menu bar utility that combines Apple SMC fan control with filtered thermal signals and a smarter control curve. Instead of reacting to every short temperature spike, it uses hysteresis, asymmetric EWMA filtering, cooldown hold, and hot/emergency bypass logic to stay responsive without causing constant fan-speed oscillation.

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
- **Hardened runtime + release packaging** for a real distributable macOS app

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

## Package a release

```bash
./Packaging/scripts/build-release.sh
```

Distribution and notarization notes live in [`Docs/DISTRIBUTION.md`](Docs/DISTRIBUTION.md).

## Project focus

This repository is intentionally focused on **stable thermal control**, not simply exposing a manual fan slider. The interesting part is the feedback controller: sensor selection, smoothing, hysteresis, cooldown behavior, safety bypasses, and the privileged macOS boundary required to apply fan targets.

## License

Licensed under the [GNU General Public License v2.0 only](LICENSE).
