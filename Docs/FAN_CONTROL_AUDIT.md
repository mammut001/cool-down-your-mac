# Fan control safety audit

Baseline: `main` at `55ee7f8a0676212bd3a268424b0d7e671600b729` (Cool Down Pro 1.0.19). This is a source audit of the fan-control path, not a claim of hardware validation. Review covers the app's sensor sampling and policy, XPC ownership, privileged helper, and AppleSMC writes.

## Findings and changes in this PR

| Priority | Baseline failure path | Change |
| --- | --- | --- |
| P0 | A live but stalled GUI kept its XPC connection and last manual SMC target indefinitely. | The helper owns a 45-second lease on manual commands. Fresh control ticks renew it without another SMC write. A helper timer restores system auto after expiry, including when the GUI remains connected. |
| P0 | An SMC read failure returned an unlimited-age cached snapshot. The app could use its old low temperature to renew a low manual target. | Failed SMC reads no longer return cached control data. Manual and Smart Curve return to system auto if no current CPU/GPU control temperature is available. |
| P1 | Each connection had an independent SMC queue. An old connection's asynchronous disconnect restore could execute after a new command. | All commands, disconnect restores, SIGTERM handling, and lease expiry share one helper queue. Only the connection that owns the current manual lease can trigger a disconnect restore or renew it. |
| P1 | Failure on fan N could leave earlier fans in manual mode; an unsuccessful auto reset wrote minimum RPM. Successful I/O was not checked against the target and mode keys. | Partial manual writes attempt auto rollback. Failed restores remain pending for watchdog retries, with a maximum-RPM target attempted on any fan still stuck in manual mode. Fan mode and target writes require immediate key read-back; failure triggers rollback. |
| P2 | Missing `FNum` threw before the per-fan discovery fallback. | Both fan count and writable fan discovery probe `F*Ac` when `FNum` is missing or zero. |

The 45-second lease exceeds the longest normal 25-second display-asleep polling interval (10-second UI setting multiplied by 2.5). A stalled helper queue or a process killed without a signal cannot run its watchdog. macOS firmware protection is independent, but this app cannot claim its own recovery in those cases.

The repository's macOS 15 / Xcode 16.4 CI could not compile the pre-existing macOS 26 Liquid Glass calls even behind a runtime availability check. This PR also adds a compiler-version guard so that CI builds the existing legacy appearance with the older SDK; Xcode 26 retains the Liquid Glass path.

## Validation required on a signed Mac build

Do not run failure injection during critical work or with the machine unattended. Capture the mode key, target RPM, and actual RPM for **each** fan with an independent read-only tool; merely observing the app's displayed target is insufficient. Test on the supported Apple Silicon machine first and on Intel hardware before asserting Intel support.

1. Build and run the unit suite. With two fans, change System Auto → Smart Curve → Manual → System Auto. Confirm both mode keys clear after Auto and both RPMs respond to Manual.
2. At a moderate temperature and a low manual setting, pause the GUI process without disconnecting its XPC connection. After 45–55 seconds, confirm both fans return to system auto. Resume the GUI and confirm a fresh sample is needed before another manual command.
3. While Manual is active, force-quit the GUI. Confirm auto restore; then rapidly reconnect/restart and verify that an old connection's invalidation cannot override the new command.
4. Inject a consecutive SMC temperature-read failure and remove HID CPU/GPU readings. Confirm Manual and Smart Curve request auto, do not renew a low manual lease, and do not show a stale temperature as current.
5. Inject a failure on the second fan's mode or target write. Confirm the first fan returns to auto. Inject an auto-restore failure, clear it, and confirm the helper retries restoration on the next watchdog tick.
6. Exercise display sleep, system sleep/wake, normal quit, helper SIGTERM, and an app poll interval of 10 seconds. Confirm no unintended low-speed hold or repeated authorization prompt.
7. On a model with no `FNum` key, confirm per-fan discovery works. Verify that a controller which acknowledges a key write without changing its read-back is treated as a failure.

## Remaining limits

- Key read-back verifies the SMC mode and requested target, not the physical fan response. A hardware test must check actual RPM and account for spin-up delay.
- Restoration is best effort if the SMC rejects auto-mode writes. The helper attempts a maximum-RPM target for affected fans, retries auto while running, and logs failures; it cannot guarantee a hardware outcome after its process is forcibly killed.
- The build and unit tests must pass on macOS. This audit was prepared in a Linux environment without AppleSMC or Xcode; the PR remains Draft until a signed Mac build and the failure tests above pass.
