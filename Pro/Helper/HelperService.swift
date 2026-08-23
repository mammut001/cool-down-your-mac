import Foundation
import os.log

final class HelperService: NSObject, CoolDownHelperProtocol {
    private let queue = DispatchQueue(label: "com.cooldown.helper.smc", qos: .userInitiated)
    private var smc: SMCKit?
    private var cachedTemperatures: [XPCSnapshotDTO.TempDTO] = []
    private var lastTemperatureSampleUptime: TimeInterval = 0
    #if arch(x86_64)
    private let temperatureSampleIntervalSeconds: TimeInterval = 10
    #else
    private let temperatureSampleIntervalSeconds: TimeInterval = 6
    #endif
    private static let log = Logger(subsystem: "com.cooldown.CoolDownPro.PrivilegedHelper", category: "SMC")

    static func restoreFansBestEffort() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SMCKit(allowKeysEndpointFallback: false).setAllFansAuto()
                log.info("client gone — fans restored to auto")
            } catch {
                log.error("client-gone restore failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func withSMC<T>(_ body: (SMCKit) throws -> T) throws -> T {
        if smc == nil {
            do {
                smc = try SMCKit(allowKeysEndpointFallback: false)
                Self.log.info("SMC open OK")
            } catch {
                Self.log.error("SMC open failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        guard let open = smc else { throw CoolDownXPCError.smcFailed.nsError }
        do {
            return try body(open)
        } catch {
            smc = nil
            do {
                smc = try SMCKit(allowKeysEndpointFallback: false)
                Self.log.info("SMC reopened after I/O failure")
                return try body(smc!)
            } catch {
                Self.log.error("SMC reopen failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func fetchSnapshot(reply: @escaping (Data?, NSError?) -> Void) {
        queue.async {
            do {
                let now = ProcessInfo.processInfo.systemUptime
                let refreshTemperatures = self.cachedTemperatures.isEmpty
                    || now - self.lastTemperatureSampleUptime >= self.temperatureSampleIntervalSeconds

                let dto = try self.withSMC { kit -> XPCSnapshotDTO in
                    let fans = try kit.readFans().map {
                        XPCSnapshotDTO.FanDTO(
                            index: $0.index,
                            name: $0.name,
                            minRPM: $0.minRPM,
                            maxRPM: $0.maxRPM,
                            currentRPM: $0.currentRPM,
                            targetRPM: $0.targetRPM,
                            isManual: $0.isManual
                        )
                    }
                    if refreshTemperatures {
                        self.cachedTemperatures = kit.readTemperatures().map {
                            XPCSnapshotDTO.TempDTO(key: $0.key, name: $0.name, celsius: $0.celsius)
                        }
                        self.lastTemperatureSampleUptime = now
                    }
                    return XPCSnapshotDTO(
                        fans: fans,
                        temperatures: self.cachedTemperatures,
                        canControlFans: kit.canControlFans
                    )
                }
                let data = try JSONEncoder().encode(dto)
                reply(data, nil)
            } catch let error as NSError {
                Self.log.error("fetchSnapshot failed: \(error.localizedDescription, privacy: .public)")
                reply(nil, error)
            } catch {
                Self.log.error("fetchSnapshot failed: \(String(describing: error), privacy: .public)")
                reply(nil, CoolDownXPCError.smcFailed.nsError)
            }
        }
    }

    func setFansAuto(reply: @escaping (NSError?) -> Void) {
        queue.async {
            do {
                try self.withSMC { try $0.setAllFansAuto() }
                Self.log.info("setFansAuto OK")
                reply(nil)
            } catch let error as NSError {
                Self.log.error("setFansAuto failed: \(error.localizedDescription, privacy: .public)")
                reply(error)
            } catch {
                Self.log.error("setFansAuto failed: \(String(describing: error), privacy: .public)")
                reply(CoolDownXPCError.smcFailed.nsError)
            }
        }
    }

    func setFansPercent(_ percent: Double, reply: @escaping (NSError?) -> Void) {
        queue.async {
            guard percent.isFinite, (0...1).contains(percent) else {
                Self.log.error("setFansPercent rejected bad percent \(percent, privacy: .public)")
                reply(NSError(domain: "com.cooldown.CoolDownPro.XPC", code: CoolDownXPCError.smcFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "Invalid fan percent"]))
                return
            }
            do {
                try self.withSMC { try $0.setAllFansPercent(percent) }
                Self.log.info("setFansPercent \(percent, privacy: .public) OK")
                reply(nil)
            } catch let error as NSError {
                Self.log.error("setFansPercent failed: \(error.localizedDescription, privacy: .public)")
                reply(error)
            } catch {
                Self.log.error("setFansPercent failed: \(String(describing: error), privacy: .public)")
                reply(CoolDownXPCError.smcFailed.nsError)
            }
        }
    }

    func setFanRPM(index: Int, rpm: Double, reply: @escaping (NSError?) -> Void) {
        queue.async {
            guard (0..<8).contains(index), rpm.isFinite, rpm > 0, rpm < 20000 else {
                Self.log.error("setFanRPM rejected bad args index=\(index) rpm=\(rpm, privacy: .public)")
                reply(NSError(domain: "com.cooldown.CoolDownPro.XPC", code: CoolDownXPCError.smcFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "Invalid fan RPM"]))
                return
            }
            do {
                try self.withSMC { try $0.setFanRPM(index: index, rpm: rpm) }
                Self.log.info("setFanRPM index=\(index) rpm=\(rpm, privacy: .public) OK")
                reply(nil)
            } catch let error as NSError {
                Self.log.error("setFanRPM failed: \(error.localizedDescription, privacy: .public)")
                reply(error)
            } catch {
                Self.log.error("setFanRPM failed: \(String(describing: error), privacy: .public)")
                reply(CoolDownXPCError.smcFailed.nsError)
            }
        }
    }
}
