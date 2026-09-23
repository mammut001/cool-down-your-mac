import Foundation
import os.log

final class HelperService: NSObject, CoolDownHelperProtocol {
    // All XPC connections, disconnect restores and lease expirations must use
    // one queue. Otherwise an old connection can undo a newer fan command.
    private static let queue = DispatchQueue(label: "com.cooldown.helper.smc", qos: .userInitiated)
    private static var smc: SMCKit?
    private static var lease = FanControlLease()
    private static var restorePending = false
    private static let leaseSeconds: TimeInterval = 45 // 10s sample interval becomes 25s with display asleep
    private static let watchdog: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(queue: HelperService.queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler {
            let expired = HelperService.lease.hasExpired(now: ProcessInfo.processInfo.systemUptime)
            guard HelperService.restorePending || expired else { return }
            do {
                try HelperService.restoreAutoLocked()
                HelperService.log.info("fan lease expired or restore retried — system auto restored")
            } catch {
                HelperService.log.error("fan lease restore failed; retrying: \(String(describing: error), privacy: .public)")
            }
        }
        timer.resume()
        return timer
    }()
    private let clientID = UUID()
    private static let log = Logger(subsystem: "com.cooldown.CoolDownPro.PrivilegedHelper", category: "SMC")

    func clientGone() {
        let clientID = self.clientID
        Self.queue.async {
            guard Self.lease.isOwned(by: clientID) else { return }
            do {
                try Self.restoreAutoLocked()
                Self.log.info("controlling client gone — fans restored to auto")
            } catch {
                Self.log.error("client-gone restore failed; retrying: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// SIGTERM waits for the same serial queue so it cannot race a pending write.
    static func restoreFansBeforeExit() throws {
        try queue.sync { try restoreAutoLocked() }
    }

    private static func restoreAutoLocked() throws {
        restorePending = true
        try withSMC { try $0.setAllFansAuto() }
        lease.clear()
        restorePending = false
    }

    private static func withSMC<T>(_ body: (SMCKit) throws -> T) throws -> T {
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
                guard let reopened = smc else { throw CoolDownXPCError.smcFailed.nsError }
                return try body(reopened)
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
        Self.queue.async {
            do {
                let dto = try Self.withSMC { kit -> XPCSnapshotDTO in
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
                    // The app overlays HID + local SMC temperatures. Re-scanning
                    // every SMC key here was discarded by the client and dominated
                    // helper CPU.
                    return XPCSnapshotDTO(
                        fans: fans,
                        temperatures: [],
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
        Self.queue.async {
            do {
                try Self.restoreAutoLocked()
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
        let clientID = self.clientID
        Self.queue.async {
            guard percent.isFinite, (0...1).contains(percent) else {
                Self.log.error("setFansPercent rejected bad percent \(percent, privacy: .public)")
                reply(NSError(domain: "com.cooldown.CoolDownPro.XPC", code: CoolDownXPCError.smcFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "Invalid fan percent"]))
                return
            }
            do {
                _ = Self.watchdog
                // Failed writes can leave a subset of fans in manual mode.
                // Keep the retry watchdog armed until auto is confirmed.
                Self.restorePending = true
                try Self.withSMC { try $0.setAllFansPercent(percent) }
                Self.lease.acquire(clientID: clientID, now: ProcessInfo.processInfo.systemUptime, duration: Self.leaseSeconds)
                Self.restorePending = false
                Self.log.info("setFansPercent \(percent, privacy: .public) OK")
                reply(nil)
            } catch let error as NSError {
                try? Self.restoreAutoLocked()
                Self.log.error("setFansPercent failed: \(error.localizedDescription, privacy: .public)")
                reply(error)
            } catch {
                try? Self.restoreAutoLocked()
                Self.log.error("setFansPercent failed: \(String(describing: error), privacy: .public)")
                reply(CoolDownXPCError.smcFailed.nsError)
            }
        }
    }

    func setFanRPM(index: Int, rpm: Double, reply: @escaping (NSError?) -> Void) {
        let clientID = self.clientID
        Self.queue.async {
            guard (0..<8).contains(index), rpm.isFinite, rpm >= 300, rpm <= 12000 else {
                Self.log.error("setFanRPM rejected bad args index=\(index) rpm=\(rpm, privacy: .public)")
                reply(NSError(domain: "com.cooldown.CoolDownPro.XPC", code: CoolDownXPCError.smcFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "Invalid fan RPM"]))
                return
            }
            do {
                _ = Self.watchdog
                Self.restorePending = true
                try Self.withSMC { try $0.setFanRPM(index: index, rpm: rpm) }
                Self.lease.acquire(clientID: clientID, now: ProcessInfo.processInfo.systemUptime, duration: Self.leaseSeconds)
                Self.restorePending = false
                Self.log.info("setFanRPM index=\(index) rpm=\(rpm, privacy: .public) OK")
                reply(nil)
            } catch let error as NSError {
                try? Self.restoreAutoLocked()
                Self.log.error("setFanRPM failed: \(error.localizedDescription, privacy: .public)")
                reply(error)
            } catch {
                try? Self.restoreAutoLocked()
                Self.log.error("setFanRPM failed: \(String(describing: error), privacy: .public)")
                reply(CoolDownXPCError.smcFailed.nsError)
            }
        }
    }

    func renewFanControlLease(reply: @escaping (NSError?) -> Void) {
        let clientID = self.clientID
        Self.queue.async {
            guard !Self.restorePending else {
                reply(CoolDownXPCError.smcFailed.nsError)
                return
            }
            // Do not revive an expired lease even if its timer has not fired yet.
            let now = ProcessInfo.processInfo.systemUptime
            guard Self.lease.renew(clientID: clientID, now: now, duration: Self.leaseSeconds) else {
                if Self.lease.isOwned(by: clientID), Self.lease.hasExpired(now: now) {
                    try? Self.restoreAutoLocked()
                }
                reply(CoolDownXPCError.smcFailed.nsError)
                return
            }
            reply(nil)
        }
    }
}
