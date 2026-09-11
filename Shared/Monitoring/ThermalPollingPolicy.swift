import Foundation

/// Centralizes telemetry cadence decisions so low-overhead polling remains
/// conservative around hot temperatures. Cheap CPU/fan-control work can still
/// run on the normal app timer while expensive temperature scans are reused.
public enum ThermalPollingPolicy {
    /// Maximum age for a cached direct-SMC temperature sample.
    ///
    /// Intel Macs pay substantially more for enumerating and reading SMC
    /// temperature keys, so cool/low-load operation reuses the previous sample
    /// for up to 4 seconds. Rising CPU load acts as feed-forward and restores
    /// the normal 2-second cadence before the last sampled temperature has
    /// already become hot. A 70C thermal threshold does the same even at lower
    /// CPU load. Apple Silicon keeps the existing 2-second behavior.
    public static func temperatureCacheLifetime(
        controlTemperatureC: Double?,
        isIntel: Bool,
        cpuLoadPercent: Double? = nil
    ) -> TimeInterval {
        guard isIntel else { return 2.0 }

        if let load = cpuLoadPercent, load.isFinite, load >= 60 {
            return 2.0
        }

        guard let temperature = controlTemperatureC, temperature.isFinite else {
            return 2.0
        }

        return temperature >= 70 ? 2.0 : 4.0
    }
}
