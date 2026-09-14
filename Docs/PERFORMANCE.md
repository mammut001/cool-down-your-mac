# Telemetry optimization on top of 1.0.14

Measured locally on 2026-09-14, Apple M5 Pro, macOS 26.5.1. Baseline source:
`v1.0.14` (`bf7d6b9`). No fan writes are performed by the benchmark.

## Changes

- Normal sampling reads all CPU/GPU temperature keys plus the auxiliary keys used
  by the curated display. Previously it read every discovered temperature key,
  then discarded most of them. The full sensor view still reads every key.
- CPU/GPU hotspots beyond the display's core/cluster limit remain in the control
  input. HID sampling, sampling interval, curve behavior and safety thresholds
  are unchanged. Timer tolerance is capped at 200 ms to permit wakeup coalescing.
- Cache SMC type/size metadata and sensor names, but never live fan values or
  modes. Failed reads evict metadata; connection invalidation clears the cache.
- Cache empty discovery results for 8 seconds to avoid repeated scans on systems
  without exposed fans/sensors. Positive discovery refresh periods are unchanged.
- Suppress unchanged helper-ready/initial-probe/status publications in the healthy
  polling path.
- Keep one lazily owned app model without forwarding telemetry to the Scene.
  Batch each polling transaction into one dedicated telemetry notification and
  update only mounted live content; hidden UI does not receive polling updates.
- Replace sensor SwiftUI rows with a cell-based NSTableView. Reload only changed
  visible rows, retaining search, grouping, full raw sensors and accessibility.
  Cache cell fonts and make unchanged header/metric views equatable.
- Use static native-color cards in the overview instead of live glass surfaces.
  The curve editor and menu retain their existing styling and scoped live updates.
- Break case-insensitive SMC sort ties by exact key. This prevents dictionary
  iteration from changing displayed GPU selections and causing structural reloads.
  The spot checks below preceded this final deterministic-order correction.

## Whole-process spot checks after native UI changes

Both apps were already running on the same Mac. Each pair uses a shared 30-second
interval with `proc_pid_rusage`; CPU is percent of one core (100% = one core).
These are app-process counters, not total system energy or helper-inclusive CPU.
CoolDown used System Auto, a 2-second interval, curated display and alerts enabled;
both apps had menu-bar temperature text disabled for this comparison. Macs Fan
Control 1.5.21 used its existing System Auto preset. Sensor sets/features differ.

| Window state / run | CoolDown CPU | MFC CPU | CoolDown footprint MiB | MFC footprint MiB |
| --- | ---: | ---: | ---: | ---: |
| Both dashboards open, first | 0.464% | 0.205% | 68.5 | 66.3 |
| Both dashboards open, repeat | 0.524% | 0.279% | 68.4 | 66.4 |
| CoolDown hidden / MFC hidden to menu bar | 0.222% | 0.038% | 70.7 | 67.3 |

The open-window repeat involved no UI interaction during the sample; the first
included a CoolDown accessibility/screenshot check. Focus and window occlusion
were not rigorously equalized. No builds ran during these samples, but other
user applications were active. Hidden-mode interrupt wakeups were 0.53/s versus
1.47/s; this does not imply lower total energy. Memory includes retained UI state.
The installed root helper was not replaced and its counters were inaccessible.
These results show **remaining CPU disparity**, not parity with Macs Fan Control.
Smart Curve plus visible menu temperature is a different workload, not represented
by these numbers. Those original user settings were restored after comparison.

The final signed artifact was then launched with `--background`, Smart Curve,
menu temperature enabled, alerts enabled and 2-second sampling. A 30-second
sample measured 0.269% CPU, 17.6 MiB footprint and 1.20 interrupt wakeups/s.
MFC remained hidden in System Auto (0.034%, 67.2 MiB, 1.33/s). This is deliberately
reported separately: control modes differ, and CoolDown had never opened a
dashboard in this process while MFC retained its previously opened UI. It is
not a like-for-like memory or CPU comparison. Persisted settings were verified.

Final signed local artifact: `dist/performance-native-1.0.14/CoolDownPro.app`.
The older `dist/performance-1.0.14` artifact does not include the native UI round.

Compile the read-only paired process sampler and pass current app PIDs:

```sh
xcrun clang -O2 Tools/TelemetryBenchmark/process.c -o /tmp/cooldown-process-benchmark
/tmp/cooldown-process-benchmark 30 <cooldown-pid> <mfc-pid>
```

For cold background-only trials, the development app accepts `--background` to
skip dashboard opening. This does not disable polling, alerts or fan control.

## Measurements

Each run warms up once, then performs 200 back-to-back SMC + HID samples with
Swift `-O`. CPU time includes user and system time charged to the benchmark
process; wall time includes waits for I/O. This is a sampling microbenchmark,
not Activity Monitor CPU usage or a whole-application energy measurement.

| Run | Valid SMC temperatures | HID temperatures | CPU ms/sample | Wall ms/sample |
| --- | ---: | ---: | ---: | ---: |
| Original 1.0.14, first run | 256 | 17 | 6.246 | 98.246 |
| Optimized normal, first run | 75 | 17 | 2.622 | 51.298 |
| Original 1.0.14, repeat | 256 | 17 | 5.038 | 84.106 |
| Optimized normal, repeat | 75 | 17 | 2.461 | 49.957 |
| Optimized all sensors | 256 | 17 | 5.220 | 88.058 |

Both fans remained readable. Normal-mode CPU time fell 51–58%; full-mode time
was comparable to baseline. Other applications/builds were active on this Mac,
so these are indicative local measurements rather than controlled lab results.
No claim of matching Macs Fan Control's total CPU, memory or energy usage is made.

## Reproduce the optimized benchmark

Run from the repository root:

```sh
BENCH_DIR=$(mktemp -d /tmp/cooldown-benchmark.XXXXXX)
xcrun clang -O2 -fobjc-arc -fblocks -c Pro/Sensors/IOHIDTemperatureBridge.m -o "$BENCH_DIR/hid.o"
xcrun swiftc -O -I Pro/SMC \
  -import-objc-header Pro/Sensors/CoolDownSensors-Bridging-Header.h \
  Pro/SMC/SMCKit.swift Pro/SMC/SMCTypes.swift Pro/SMC/SMCKnownNames.swift \
  Tools/TelemetryBenchmark/main.swift "$BENCH_DIR/hid.o" -o "$BENCH_DIR/benchmark"
"$BENCH_DIR/benchmark" 200 --curated
"$BENCH_DIR/benchmark" 200
```

For the baseline, compile the 1.0.14 SMC sources with the same harness, changing
`kit.readTemperatures(includeAll: includeAll)` to `kit.readTemperatures()`.
Use separate executables and alternate runs under the same system conditions.

## Validation and limits

- Release builds succeeded for arm64 and x86_64.
- All 63 XCTest tests passed on arm64 in Debug after the final correction,
  including preservation of Intel/Apple Silicon/lowercase sensor keys and
  out-of-view hotspots, and shuffled case-distinct GPU selection.
- The first final regression run exposed nondeterministic case-insensitive GPU
  sort ties. Exact-key tie breaking fixed the failure; the subsequent suite passed.
- A Release test attempt encountered a cached framework built without
  `-enable-testing`; the subsequent Debug test run succeeded.
- Intel runtime hardware, long-duration energy/memory, sleep/wake, and controlled
  full-app before/after measurements have not been performed. Existing recovery paths are
  retained. The unsigned/ad-hoc test builds were not used to control the fans.
- The local signed app is a development build based on 1.0.14, not a newly
  published or notarized release. Quit the existing fan-control app before
  trying this build so two controllers do not compete.
