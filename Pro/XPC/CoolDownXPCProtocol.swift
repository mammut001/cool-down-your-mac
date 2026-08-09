import Foundation

public let coolDownHelperMachServiceName = "com.cooldown.CoolDownPro.PrivilegedHelper"

@objc public protocol CoolDownHelperProtocol {
    func ping(reply: @escaping (Bool) -> Void)
    func fetchSnapshot(reply: @escaping (Data?, NSError?) -> Void)
    func setFansAuto(reply: @escaping (NSError?) -> Void)
    func setFansPercent(_ percent: Double, reply: @escaping (NSError?) -> Void)
    func setFanRPM(index: Int, rpm: Double, reply: @escaping (NSError?) -> Void)
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
