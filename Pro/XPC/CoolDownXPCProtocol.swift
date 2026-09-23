import Foundation

public let coolDownHelperMachServiceName = "com.cooldown.CoolDownPro.PrivilegedHelper"

/// Pure lease state; the helper owns serialization and SMC recovery.
struct FanControlLease {
    private(set) var owner: UUID?
    private(set) var deadline: TimeInterval?

    mutating func acquire(clientID: UUID, now: TimeInterval, duration: TimeInterval) {
        owner = clientID
        deadline = now + duration
    }

    mutating func renew(clientID: UUID, now: TimeInterval, duration: TimeInterval) -> Bool {
        guard owner == clientID, let deadline, now < deadline else { return false }
        self.deadline = now + duration
        return true
    }

    func isOwned(by clientID: UUID) -> Bool { owner == clientID }

    func hasExpired(now: TimeInterval) -> Bool {
        deadline.map { now >= $0 } ?? false
    }

    mutating func clear() {
        owner = nil
        deadline = nil
    }
}

@objc public protocol CoolDownHelperProtocol {
    func ping(reply: @escaping (Bool) -> Void)
    func fetchSnapshot(reply: @escaping (Data?, NSError?) -> Void)
    func setFansAuto(reply: @escaping (NSError?) -> Void)
    func setFansPercent(_ percent: Double, reply: @escaping (NSError?) -> Void)
    func setFanRPM(index: Int, rpm: Double, reply: @escaping (NSError?) -> Void)
    /// Keeps an unchanged manual target alive without repeating an SMC write.
    func renewFanControlLease(reply: @escaping (NSError?) -> Void)
}

public enum CoolDownXPCError: Int {
    case helperUnavailable = 1
    case unauthorized = 2
    case smcFailed = 3
    case encodeFailed = 4

    public var nsError: NSError {
        let messages: [CoolDownXPCError: String] = [
            .helperUnavailable: "Privileged helper is unavailable",
            .unauthorized: "Caller is not authorized",
            .smcFailed: "SMC operation failed",
            .encodeFailed: "Failed to encode snapshot"
        ]
        return NSError(
            domain: "com.cooldown.CoolDownPro.XPC",
            code: rawValue,
            userInfo: [NSLocalizedDescriptionKey: messages[self] ?? "Unknown error"]
        )
    }
}

public struct XPCSnapshotDTO: Codable, Sendable {
    public var fans: [FanDTO]
    public var temperatures: [TempDTO]
    public var canControlFans: Bool
    /// Missing in pre-lease helpers. An upgraded app must not use their writes.
    public var supportsFanLease: Bool

    enum CodingKeys: String, CodingKey {
        case fans, temperatures, canControlFans, supportsFanLease
    }

    public init(fans: [FanDTO], temperatures: [TempDTO], canControlFans: Bool, supportsFanLease: Bool = true) {
        self.fans = fans
        self.temperatures = temperatures
        self.canControlFans = canControlFans
        self.supportsFanLease = supportsFanLease
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fans = try c.decode([FanDTO].self, forKey: .fans)
        temperatures = try c.decode([TempDTO].self, forKey: .temperatures)
        canControlFans = try c.decode(Bool.self, forKey: .canControlFans)
        supportsFanLease = try c.decodeIfPresent(Bool.self, forKey: .supportsFanLease) ?? false
    }

    public struct FanDTO: Codable, Sendable {
        public var index: Int
        public var name: String
        public var minRPM: Double
        public var maxRPM: Double
        public var currentRPM: Double
        public var targetRPM: Double?
        public var isManual: Bool
    }

    public struct TempDTO: Codable, Sendable {
        public var key: String
        public var name: String
        public var celsius: Double
    }
}
