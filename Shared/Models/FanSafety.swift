import Foundation

/// Decides which temperature readings may drive fan control.
///
/// v1.0.19 discarded every reading at or above 110-115 °C to suppress isolated
/// sensor glitches. That also discarded the hottest real die sensor, so the
/// control temperature fell exactly when the machine was hottest. A reading in
/// the glitch band is now trusted when another sensor corroborates real heat.
public enum TemperatureSanity {
    public static let minimumC = 5.0
    /// Readings at or above this need a second hot sensor to be trusted.
    public static let corroborationRequiredC = 110.0
    /// A different sensor at or above this makes a glitch-band reading plausible.
    public static let corroboratingC = 90.0
    /// No Mac sensor legitimately reports this; treat it as a decode fault.
    public static let impossibleC = 150.0

    public static func isInRange(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius > minimumC && celsius < impossibleC
    }

    public static func trustedControlReadings(_ readings: [TemperatureReading]) -> [TemperatureReading] {
        let inRange = readings.filter { isInRange($0.celsius) }
        return inRange.filter { reading in
            guard reading.celsius >= corroborationRequiredC else { return true }
            return inRange.contains { $0.key != reading.key && $0.celsius >= corroboratingC }
        }
    }
}

/// Manual-mode high-temperature override with hysteresis and a minimum hold.
/// Without them, a temperature hovering at a threshold switched the fans
/// between full speed and the user's low setting on every poll.
public struct ThermalOverrideLatch: Sendable {
    public struct Level: Sendable {
        public let enterC: Double
        public let exitC: Double
        public let percent: Double
    }

    /// Ordered from most to least severe.
    public static let levels: [Level] = [
        Level(enterC: 95, exitC: 90, percent: 1.0),
        Level(enterC: 90, exitC: 85, percent: 0.75)
    ]
    public static let minimumHoldSeconds: TimeInterval = 10

    public private(set) var percent: Double?
    private var changedAt: TimeInterval = 0

    public init() {}

    public mutating func reset() {
        percent = nil
        changedAt = 0
    }

    public mutating func update(temperatureC: Double?, now: TimeInterval) -> Double? {
        guard let temperatureC, temperatureC.isFinite else {
            reset()
            return nil
        }
        let entered = Self.levels.first { temperatureC >= $0.enterC }?.percent
        if let entered, entered > (percent ?? -1) {
            percent = entered
            changedAt = now
            return percent
        }
        guard let current = percent else { return nil }
        let sustained = Self.levels.first { temperatureC >= $0.exitC }?.percent
        if (sustained ?? -1) < current, now - changedAt >= Self.minimumHoldSeconds {
            percent = sustained
            changedAt = now
        }
        return percent
    }
}

/// Compares the fans' published SMC state with the command this app owns.
/// Lease renewal does not write the SMC, so a change by firmware or another
/// fan-control app would otherwise go unnoticed for as long as the target
/// percentage stayed the same.
public enum FanCommandVerification {
    /// Mirrors `SMCKit.setAllFansPercent`.
    public static func expectedTargetRPM(percent: Double, minRPM: Double, maxRPM: Double) -> Double {
        let lo = minRPM > 200 ? minRPM : 1350
        let hi = maxRPM > lo ? maxRPM : max(lo + 1000, 6000)
        return lo + (hi - lo) * min(max(percent, 0), 1)
    }

    public static func manualCommandHasDrifted(percent: Double, fans: [FanInfo]) -> Bool {
        for fan in fans {
            if !fan.isManual { return true }
            guard let target = fan.targetRPM, target.isFinite else { continue }
            let expected = expectedTargetRPM(percent: percent, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
            if abs(target - expected) > max(50, expected * 0.03) { return true }
        }
        return false
    }
}

public struct ReplyTimeoutError: LocalizedError, Sendable {
    public let seconds: TimeInterval
    public init(seconds: TimeInterval) { self.seconds = seconds }
    public var errorDescription: String? {
        String(format: "Fan-control helper did not reply within %.0f seconds", seconds)
    }
}

/// Resumes a callback-based request exactly once: with its reply, or with
/// `ReplyTimeoutError` if no reply arrives. An XPC proxy whose peer is stuck
/// never calls its reply or error handler, which previously stalled polling.
public func awaitReply<T>(
    timeout: TimeInterval,
    onTimeout: @escaping @Sendable () -> Void = {},
    _ body: (@escaping (Result<T, Error>) -> Void) -> Void
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let lock = NSLock()
        var resumed = false
        func finish(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return false }
            resumed = true
            continuation.resume(with: result)
            return true
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            if finish(.failure(ReplyTimeoutError(seconds: timeout))) {
                onTimeout()
            }
        }
        body { _ = finish($0) }
    }
}
