# Cool Down Pro v1.0.21 (build 32)

## Fan control safety

- Trust corroborated high CPU/GPU temperatures instead of dropping the hottest readings as glitches. Manual mode now applies the stronger of battery and chip safety overrides.
- Detect when firmware or another fan-control app changes a fan's mode or target, then reapply Cool Down Pro's selected command on the next poll.
- Restore system automatic fan control when the privileged helper starts after a crash or force quit, even while the GUI is stopped.
- Add hysteresis to the Manual thermal override, time out stalled helper replies, and keep active fan control awake during App Nap.
- Correct auxiliary SMC temperature decoding, clamp stored settings, and improve restoration on Macs without fan-mode keys.

See the [fan control safety audit](https://github.com/mammut001/cool-down-your-mac/blob/v1.0.21/Docs/FAN_CONTROL_AUDIT.md) for the findings and limits.

## Verification

- 117 unit tests passed locally and the PR's Build & Test CI passed.
- On an M5 Pro with two fans and the new helper installed, an external 4500 RPM target was replaced by the app's 3349 RPM Manual target within about one second. With the GUI stopped, force-quitting and relaunching the helper returned both fans to system automatic mode.
- Intel runtime behavior and deliberately induced faults in a physical AppleSMC remain untested. Two fan-control apps can override each other's targets.

**DMG SHA-256:** `afea18078a49fe5b4c24e977774b556cdfec5bddc90a56bb41e846b79b3f87ee`

## Install

1. Download `CoolDownPro.dmg` and drag **CoolDownPro** to **Applications**.
2. Launch the app. Existing installations may need **Settings → General → Repair Fan Control** to install the updated helper.

Requires macOS 14 or later. Universal Apple Silicon and Intel binaries are included.
