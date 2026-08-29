import Foundation
import CoolDownKit

/// Best-effort unprivileged SMC access for UI (and local write fallback when helper SMC fails).
/// Prefer the privileged helper for production fan writes.
enum DirectSMCReader {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var kit: SMCKit?
        var snapshot: SensorSnapshot?
        var temperatures: [TemperatureReading] = []
        var temperaturesRefreshedAtUptime: TimeInterval = 0
    }

    private static let state = State()

    static func readSnapshot() -> SensorSnapshot? {
        state.lock.lock()
        defer { state.lock.unlock() }
        do {
            let kit = try sharedKitLocked()
            let fans = try kit.readFans().map {
                FanInfo(
                    index: $0.index,
                    name: $0.name,
                    minRPM: $0.minRPM,
                    maxRPM: $0.maxRPM,
                    currentRPM: $0.currentRPM,
                    targetRPM: $0.targetRPM,
                    isManual: $0.isManual
                )
            }

            let now = ProcessInfo.processInfo.systemUptime
            #if arch(x86_64)
            let isIntel = true
            #else
            let isIntel = false
            #endif
            let temperatureCacheLifetime = ThermalPollingPolicy.temperatureCacheLifetime(
                controlTemperatureC: state.snapshot?.maxTemperatureC,
                isIntel: isIntel
            )
            let cachedTemperaturesAreFresh = !state.temperatures.isEmpty
                && now - state.temperaturesRefreshedAtUptime < temperatureCacheLifetime

            let temps: [TemperatureReading]
            if cachedTemperaturesAreFresh {
                temps = state.temperatures
            } else {
                let freshTemperatures = kit.readTemperatures().map {
                    TemperatureReading(key: $0.key, name: $0.name, celsius: $0.celsius)
                }
                // Keep the last valid sample if a transient SMC read returns no
                // temperature rows. The next expired poll will retry.
                if freshTemperatures.isEmpty, !state.temperatures.isEmpty {
                    temps = state.temperatures
                } else {
                    state.temperatures = freshTemperatures
                    state.temperaturesRefreshedAtUptime = now
                    temps = freshTemperatures
                }
            }

            let snapshot = SensorSnapshot(
                fans: fans,
                temperatures: temps,
                canControlFans: kit.canControlFans,
                helperAvailable: false
            )
            state.snapshot = snapshot
            return snapshot
        } catch {
            state.kit = nil
            // A transient SMC read should not blank the UI. A slightly stale
            // snapshot is preferable and the next poll will retry.
            return state.snapshot
        }
    }

    @discardableResult
    static func setFansAuto() -> Bool {
        do {
            try SMCKit(allowKeysEndpointFallback: false).setAllFansAuto()
            invalidateReadConnection()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func setFansPercent(_ percent: Double) -> Bool {
        do {
            try SMCKit(allowKeysEndpointFallback: false).setAllFansPercent(percent)
            invalidateReadConnection()
            return true
        } catch {
            return false
        }
    }

    private static func sharedKitLocked() throws -> SMCKit {
        if let kit = state.kit {
            return kit
        }
        let kit = try SMCKit(allowKeysEndpointFallback: true)
        state.kit = kit
        return kit
    }

    private static func invalidateReadConnection() {
        state.lock.lock()
        state.kit?.invalidateCaches()
        state.kit = nil
        state.temperaturesRefreshedAtUptime = 0
        state.lock.unlock()
    }
}
