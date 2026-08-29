import Foundation

/// Pure policy for turning sustained aggregate CPU load into a progressive
/// fan boost. The policy deliberately reacts faster as load approaches 100%
/// while retaining a small activation delay near the threshold to avoid
/// audible fan pulses from short bursts.
public enum LoadBoostPolicy {
    public static func normalizedExcess(loadPercent: Double, threshold: Double) -> Double {
        let threshold = min(max(threshold, 20), 95)
        let load = min(max(loadPercent, 0), 100)
        guard load > threshold else { return 0 }
        return min(max((load - threshold) / max(100 - threshold, 1), 0), 1)
    }

    /// Near the threshold, wait up to 3 seconds so brief activity spikes do not
    /// move the fans. At very high load, shrink the delay toward 1 second.
    public static func activationDelaySeconds(loadPercent: Double, threshold: Double) -> TimeInterval {
        let t = normalizedExcess(loadPercent: loadPercent, threshold: threshold)
        return 3.0 - (2.0 * t)
    }

    /// Use a sub-linear power curve so moderate/high load earns useful airflow
    /// earlier instead of waiting until CPU utilization is nearly saturated.
    public static func desiredBoost(loadPercent: Double, threshold: Double, boostMax: Double) -> Double {
        let maxBoost = min(max(boostMax, 0), 0.4)
        guard maxBoost > 0 else { return 0 }
        let t = normalizedExcess(loadPercent: loadPercent, threshold: threshold)
        guard t > 0 else { return 0 }
        return maxBoost * pow(t, 0.65)
    }

    /// The boost itself also ramps faster at high utilization. Release remains
    /// intentionally slower in LoadMonitor to preserve acoustic stability.
    public static func riseTimeConstantSeconds(loadPercent: Double, threshold: Double) -> TimeInterval {
        let t = normalizedExcess(loadPercent: loadPercent, threshold: threshold)
        return 3.0 - (1.5 * t)
    }
}
