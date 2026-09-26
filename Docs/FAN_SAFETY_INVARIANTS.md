# Fan safety invariants

These are the properties Cool Down Pro must hold on every path, including failures. A future audit should check each row rather than start from scratch: a finding either violates a row, or it shows a missing row, which should be added here with its test.

The design goal behind all of them: any failure ends with the fans under system control, and the app never believes a state the hardware does not have. Independently of this app, Apple Silicon and Intel firmware throttle and ultimately shut down an overheating chip; the realistic worst case of a remaining bug is heat, noise or lost performance, not hardware damage. The rows below keep it there.

| ID | Invariant | Enforced in | Tests |
| --- | --- | --- | --- |
| I1 | The app writes only fan mode (`F*Md`, `F*md`) and fan target (`F*Tg`) SMC keys. | `SMCKit` is the only SMC writer. | `FanSafetyInvariantTests.testI1…` |
| I2 | A manual target stays within the fan's reported minimum and maximum; the fan is never stopped. The helper rejects non-finite or out-of-range requests before any write. | `SMCKit.setFanRPM` clamp; `HelperService` argument guards. | `FanSafetyInvariantTests.testI2…` |
| I3 | Without a fresh CPU/GPU temperature, Manual and Smart Curve return the fans to system auto. A failed read never yields a cached temperature. | `DirectSMCReader`, `ProAppModel.applyControlPolicy`. | `SMCFaultInjectionTests.testTemperatureReadFailuresNeverReturnLastGoodSample`; app policy: live fault pass in `FAN_CONTROL_AUDIT.md`. |
| I4 | The hottest trusted sensor always reaches control and alerts. Only impossible values and isolated glitches above 110 °C are discarded. Auxiliary (`ioft`) sensors never count as CPU/GPU. | `TemperatureSanity`, `SensorCatalog.controlReadings`. | `TemperatureTrustTests`, `SMCDeeperFaultTests.testHotTemperatureIsNotDiscardedAtSource`, `…FixedPoint…` |
| I5 | Safety logic only raises fan speed: curves are non-decreasing, Smart Curve floors and emergency apply above 80/85/90 °C, and Manual takes the strongest of the user setting, battery floor and chip override. | `CurveProfile.normalized`, `SmartCurveEngine`, `ThermalOverrideLatch`, `ProAppModel.thermalSafetyOverridePercent`. | `CurveProfileTests`, `SmartCurveEngineTests`, `ThermalOverrideLatchTests` |
| I6 | No fan stays manual without a live lease: lease expiry, owner disconnect, SIGTERM and helper relaunch all restore auto; a stale or disconnected client cannot override the owner. | `HelperService` shared queue, lease, watchdog, `reconcileAfterLaunch`. | `HelperServiceFaultTests`, `FanControlLeaseTests`, `SMCDeeperFaultTests.testHelperLaunch…` |
| I7 | A failed auto restore never leaves a low manual target: affected fans get their maximum target and the watchdog retries. Fans with no mode key need no restore. | `SMCKit.setAllFansAuto`, `HelperService.restorePending`. | `SMCFaultInjectionTests.testFailedAutoRestore…`, `HelperServiceFaultTests.testFailedAutoRestoreIsRetriedByWatchdog`, `SMCDeeperFaultTests.testAutoRestoreWithoutModeKeysIsANoOp` |
| I8 | A write counts only after read-back confirms it; a partial or unconfirmed write rolls every fan back to auto. | `SMCKit.setFanManual`, `setFanRPM`, `setAllFansPercent`. | `SMCFaultInjectionTests` (ignored write, delayed and failed read-back, second-fan failures) |
| I9 | The app's belief matches the hardware: an owned command whose mode or target changed is rewritten, and an unreadable mode is treated as manual. | `ProAppModel.applyFanWrite`, `FanCommandVerification`, `SMCKit.readFans`. | `FanCommandVerificationTests`, `SMCDeeperFaultTests.testUnreadableModeIsReportedAsManual` |
| I10 | A stalled component cannot freeze control silently: helper replies time out, the GUI's lease expires if it stalls, and App Nap cannot defer a tick past the lease. | `awaitReply`, lease duration, `ProAppModel.updateControlActivity`, settings clamps. | `ReplyTimeoutTests`, `SettingsBoundsTests`, lease tests |

## Known gaps

- `ProAppModel` is not in the unit-test target. Its wiring for I3, the Manual combination in I5 and the drift rewrite in I9 is verified by review and the live passes, not by unit tests. Extracting the policy decision into a pure function would close this.
- Unit tests use a fake AppleSMC. Physical behavior needs the hardware matrix in `FAN_CONTROL_AUDIT.md`, repeated on Intel before claiming Intel support.
- A helper killed without a signal, or blocked inside IOKit, cannot act until it runs again; I6 then depends on its relaunch.
