import Foundation
import CoolDownKit

/// Best-effort unprivileged SMC access for UI (and local write fallback when helper SMC fails).
/// Prefer the privileged helper for production fan writes.
enum DirectSMCReader {
    static func readSnapshot() -> SensorSnapshot? {
        do {
            let kit = try SMCKit(allowKeysEndpointFallback: true)
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
            let temps = kit.readTemperatures().map {
                TemperatureReading(key: $0.key, name: $0.name, celsius: $0.celsius)
            }
            return SensorSnapshot(
                fans: fans,
                temperatures: temps,
                canControlFans: kit.canControlFans,
                helperAvailable: false
            )
        } catch {
            return nil
        }
    }

    @discardableResult
    static func setFansAuto() -> Bool {
        do {
            try SMCKit(allowKeysEndpointFallback: false).setAllFansAuto()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func setFansPercent(_ percent: Double) -> Bool {
        do {
            try SMCKit(allowKeysEndpointFallback: false).setAllFansPercent(percent)
            return true
        } catch {
            return false
        }
    }
}
