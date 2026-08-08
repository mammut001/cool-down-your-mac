import Foundation
import CoolDownKit

/// Best-effort unprivileged SMC read for UI when helper is not yet installed.
/// Writes always go through the privileged helper.
enum DirectSMCReader {
    static func readSnapshot() -> SensorSnapshot? {
        do {
            let kit = try SMCKit()
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
                canControlFans: false,
                helperAvailable: false
            )
        } catch {
            return nil
        }
    }
}
