import Foundation
import CoolDownKit

/// Converts thermal demand into a deliberately slow-moving fan target.
///
/// The curve itself remains user-defined, but the controller filters short
/// temperature spikes, applies hysteresis to the curve decision, and limits
/// how quickly the final fan command can move. This prevents the classic
/// heat -> fan burst -> temperature drop -> fan drop oscillation.
public final class SmartCurveEngine: @unchecked Sendable {
    #if DEBUG
    public struct Diagnostics: Sendable {
        public let rawTemperatureC: Double
        public let filteredTemperatureC: Double?
        public let curvePercent: Double
        public let loadBoostPercent: Double
        public let desiredPercent: Double
        public let finalPercent: Double
        public let cooldownRemainingSeconds: TimeInterval
        public let isHotResponse: Bool
        public let isEmergency: Bool

        public init(
            rawTemperatureC: Double,
            filteredTemperatureC: Double?,
            curvePercent: Double,
            loadBoostPercent: Double,
            desiredPercent: Double,
            finalPercent: Double,
            cooldownRemainingSeconds: TimeInterval,
            isHotResponse: Bool,
            isEmergency: Bool
        ) {
            self.rawTemperatureC = rawTemperatureC
            self.filteredTemperatureC = filteredTemperatureC
            self.curvePercent = curvePercent
            self.loadBoostPercent = loadBoostPercent
            self.desiredPercent = desiredPercent
            self.finalPercent = finalPercent
            self.cooldownRemainingSeconds = cooldownRemainingSeconds
            self.isHotResponse = isHotResponse
            self.isEmergency = isEmergency
        }
    }
    #endif

    private let lock = NSLock()

    private var filteredTemperatureC: Double?
    private var lastCurvePercent: Double?
    private var lastCurveDecisionTemp: Double?
    private var lastAppliedPercent: Double?
    private var lastUpdateUptime: TimeInterval?
    private var cooldownRemainingSeconds: TimeInterval = 0
    #if DEBUG
    private var lastDiagnostics: Diagnostics?
    #endif

    // Tuned for a calm acoustic response at normal temperatures while moving
    // decisively before the chassis heat-soaks in a warm ambient environment.
    private let temperatureRiseAlphaAtTwoSeconds = 0.35
    private let temperatureFallAlphaAtTwoSeconds = 0.12
    private let normalRisePerSecond = 0.02
    private let warmRisePerSecond = 0.05
    private let hotRisePerSecond = 0.12
    private let fallPerSecond = 0.0075
    private let decreaseHoldSeconds: TimeInterval = 10
    private let percentDeadband = 0.015
    private let warmTemperatureC = 80.0
    private let hotTemperatureC = 85.0
    private let emergencyTemperatureC = 90.0
    private let warmFanFloor = 0.85
    private let hotFanFloor = 0.95

    public init() {}

