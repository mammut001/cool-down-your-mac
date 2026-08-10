import Foundation
import CoolDownKit

/// Converts thermal demand into a deliberately slow-moving fan target.
///
/// The curve itself remains user-defined, but the controller filters short
/// temperature spikes, applies hysteresis to the curve decision, and limits
/// how quickly the final fan command can move. This prevents the classic
/// heat -> fan burst -> temperature drop -> fan drop oscillation.
public final class SmartCurveEngine: @unchecked Sendable {
    private let lock = NSLock()

    private var filteredTemperatureC: Double?
    private var lastCurvePercent: Double?
    private var lastCurveDecisionTemp: Double?
    private var lastAppliedPercent: Double?
    private var lastUpdateUptime: TimeInterval?
    private var cooldownRemainingSeconds: TimeInterval = 0

    // Tuned for a calm acoustic response while still reacting quickly to heat.
    private let temperatureRiseAlphaAtTwoSeconds = 0.35
    private let temperatureFallAlphaAtTwoSeconds = 0.12
    private let normalRisePerSecond = 0.02
    private let hotRisePerSecond = 0.08
    private let fallPerSecond = 0.0075
    private let decreaseHoldSeconds: TimeInterval = 10
    private let percentDeadband = 0.015
    private let hotTemperatureC = 88.0
    private let emergencyTemperatureC = 92.0

    public init() {}

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        filteredTemperatureC = nil
        lastCurvePercent = nil
        lastCurveDecisionTemp = nil
        lastAppliedPercent = nil
        lastUpdateUptime = nil
        cooldownRemainingSeconds = 0
    }

    /// Returns the final fan percentage after thermal filtering, hysteresis,
    /// load boost, cooldown hold, and asymmetric slew-rate limiting.
    public func targetPercent(
        temperatureC: Double,
        profile: CurveProfile,
        loadBoost: Double = 0
    ) -> Double {
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        let dt = elapsedSeconds(now: now)
        let filtered = filterTemperature(temperatureC, elapsedSeconds: dt)
        let curvePercent = stabilizedCurvePercent(temperatureC: filtered, profile: profile)
        var desired = (curvePercent + loadBoost).clamped(to: 0...1)

        // Safety bypasses: do not let smoothing make the machine sluggish at
        // genuinely high temperatures. 92C goes straight to full fan.
        if temperatureC >= emergencyTemperatureC {
            lastAppliedPercent = 1
            cooldownRemainingSeconds = decreaseHoldSeconds
            return 1
        }
        if temperatureC >= hotTemperatureC {
            desired = max(desired, 0.85)
        }

        guard let last = lastAppliedPercent else {
            lastAppliedPercent = desired
            return desired
        }

        let delta = desired - last

        // Ignore tiny target changes. The desired value can continue drifting,
        // so a meaningful accumulated difference will still be applied later.
        if abs(delta) < percentDeadband {
            cooldownRemainingSeconds = max(0, cooldownRemainingSeconds - dt)
            return last
        }

        if delta > 0 {
            // Any real increase restarts the cooldown timer so we do not undo
            // the cooling response as soon as temperature begins to fall.
            cooldownRemainingSeconds = decreaseHoldSeconds
            let rate = temperatureC >= hotTemperatureC ? hotRisePerSecond : normalRisePerSecond
            let next = min(desired, last + rate * dt)
            lastAppliedPercent = next
            return next
        }

        cooldownRemainingSeconds = max(0, cooldownRemainingSeconds - dt)
        guard cooldownRemainingSeconds <= 0 else {
            return last
        }

        let next = max(desired, last - fallPerSecond * dt)
        lastAppliedPercent = next
        return next
    }

    private func elapsedSeconds(now: TimeInterval) -> TimeInterval {
        defer { lastUpdateUptime = now }
        guard let lastUpdateUptime else { return 2 }
        // Clamp long sleeps / debugger pauses so one delayed poll cannot create
        // an enormous ramp step.
        return (now - lastUpdateUptime).clamped(to: 0.25...10)
    }

    private func filterTemperature(_ raw: Double, elapsedSeconds dt: TimeInterval) -> Double {
        guard let previous = filteredTemperatureC else {
            filteredTemperatureC = raw
            return raw
        }

        // React faster while heating and deliberately slower while cooling.
        let baseAlpha = raw >= previous
            ? temperatureRiseAlphaAtTwoSeconds
            : temperatureFallAlphaAtTwoSeconds
        let alpha = 1 - pow(1 - baseAlpha, dt / 2)
        let next = previous + (raw - previous) * alpha
        filteredTemperatureC = next
        return next
    }

    private func stabilizedCurvePercent(temperatureC: Double, profile: CurveProfile) -> Double {
        let raw = profile.fanPercent(for: temperatureC)
        guard let last = lastCurvePercent, let lastTemp = lastCurveDecisionTemp else {
            lastCurvePercent = raw
            lastCurveDecisionTemp = temperatureC
            return raw
        }

        let tempDelta = abs(temperatureC - lastTemp)
        let percentDelta = abs(raw - last)
        if tempDelta < profile.hysteresisC && percentDelta < 0.03 {
            return last
        }

        lastCurvePercent = raw
        lastCurveDecisionTemp = temperatureC
        return raw
    }
}
