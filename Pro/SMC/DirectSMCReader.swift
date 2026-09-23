import Foundation
import CoolDownKit

/// Best-effort unprivileged SMC access for UI (and local write fallback when helper SMC fails).
/// Prefer the privileged helper for production fan writes.
enum DirectSMCReader {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var kit: SMCKit?
    }

    private static let state = State()

    static func readSnapshot(includeAllTemperatures: Bool = true) -> SensorSnapshot? {
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
            let temps = kit.readTemperatures(includeAll: includeAllTemperatures).map {
                TemperatureReading(key: $0.key, name: $0.name, celsius: $0.celsius)
            }
            let snapshot = SensorSnapshot(
                fans: fans,
                temperatures: temps,
                canControlFans: kit.canControlFans,
                helperAvailable: false
            )
            return snapshot
        } catch {
            state.kit = nil
            // A cached temperature must never be mistaken for a fresh control
            // sample. The caller may use HID readings or restore system auto.
            return nil
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

    static func invalidateReadConnection() {
        state.lock.lock()
        state.kit?.invalidateCaches()
        state.kit = nil
        state.lock.unlock()
    }
}
