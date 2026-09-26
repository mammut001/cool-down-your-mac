# Fan control safety audit

The properties this audit protects are listed, with their tests, in [FAN_SAFETY_INVARIANTS.md](FAN_SAFETY_INVARIANTS.md).

Baseline: `main` at `55ee7f8a0676212bd3a268424b0d7e671600b729` (Cool Down Pro 1.0.19). Review covers the app's sensor sampling and policy, XPC ownership, privileged helper, and AppleSMC writes. The lease and disconnect recovery paths were also tested on a signed M5 Pro build, as recorded below.

## Findings and changes for v1.0.20

| Priority | Baseline failure path | Change |
| --- | --- | --- |
| P0 | A live but stalled GUI kept its XPC connection and last manual SMC target indefinitely. | The helper owns a 45-second lease on manual commands. Fresh control ticks renew it without another SMC write. A helper timer restores system auto after expiry, including when the GUI remains connected. |
| P0 | An SMC read failure returned an unlimited-age cached snapshot. The app could use its old low temperature to renew a low manual target. | Failed SMC reads no longer return cached control data. Manual and Smart Curve return to system auto if no current CPU/GPU control temperature is available. |
| P1 | Each connection had an independent SMC queue. An old connection's asynchronous disconnect restore could execute after a new command. | All commands, disconnect restores, SIGTERM handling, and lease expiry share one helper queue. Only the connection that owns the current manual lease can trigger a disconnect restore or renew it. |
| P1 | A queued manual write could run after its client disconnect callback, reacquiring manual mode after auto restoration. | Each helper connection records invalidation on the shared queue and rejects later writes or renewals from that connection. The actual helper queue is tested with a disconnected client and a newer controlling client. |
| P1 | Failure on fan N could leave earlier fans in manual mode; an unsuccessful auto reset wrote minimum RPM. Successful I/O was not checked against the target and mode keys. | Partial manual writes attempt auto rollback. Failed restores remain pending for watchdog retries, with a maximum-RPM target attempted on any fan still stuck in manual mode. Fan mode and target writes require key read-back; target verification allows up to 900 ms for AppleSMC to publish the new value before rollback. |
| P2 | During a Smart Curve temperature outage, fans returned to auto but the UI kept showing the previous target percentage. | The unavailable-temperature path clears the target and load boost, resets curve state, and shows the auto-restoration notice. |
| P2 | Missing `FNum` threw before the per-fan discovery fallback. | Both fan count and writable fan discovery probe `F*Ac` when `FNum` is missing or zero. |
| P0 | An updated GUI could connect to an already-installed older helper that has no lease, then continue issuing manual commands. | Helper snapshots advertise lease support. Missing support decodes as false; the GUI blocks manual control, requests auto if an old helper reports manual fans, and exposes the explicit helper repair path. |

The 45-second lease exceeds the longest normal 25-second display-asleep polling interval (10-second UI setting multiplied by 2.5). A stalled helper queue or a process killed without a signal cannot run its watchdog. macOS firmware protection is independent, but this app cannot claim its own recovery in those cases.

The repository's macOS 15 / Xcode 16.4 CI could not compile the pre-existing macOS 26 Liquid Glass calls even behind a runtime availability check. The audit changes add a compiler-version guard so that CI builds the existing legacy appearance with the older SDK; Xcode 26 retains the Liquid Glass path.

## Signed Mac validation

On 2026-09-23, a signed Debug app and its bundled helper were tested on an M5 Pro with two fans. The installed helper was checked against the bundled binary. The first live attempt found that immediate `F0Tg` read-back rejected manual writes; bounded read-back retries resolved the failure on this machine. Both fans then entered manual mode at 50% and reached approximately 3350/3560 RPM. The final tests used the independent `cooldown-smc read` output:

| Test | Before fault | After fault | Result |
| --- | --- | --- | --- |
| T2: `kill -STOP` on the GUI PID, wait 50 s | Both fans `manual=true`, targets 3349/3563 RPM | Both `manual=false` while GUI was still stopped; helper logged lease expiry and auto restore | Pass |
| T3: `kill -9` on the GUI PID, wait 5 s | Both fans `manual=true`, targets 3349/3563 RPM | Both `manual=false`; helper logged controlling client gone and auto restore | Pass |

The later sleep and fault-injection work expanded the local test suite from 75 to 93 tests. Eight `SMCFaultInjectionTests` drive the real `SMCKit` path through a DEBUG-only fake AppleSMC transport, including missing `FNum`, failed mode and target writes, acknowledged-but-ignored writes, delayed read-back, failed auto restore, and repeated temperature read failures. Six `HelperServiceFaultTests` exercise the actual serialized helper queue with an injected SMC: late commands from disconnected clients, old/new connection ownership, lease expiry, restore retries, and SIGTERM restoration. Four `SMCConnectionRecoveryTests` cover open and I/O retry failures. All 93 tests passed locally. No failure was deliberately induced in the physical AppleSMC.