    #if DEBUG
    public var diagnostics: Diagnostics {
        lock.lock()
        defer { lock.unlock() }
        return Diagnostics(
            rawTemperatureC: lastDiagnostics?.rawTemperatureC ?? filteredTemperatureC ?? 0,
            filteredTemperatureC: lastDiagnostics?.filteredTemperatureC ?? filteredTemperatureC,
            curvePercent: lastDiagnostics?.curvePercent ?? lastCurvePercent ?? 0,
            loadBoostPercent: lastDiagnostics?.loadBoostPercent ?? 0,
            desiredPercent: lastDiagnostics?.desiredPercent ?? lastAppliedPercent ?? 0,
            finalPercent: lastDiagnostics?.finalPercent ?? lastAppliedPercent ?? 0,
            cooldownRemainingSeconds: lastDiagnostics?.cooldownRemainingSeconds ?? cooldownRemainingSeconds,
            isHotResponse: lastDiagnostics?.isHotResponse ?? false,
            isEmergency: lastDiagnostics?.isEmergency ?? false
        )
    }
    #endif

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        filteredTemperatureC = nil
        lastCurvePercent = nil
        lastCurveDecisionTemp = nil
        lastAppliedPercent = nil
        lastUpdateUptime = nil
        cooldownRemainingSeconds = 0
        #if DEBUG
        lastDiagnostics = nil
        #endif
    }

    /// Returns the final fan percentage after thermal filtering, hysteresis,
    /// load boost, cooldown hold, and asymmetric slew-rate limiting.
    public func targetPercent(
        temperatureC: Double,
        profile: CurveProfile,
        loadBoost: Double = 0,
        uptime: TimeInterval? = nil
    ) -> Double {
        lock.lock()
        defer { lock.unlock() }

        let now = uptime ?? ProcessInfo.processInfo.systemUptime
        let dt = elapsedSeconds(now: now)
        let filtered = filterTemperature(temperatureC, elapsedSeconds: dt)
        let curvePercent = stabilizedCurvePercent(temperatureC: filtered, profile: profile)
        var desired = (curvePercent + loadBoost).clamped(to: 0...1)
        let isEmergency = temperatureC >= emergencyTemperatureC
        let isHotResponse = temperatureC >= hotTemperatureC
        let isWarmResponse = temperatureC >= warmTemperatureC

        // Safety bypasses: do not let smoothing make the machine sluggish at
        // genuinely high temperatures. 90C goes straight to full fan. Warm
        // and hot floors start building airflow before thermal saturation.
        if isEmergency {
            lastAppliedPercent = 1
            cooldownRemainingSeconds = decreaseHoldSeconds
            #if DEBUG
            lastDiagnostics = Diagnostics(
                rawTemperatureC: temperatureC,
                filteredTemperatureC: filtered,
                curvePercent: curvePercent,
                loadBoostPercent: loadBoost,
                desiredPercent: 1,
                finalPercent: 1,
                cooldownRemainingSeconds: cooldownRemainingSeconds,
                isHotResponse: true,
                isEmergency: true
            )
            #endif
            return 1
        }

        if isWarmResponse || isHotResponse {
            let rawCurvePercent = profile.fanPercent(for: temperatureC)
            let rawDesired = (rawCurvePercent + loadBoost).clamped(to: 0...1)
            desired = max(desired, rawDesired)
        }

        if isHotResponse {
            desired = max(desired, hotFanFloor)
        } else if isWarmResponse {
            desired = max(desired, warmFanFloor)
        }

        guard let last = lastAppliedPercent else {
            lastAppliedPercent = desired
            cooldownRemainingSeconds = decreaseHoldSeconds
            #if DEBUG
            lastDiagnostics = Diagnostics(
                rawTemperatureC: temperatureC,
                filteredTemperatureC: filtered,
                curvePercent: curvePercent,
                loadBoostPercent: loadBoost,
                desiredPercent: desired,
                finalPercent: desired,
                cooldownRemainingSeconds: cooldownRemainingSeconds,
                isHotResponse: isHotResponse,
                isEmergency: false
            )
            #endif
            return desired
        }

        // At 85C and above, reach the hot floor immediately instead of taking
        // several polling intervals to slew through a dangerous temperature.
        if isHotResponse && last < desired {
            let next = desired
            lastAppliedPercent = next
            cooldownRemainingSeconds = decreaseHoldSeconds
            #if DEBUG
            lastDiagnostics = Diagnostics(
                rawTemperatureC: temperatureC,
                filteredTemperatureC: filtered,
                curvePercent: curvePercent,
                loadBoostPercent: loadBoost,
                desiredPercent: desired,
                finalPercent: next,
                cooldownRemainingSeconds: cooldownRemainingSeconds,
                isHotResponse: true,
                isEmergency: false
            )
            #endif
            return next
        }

        // At 80C and above, reach the warm floor immediately instead of taking
        // several polling intervals to slew from a low previous target.
        if isWarmResponse && last < desired {
            let next = desired
            lastAppliedPercent = next
            cooldownRemainingSeconds = decreaseHoldSeconds
            #if DEBUG
            lastDiagnostics = Diagnostics(
                rawTemperatureC: temperatureC,
                filteredTemperatureC: filtered,
                curvePercent: curvePercent,
                loadBoostPercent: loadBoost,
                desiredPercent: desired,
                finalPercent: next,
                cooldownRemainingSeconds: cooldownRemainingSeconds,
                isHotResponse: false,
                isEmergency: false
            )
            #endif
            return next
        }

        let delta = desired - last

        // Ignore tiny target changes. The desired value can continue drifting,
        // so a meaningful accumulated difference will still be applied later.
        // Do not stall below an active thermal floor.
        if abs(delta) < percentDeadband && !(isHotResponse && last < hotFanFloor) {
            cooldownRemainingSeconds = max(0, cooldownRemainingSeconds - dt)
            #if DEBUG
            lastDiagnostics = Diagnostics(
                rawTemperatureC: temperatureC,
                filteredTemperatureC: filtered,
                curvePercent: curvePercent,
                loadBoostPercent: loadBoost,
                desiredPercent: desired,
                finalPercent: last,
                cooldownRemainingSeconds: cooldownRemainingSeconds,
                isHotResponse: isHotResponse,
                isEmergency: false
            )
            #endif
            return last
        }

        if delta > 0 {
            // Any real increase restarts the cooldown timer so we do not undo
            // the cooling response as soon as temperature begins to fall.
            cooldownRemainingSeconds = decreaseHoldSeconds
            let rate: Double
            if isHotResponse {
                rate = hotRisePerSecond
            } else if isWarmResponse {
                rate = warmRisePerSecond
            } else {
                rate = normalRisePerSecond
            }
            let next = min(desired, last + rate * dt)
            lastAppliedPercent = next
            #if DEBUG
            lastDiagnostics = Diagnostics(
                rawTemperatureC: temperatureC,
                filteredTemperatureC: filtered,
                curvePercent: curvePercent,
                loadBoostPercent: loadBoost,
                desiredPercent: desired,
                finalPercent: next,
                cooldownRemainingSeconds: cooldownRemainingSeconds,
                isHotResponse: isHotResponse,
                isEmergency: false
            )
            #endif
            return next
        }

        cooldownRemainingSeconds = max(0, cooldownRemainingSeconds - dt)
        guard cooldownRemainingSeconds <= 0 else {
            #if DEBUG
            lastDiagnostics = Diagnostics(
                rawTemperatureC: temperatureC,
                filteredTemperatureC: filtered,
                curvePercent: curvePercent,
                loadBoostPercent: loadBoost,
                desiredPercent: desired,
                finalPercent: last,
                cooldownRemainingSeconds: cooldownRemainingSeconds,
                isHotResponse: isHotResponse,
                isEmergency: false
            )
            #endif
            return last
        }

        let next = max(desired, last - fallPerSecond * dt)
        lastAppliedPercent = next
        #if DEBUG
        lastDiagnostics = Diagnostics(
            rawTemperatureC: temperatureC,
            filteredTemperatureC: filtered,
            curvePercent: curvePercent,
            loadBoostPercent: loadBoost,
            desiredPercent: desired,
            finalPercent: next,
            cooldownRemainingSeconds: cooldownRemainingSeconds,
            isHotResponse: isHotResponse,
            isEmergency: false
        )
        #endif
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
        if tempDelta < profile.hysteresisC {
            return last
        }

        lastCurvePercent = raw
        lastCurveDecisionTemp = temperatureC
        return raw
    }
}
