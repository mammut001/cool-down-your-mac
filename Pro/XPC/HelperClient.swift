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

    private init() {}

    public var helperStatus: SMAppService.Status {
        FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/\(coolDownHelperMachServiceName)")
            ? .enabled : .notRegistered
    }

    public func installHelper() throws {
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

    public func uninstallHelper() throws {
        // SMJobBless replaces an installed tool atomically, so callers can
        // repair or upgrade it by blessing again without a second prompt.
        connection?.invalidate()
        connection = nil
        isConnected = false
    }

    public func reconnect() {
        connection?.invalidate()
        let conn = NSXPCConnection(machServiceName: coolDownHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: CoolDownHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
            }
        }
        conn.resume()
        connection = conn
        ping()
    }

    public func ping() {
        guard let proxy = proxy() else {
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
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            guard let proxy = proxy() else {
                continuation.resume(throwing: CoolDownXPCError.helperUnavailable.nsError)
                return
            }
            proxy.fetchSnapshot { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CoolDownXPCError.encodeFailed.nsError)
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let proxy = proxy() else {
                continuation.resume(throwing: CoolDownXPCError.helperUnavailable.nsError)
                return
            }
            proxy.setFansAuto { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    public func setFansPercent(_ percent: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let proxy = proxy() else {
                continuation.resume(throwing: CoolDownXPCError.helperUnavailable.nsError)
                return
            }
            proxy.setFansPercent(percent) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    public func setFanRPM(index: Int, rpm: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let proxy = proxy() else {
                continuation.resume(throwing: CoolDownXPCError.helperUnavailable.nsError)
                return
            }
            proxy.setFanRPM(index: index, rpm: rpm) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func proxy() -> CoolDownHelperProtocol? {
        if connection == nil { reconnect() }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
                self?.isConnected = false
            }
        } as? CoolDownHelperProtocol
    }
}