The first full system sleep/wake trial found a GUI crash in `IOHIDServiceClientCopyEvent` after wake. The HID bridge now stops sampling, releases cached client and service handles before sleep, and recreates them after wake, with teardown serialized against an in-flight read. A display-sleep cycle kept both fans manual. Subsequent full system sleep cycles of 11 and 54 seconds kept the GUI alive, but the 54-second trial exposed a second race: an in-flight control tick sent a manual command after the sleep handler had restored auto. The app now blocks policy writes while sleeping, invalidates the previous control generation, drains pending commands with an auto request on the same XPC connection, then disconnects until wake.

The final signed Debug retest entered full system sleep at 15:09:11 and woke at 15:14:04, a 293-second sleep according to `pmset -g log`. The helper logged `setFansAuto OK` at 15:09:06 and no further manual command until `setFansPercent 0.500000 OK` at 15:14:07, after wake. The same GUI PID remained alive, 32 live sensors returned, both fans reached their manual targets, and no new Cool Down Pro crash report appeared. The app was then returned to System Auto and both fans read `manual=false`.

The installed helper during the sleep retest was the previously validated lease-capable build. The connection-recovery extraction added in this follow-up was exercised by unit tests, not by a new privileged-helper installation.

The later live fault pass used a process-specific marker in the signed Debug app to suppress both direct SMC and HID telemetry while leaving physical fan control with the installed helper. In Manual and Smart Curve, both fans returned to `manual=false` within five seconds. Manual stayed auto beyond the 45-second lease, the UI showed zero live sensors and no current temperature, and restoring telemetry produced a fresh sample before Manual was applied again. This test also found and fixed Smart Curve's stale displayed target. With the sample interval raised from 2 to 10 seconds, Manual remained active beyond one lease period and through a 54-second display-sleep cycle; no extra authorization appeared. The original 2-second setting was restored. A normal GUI Quit while Manual was active returned both fans to auto.

The following matrix remains useful for release qualification, especially on Intel hardware. Test-only injection and helper queue tests are identified above; they are not claimed as physical AppleSMC fault passes.

Do not run failure injection during critical work or with the machine unattended. Capture the mode key, target RPM, and actual RPM for **each** fan with an independent read-only tool; merely observing the app's displayed target is insufficient. Test on the supported Apple Silicon machine first and on Intel hardware before asserting Intel support.

1. Build and run the unit suite. With two fans, change System Auto → Smart Curve → Manual → System Auto. Confirm both mode keys clear after Auto and both RPMs respond to Manual.
2. At a moderate temperature and a low manual setting, pause the GUI process without disconnecting its XPC connection. After 45–55 seconds, confirm both fans return to system auto. Resume the GUI and confirm a fresh sample is needed before another manual command.
3. While Manual is active, force-quit the GUI. Confirm auto restore; then rapidly reconnect/restart and verify that an old connection's invalidation cannot override the new command.
4. Inject a consecutive SMC temperature-read failure and remove HID CPU/GPU readings. Confirm Manual and Smart Curve request auto, do not renew a low manual lease, and do not show a stale temperature as current.
5. Inject a failure on the second fan's mode or target write. Confirm the first fan returns to auto. Inject an auto-restore failure, clear it, and confirm the helper retries restoration on the next watchdog tick.
6. Exercise display sleep, system sleep/wake, normal quit, helper SIGTERM, and an app poll interval of 10 seconds. Confirm no unintended low-speed hold or repeated authorization prompt.
7. On a model with no `FNum` key, confirm per-fan discovery works. Verify that a controller which acknowledges a key write without changing its read-back is treated as a failure.
8. Upgrade the GUI while leaving the pre-lease helper installed. Confirm manual controls remain disabled, any existing manual fan is returned to auto, and the Repair flow installs a lease-capable helper before manual control becomes available.

## Follow-up audit: sensor trust and hardware-state drift

A second review looked past process and connection failures at the data the policy trusts and at the gap between the fans' actual state and the app's belief. A read-only SMC probe on the M5 Pro supplied the key types and values cited below.

