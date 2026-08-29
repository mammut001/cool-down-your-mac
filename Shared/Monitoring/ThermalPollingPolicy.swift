import Foundation

/// Centralizes telemetry cadence decisions so low-overhead polling remains
/// conservative around hot temperatures. Cheap CPU/fan-control work can still
/// run on the normal app timer while expensive temperature scans are reused.
public enum ThermalPollingPolicy {
    /// Maximum age for a cached direct-SMC temperature sample.
    ///
    /// Intel Macs pay substantially more for enumerating and reading SMC
    /// temperature keys, so cool/normal operation reuses the previous sample.
    /// Rising CPU load acts as feed-forward: expensive temperature polling
    /// accelerates before the last sampled temperature has already become hot.
    /// Apple Silicon keeps the existing 2s behavior because HID telemetry is
    /// the primary path there.
    public static func temperatureCacheLifetime(
        controlTemperatureC: Double?,
        isIntel: Bool,
        cpuLoadPercent: Double? = nil
    ) -> TimeInterval {
        guard isIntel else { return 2.0 }

        if let load = cpuLoadPercent, load.isFinite {
            if load >= 80 {
                return 2.0
            }
            if load >= 60 {
                return 3.0
            }
        }

        guard let temperature = controlTemperatureC, temperature.isFinite else {
            return 2.0
        }

        switch temperature {
        case 80...:
            return 2.0
        case 70..<80:
            return 3.0
        default:
            return 4.0
        }
    }
}
