# Cool Down Pro v1.0.22 (build 33)

## Fan control safety

- The privileged helper now grants manual fan control only to an app that will keep its 45-second safety lease alive. Apps older than 1.0.20 are refused and the fans stay under macOS automatic control, instead of cycling between automatic and manual every 45 seconds. A connection whose lease expires while it stays open is refused until it reconnects; the app reconnects on its own and rewrites the current target on the next poll.
- This closes the case found on an M5 Pro where a 1.0.18 app running against a newer helper made the fans stop for a few seconds at moderate temperatures and then resume.

## Updates

- Scheduled update checks are now visible. As a menu-bar app, Cool Down Pro previously received Sparkle's update alert behind other windows, so daily checks could succeed for weeks without anyone seeing the update. A pending update now shows an **Install…** row in the menu-bar popover and in Settings → Updates, and a notification when notifications are already allowed. Either one opens the update in front.

See the [fan control safety audit](https://github.com/mammut001/cool-down-your-mac/blob/v1.0.22/Docs/FAN_CONTROL_AUDIT.md) for the findings and limits, including the new invariant I11.

## Verification

- 121 unit tests passed locally and the PR's Build & Test CI passed.
- On an M5 Pro with two fans, the 1.0.21 app against the lease-capable helper held manual control across 56-second and 50-second gaps between writes with no lease expiry. The refusal paths of the new helper were exercised through the fault-injection test transport, not on a physical AppleSMC.
- Intel runtime behavior remains untested. Two fan-control apps can still override each other's targets.

**DMG SHA-256:** `a011df8663198a3489e12f5f86f292fa5145fc8c5ecdab05f861b3a69af7e4c3`

## Install

1. Download `CoolDownPro.dmg` and drag **CoolDownPro** to **Applications**, or accept the in-app update.
2. Launch the app, then use **Settings → General → Repair Fan Control** once so the updated helper is installed. macOS asks for an administrator password.

Requires macOS 14 or later. Universal Apple Silicon and Intel binaries are included.
