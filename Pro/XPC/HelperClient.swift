import Foundation
import ServiceManagement
import Security
import CoolDownKit

@MainActor
public final class HelperClient: ObservableObject {
    public static let shared = HelperClient()

    @Published public private(set) var isConnected = false
    @Published public private(set) var lastError: String?

    private var connection: NSXPCConnection?
    /// Incremented whenever the live connection is discarded so stale
    /// invalidation handlers cannot clear a newer session.
    private var connectionEpoch = 0

    private init() {}

    public var isHelperInstalled: Bool {
        FileManager.default.isExecutableFile(
            atPath: "/Library/PrivilegedHelperTools/\(coolDownHelperMachServiceName)"
        )
    }

    /// Installs the helper for the first time, or replaces it after an explicit
    /// repair request. The guard is important: acquiring the SMJobBless right
    /// always presents macOS's administrator dialog, even when the existing
    /// helper is healthy.
    public func installHelper(replacingExisting: Bool = false) throws {
        if isHelperInstalled && !replacingExisting {
            reconnect()
            return
        }

        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization else {
            throw CoolDownXPCError.helperUnavailable.nsError
        }
        defer { AuthorizationFree(authorization, []) }

        var item = AuthorizationItem(
            name: kSMRightBlessPrivilegedHelper,
            valueLength: 0,
            value: nil,
            flags: 0
        )
        var rights = AuthorizationRights(count: 1, items: &item)
        let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
        guard AuthorizationCopyRights(authorization, &rights, nil, flags, nil) == errAuthorizationSuccess else {
            throw CoolDownXPCError.helperUnavailable.nsError
        }

        var blessingError: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, coolDownHelperMachServiceName as CFString, authorization, &blessingError) else {
            throw (blessingError?.takeRetainedValue() as Error?) ?? CoolDownXPCError.helperUnavailable.nsError
        }
        reconnect()
    }

    public func disconnect() {
        dropConnection()
    }

    public func reconnect() {
        dropConnection()
        let conn = NSXPCConnection(machServiceName: coolDownHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: CoolDownHelperProtocol.self)
        if #available(macOS 13.0, *) {
            try? conn.setCodeSigningRequirement(Self.helperPeerRequirement)
        }
        connectionEpoch += 1
        let epoch = connectionEpoch
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.handleConnectionLoss(epoch: epoch)
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.handleConnectionLoss(epoch: epoch)
            }
        }
        conn.resume()
        connection = conn
        ping()
    }

    public func ping() {
        guard let proxy = proxy(onError: { [weak self] _ in
            self?.isConnected = false
        }) else {
            isConnected = false
            return
        }
        proxy.ping { [weak self] ok in
            Task { @MainActor in
                self?.isConnected = ok
            }
        }
    }

    public func fetchSnapshot() async throws -> SensorSnapshot {
        let data: Data = try await invoke { proxy, finish in
            proxy.fetchSnapshot { data, error in
                if let error {
                    finish(.failure(error))
                } else if let data {
                    finish(.success(data))
                } else {
                    finish(.failure(CoolDownXPCError.encodeFailed.nsError))
                }
            }
        }
        let dto = try JSONDecoder().decode(XPCSnapshotDTO.self, from: data)
        isConnected = true
        return SensorSnapshot(
            fans: dto.fans.map {
                FanInfo(
                    index: $0.index,
                    name: $0.name,
                    minRPM: $0.minRPM,
                    maxRPM: $0.maxRPM,
                    currentRPM: $0.currentRPM,
                    targetRPM: $0.targetRPM,
                    isManual: $0.isManual
                )
            },
            temperatures: dto.temperatures.map {
                TemperatureReading(key: $0.key, name: $0.name, celsius: $0.celsius)
            },
            canControlFans: dto.canControlFans,
            helperAvailable: true
        )
    }

    public func setFansAuto() async throws {
        try await invoke { (proxy: CoolDownHelperProtocol, finish: @escaping (Result<Void, Error>) -> Void) in
            proxy.setFansAuto { error in
                if let error { finish(.failure(error)) }
                else { finish(.success(())) }
            }
        }
    }

    public func setFansPercent(_ percent: Double) async throws {
        try await invoke { (proxy: CoolDownHelperProtocol, finish: @escaping (Result<Void, Error>) -> Void) in
            proxy.setFansPercent(percent) { error in
                if let error { finish(.failure(error)) }
                else { finish(.success(())) }
            }
        }
    }

    public func setFanRPM(index: Int, rpm: Double) async throws {
        try await invoke { (proxy: CoolDownHelperProtocol, finish: @escaping (Result<Void, Error>) -> Void) in
            proxy.setFanRPM(index: index, rpm: rpm) { error in
                if let error { finish(.failure(error)) }
                else { finish(.success(())) }
            }
        }
    }

    /// Blocking auto-restore for `applicationWillTerminate`. Must not hop to
    /// the main actor — the terminate callback already owns that thread.
    nonisolated public static func setFansAutoBlocking(timeout: TimeInterval = 1.0) {
        let conn = NSXPCConnection(machServiceName: coolDownHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: CoolDownHelperProtocol.self)
        if #available(macOS 13.0, *) {
            try? conn.setCodeSigningRequirement(helperPeerRequirement)
        }
        conn.resume()
        defer { conn.invalidate() }

        let sema = DispatchSemaphore(value: 0)
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
            sema.signal()
        } as? CoolDownHelperProtocol
        proxy?.setFansAuto { _ in
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + timeout)
    }

    private func invoke<T>(
        _ body: (CoolDownHelperProtocol, @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func finish(_ result: Result<T, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            guard let proxy = proxy(onError: { error in
                finish(.failure(error))
            }) else {
                finish(.failure(CoolDownXPCError.helperUnavailable.nsError))
                return
            }
            body(proxy, finish)
        }
    }

    private func proxy(onError: @escaping (Error) -> Void) -> CoolDownHelperProtocol? {
        if connection == nil { reconnect() }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
                self?.handleConnectionLoss(epoch: self?.connectionEpoch ?? 0)
                onError(error)
            }
        } as? CoolDownHelperProtocol
    }

    private func handleConnectionLoss(epoch: Int) {
        guard epoch == connectionEpoch else { return }
        dropConnection()
    }

    private func dropConnection() {
        let existing = connection
        connection = nil
        isConnected = false
        existing?.invalidationHandler = nil
        existing?.interruptionHandler = nil
        existing?.invalidate()
    }

    private static let helperPeerRequirement =
        "identifier \"com.cooldown.CoolDownPro.PrivilegedHelper\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = Z5D5N7CU6L"
}
