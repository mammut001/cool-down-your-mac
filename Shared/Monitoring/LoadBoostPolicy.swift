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

    /// Keep activation aligned with the app's default 2-second control tick:
    /// near-threshold load can wait for the next tick, but never just beyond it
    /// and therefore an additional full polling interval. The delay reaches
    /// zero at 75% normalized excess (90% load with the default threshold).
    public static func activationDelaySeconds(loadPercent: Double, threshold: Double) -> TimeInterval {
        let t = normalizedExcess(loadPercent: loadPercent, threshold: threshold)
        return max(0, 2.0 * (1.0 - (t / 0.75)))
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
