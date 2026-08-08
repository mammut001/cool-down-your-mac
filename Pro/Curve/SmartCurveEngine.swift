import Foundation
import CoolDownKit

/// Maps temperature to fan percent with hysteresis to avoid RPM chatter.
public final class SmartCurveEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAppliedPercent: Double?
    private var lastDecisionTemp: Double?

    public init() {}

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastAppliedPercent = nil
        lastDecisionTemp = nil
    }

    public func targetPercent(temperatureC: Double, profile: CurveProfile) -> Double {
        lock.lock()
        defer { lock.unlock() }

        let raw = profile.fanPercent(for: temperatureC)
        guard let last = lastAppliedPercent, let lastTemp = lastDecisionTemp else {
            lastAppliedPercent = raw
            lastDecisionTemp = temperatureC
            return raw
        }

        // Only change when temperature moves beyond hysteresis or percent delta is meaningful.
        let tempDelta = abs(temperatureC - lastTemp)
        let percentDelta = abs(raw - last)
        if tempDelta < profile.hysteresisC && percentDelta < 0.03 {
            return last
        }

        lastAppliedPercent = raw
        lastDecisionTemp = temperatureC
        return raw
    }
}