| Priority | Failure path | Change |
| --- | --- | --- |
| P1 | Every reading at or above 110 °C (SMC), 115 °C (catalog, control, alerts) or 120 °C (HID) was dropped as a glitch. The hottest die sensor disappeared first, so the control temperature fell as the chip heated; with all CPU values above the cap, a cool GPU sensor could keep Manual's 90/95 °C override and the Smart Curve emergency from engaging. User temperature alerts were capped the same way. | `TemperatureSanity` rejects only non-finite, ≤ 5 °C and ≥ 150 °C values. A reading of 110 °C or more is trusted when a different sensor reads at least 90 °C, which still rejects an isolated glitch. Control, the curated list, battery floor and alerts share the rule. |
| P1 | Lease renewal never reads the SMC. If firmware or another fan-control app (this Mac also runs Macs Fan Control's root `smcwrite` daemon) changed a fan's mode or target, the app kept renewing and showing its own target. At a stable 100 % emergency command it never wrote again. | Before renewing, the app compares each fan's published mode and target with the owned Manual/Smart Curve command and rewrites it on a mismatch, with a status message naming other fan-control apps. |
| P1 | Leases exist only in helper memory and the watchdog started with the first command. A helper that crashed or was killed while fans were manual was relaunched with no lease and no watchdog, leaving the last target in place until a GUI reconnected. | On launch, before the XPC listener resumes, the helper arms the watchdog and returns any manual fan to system auto; a failed restore stays pending for retries. |
| P1 | Manual's thermal override returned the battery floor as soon as it applied, so a 43 °C battery (50 %) masked a 96 °C chip (100 %). | The stronger of the battery and chip protections wins. |
| P2 | Manual's 90/95 °C override had no hysteresis. A temperature hovering at a threshold switched the fans between full speed and the user's setting on every poll, each switch costing a verified SMC write. | `ThermalOverrideLatch` exits 5 °C below each entry threshold and holds a level for at least 10 s; escalation is immediate. |
| P2 | XPC requests had no timeout. A helper stuck in IOKit never replied, `isTicking` stayed set, and polling, alerts and status updates stopped silently. | Requests fail after 10 s and drop the connection, so the next poll reconnects and the helper restores auto for that client once its queue recovers. |
| P2 | The menu-bar app did not opt out of App Nap. A timer deferred past 45 s would let the lease expire, cycling fans between auto and manual. This was not observed; helper info logs are not persisted. | While Manual or Smart Curve is selected, the app holds a `userInitiatedAllowingIdleSystemSleep` activity and logs any control tick delayed beyond 36 s. |
| P2 | On a Mac without `F*Md`/`F*md` keys (Intel), an auto restore treated the missing key as a failure, wrote each fan's maximum target and left the watchdog retrying every 5 s. Quit in the default Smart Curve mode reached this path. | Fans without a mode key are skipped by auto restore; an I/O failure while probing still attempts it. |
| P3 | `ioft` temperatures were decoded big-endian (for example `TG0B` read 2.25 × 10¹⁴ instead of 27.6 °C) and only the ceiling hid them. Their values match the battery `TB*T` keys, but the `TG` prefix would classify them as GPU. | Little-endian decoding; `ioft` readings are auxiliary: grouped as Other and excluded from CPU/GPU lists and control. |
| P3 | Stored sample interval and curve hysteresis were not clamped on decode. An interval above 18 s makes the 25 s display-asleep cadence exceed the 45 s lease. | Decoding and initialization clamp them to the settings ranges, 1–10 s and 0.5–5 °C. |
| P3 | An unreadable fan-mode key was reported as auto, so quit and old-helper recovery skipped that fan. | An existing but unreadable mode key reports manual, which only causes an extra auto request. |

Twenty-four new tests cover these paths and the invariants; the full suite of 117 tests passes. On 2026-09-26, the signed Debug helper from commit `72f1036` was installed on the M5 Pro and matched the bundled helper by SHA-256. With the GUI in Manual at 50% and a 2-second poll interval, Macs Fan Control changed fan 0's target from 3349 to 4500 RPM; an independent SMC read showed Cool Down Pro restore 3349 RPM within about one second. With both fans manual, the GUI was stopped and the root helper force-quit. After a launchd kickstart, both fans read `manual=false` while the GUI remained stopped. The GUI was resumed and quit normally, and both fans remained in system auto. This validates the two additional live cases; the other matrix steps were not repeated for this follow-up. Physical AppleSMC fault injection and Intel runtime behavior remain untested.

## Remaining limits

- Two fan-control apps cannot share the SMC. Cool Down Pro now reapplies its own Manual or Smart Curve command when another app changes it, and a relaunched helper returns manual fans to auto, which can override the other app. System Auto still issues one auto request when selected.

- Key read-back verifies the SMC mode and requested target, not the physical fan response. A hardware test must check actual RPM and account for spin-up delay.
- Restoration is best effort if the SMC rejects auto-mode writes. The helper attempts a maximum-RPM target for affected fans, retries auto while running, and logs failures; it cannot guarantee a hardware outcome after its process is forcibly killed.
- Faults injected through the test transport do not prove that every physical AppleSMC controller will behave identically. Intel hardware remains untested in this audit.
