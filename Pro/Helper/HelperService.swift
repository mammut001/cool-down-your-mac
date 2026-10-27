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
        timer.setEventHandler { HelperService.watchdogTickLocked() }
        timer.resume()
        return timer
    }()
    /// Owners whose lease expired while their connection was still open. A
    /// live app that does not renew is either stalled or too old to know the
    /// lease; both must not reacquire manual control on their next command,
    /// or the fans cycle auto/manual every 45 s. Cleared when the connection
    /// goes away, so a reconnect (new `HelperService`) starts clean.
    private static var nonRenewingClients: Set<UUID> = []
    /// Cool Down Pro 1.0.20 (build 31) was the first app to renew the lease.
    static let minimumLeaseClientBuild = 31
    private let clientID = UUID()
    private let clientBuild: Int?
    // Only access on the shared helper queue. A disconnect may be queued before
    // an already-delivered fan command; that late command must be rejected.
    private var clientIsGone = false
    private var loggedOutdatedClient = false
    private static let log = Logger(subsystem: "com.cooldown.CoolDownPro.PrivilegedHelper", category: "SMC")

    /// `clientBuild` is the connected app's `CFBundleVersion` read from its
    /// signature by `HelperDelegate`; tests default to a lease-capable build.
    init(clientBuild: Int? = HelperService.minimumLeaseClientBuild) {
        self.clientBuild = clientBuild
        super.init()
    }

    static func buildNumber(fromBundleVersion value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let string = value as? String else { return nil }
        // "32" or "32.1": the leading integer is the build.
        let head = string.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return Int(head.trimmingCharacters(in: .whitespaces))
    }

    private var clientRenewsLeases: Bool {
        guard let clientBuild else { return false }
        return clientBuild >= Self.minimumLeaseClientBuild
    }

    /// Manual commands need a client that will keep the lease alive. Returns
    /// the error to reply with, or nil when the command may proceed.
    private func manualCommandRefusal() -> NSError? {
        if clientIsGone { return CoolDownXPCError.helperUnavailable.nsError }
        guard clientRenewsLeases else {
            if !loggedOutdatedClient {
                loggedOutdatedClient = true
                Self.log.error("manual fan command refused: client build \(self.clientBuild.map(String.init) ?? "unknown", privacy: .public) predates lease renewal (needs \(Self.minimumLeaseClientBuild)); fans stay in system auto")
            }
            return CoolDownXPCError.clientOutdated.nsError
        }
        if Self.nonRenewingClients.contains(clientID) {
            return CoolDownXPCError.leaseNotRenewed.nsError
        }
        return nil
    }

    #if DEBUG
    private static var testOpenSMC: (() throws -> SMCKit)?
    private static var testUptime: TimeInterval?

    static func configureForTests(openSMC: @escaping () throws -> SMCKit, uptime: TimeInterval = 100) {
        queue.sync {
            smc = nil
            lease.clear()
            nonRenewingClients.removeAll()
            restorePending = false
            testOpenSMC = openSMC
            testUptime = uptime
        }
    }

    static func setUptimeForTests(_ uptime: TimeInterval) {
        queue.sync { testUptime = uptime }
    }

    static func watchdogTickForTests() {
        queue.sync { watchdogTickLocked() }
    }

    static func drainForTests() {
        queue.sync {}
    }

    static func resetForTests() {
        queue.sync {
            smc = nil
            lease.clear()
            nonRenewingClients.removeAll()
            restorePending = false
            testOpenSMC = nil
            testUptime = nil
        }
    }
    #endif

    private static var uptime: TimeInterval {
        #if DEBUG
        if let testUptime { return testUptime }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    private static func watchdogTickLocked() {
        let expired = lease.hasExpired(now: uptime)
        if expired, let owner = lease.owner, !nonRenewingClients.contains(owner) {
            // The owner's disconnect would already have cleared this lease, so
            // its connection is still open: a stalled or lease-unaware app.
            nonRenewingClients.insert(owner)
            log.fault("fan lease expired while the controlling app stayed connected; its manual commands are refused until it reconnects")
        }
        guard restorePending || expired else { return }
        do {
            try restoreAutoLocked()
            log.info("fan lease expired or restore retried — system auto restored")
        } catch {
            log.error("fan lease restore failed; retrying: \(String(describing: error), privacy: .public)")
        }
    }

    /// Leases live only in this process. After a crash, kill or upgrade,
    /// launchd starts a helper that owns no lease, so no client can be
    /// relying on a manual fan: return any manual fan to system auto and arm
    /// the watchdog so a failed restore is retried.
    static func reconcileAfterLaunch() {
        queue.async {
            _ = watchdog
            let manualFans = try? withSMC { try $0.readFans().filter(\.isManual).count }
            guard manualFans != 0 else { return }
            do {
                try restoreAutoLocked()
                log.info("helper launch found manual fans without a lease — system auto restored")
            } catch {
                log.error("helper launch restore failed; retrying: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func clientGone() {
        let clientID = self.clientID
        Self.queue.async { [self] in
            clientIsGone = true
            Self.nonRenewingClients.remove(clientID)
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
        try SMCConnectionRecovery.run(
            cached: &smc,
            open: {
                #if DEBUG
                if let testOpenSMC = Self.testOpenSMC { return try testOpenSMC() }
                #endif
                do {
                    let kit = try SMCKit(allowKeysEndpointFallback: false)
                    Self.log.info("SMC open OK")
                    return kit
                } catch {
                    Self.log.error("SMC open failed: \(String(describing: error), privacy: .public)")
                    throw error
                }
            },
            onReopen: {
                Self.log.info("SMC reopened after I/O failure")
            },
            operation: body
        )
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
        Self.queue.async { [self] in
            guard !clientIsGone else {
                reply(CoolDownXPCError.helperUnavailable.nsError)
                return
            }
            _ = Self.watchdog
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
        Self.queue.async { [self] in
            if let refusal = manualCommandRefusal() {
                reply(refusal)
                return
            }
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
                Self.lease.acquire(clientID: clientID, now: Self.uptime, duration: Self.leaseSeconds)
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
        Self.queue.async { [self] in
            if let refusal = manualCommandRefusal() {
                reply(refusal)
                return
            }
            guard (0..<8).contains(index), rpm.isFinite, rpm >= 300, rpm <= 12000 else {
                Self.log.error("setFanRPM rejected bad args index=\(index) rpm=\(rpm, privacy: .public)")
                reply(NSError(domain: "com.cooldown.CoolDownPro.XPC", code: CoolDownXPCError.smcFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "Invalid fan RPM"]))
                return
            }
            do {
                _ = Self.watchdog
                Self.restorePending = true
                try Self.withSMC { try $0.setFanRPM(index: index, rpm: rpm) }
                Self.lease.acquire(clientID: clientID, now: Self.uptime, duration: Self.leaseSeconds)
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
        Self.queue.async { [self] in
            guard !clientIsGone else {
                reply(CoolDownXPCError.helperUnavailable.nsError)
                return
            }
            guard !Self.restorePending else {
                reply(CoolDownXPCError.smcFailed.nsError)
                return
            }
            // Do not revive an expired lease even if its timer has not fired yet.
            let now = Self.uptime
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
