# Cool Down Pro v1.0.20 (build 31)

## Fan control safety

- A 45-second helper lease returns fans to macOS automatic control when the app stalls, even if its XPC connection remains open. A disconnected client can no longer issue queued manual writes after restoration.
- Failed or stale temperature readings no longer sustain Manual or Smart Curve control. Both modes request System Auto when no current CPU/GPU control temperature is available.
- Partial fan writes attempt rollback; failed restores remain queued for watchdog retry. SMC mode and target writes now require read-back, allowing time for the controller to publish a new target.
- The app checks that the installed privileged helper supports the lease before allowing manual control. Its Repair action installs the matching helper when an older one is found.
- Sleep and wake handling now stops HID sampling safely, restores automatic fan control before sleep, and resumes control only after a fresh post-wake sample.

See the [fan control safety audit](https://github.com/mammut001/cool-down-your-mac/blob/v1.0.20/Docs/FAN_CONTROL_AUDIT.md) for the findings, test matrix, and remaining limits.

## Verification

- 93 unit tests passed, including injected SMC and helper-queue fault cases. CI passed on the release candidate.
- On an M5 Pro with two fans, live pause and force-quit tests restored both fans to automatic control. A 293-second full system sleep/wake test restored auto before sleep and resumed only after wake. UI fault injection returned Manual and Smart Curve to auto within five seconds.
- Intel runtime behavior and deliberately induced faults in a physical AppleSMC were not tested in this audit.

<!-- The release pipeline inserts the verified DMG SHA-256 before publishing. -->

## Install

1. Download `CoolDownPro.dmg` and drag **CoolDownPro** to **Applications**.
2. Launch the app and approve the privileged helper prompt when first enabling fan control. Existing installations may need to use **Settings → General → Repair** to install the updated helper.

Requires macOS 14 or later. Universal Apple Silicon and Intel binaries are included.
