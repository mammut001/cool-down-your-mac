import Foundation
import CoolDownKit

/// Best-effort unprivileged SMC access for UI (and local write fallback when helper SMC fails).
/// Prefer the privileged helper for production fan writes.
enum DirectSMCReader {
    private final class SnapshotCache: @unchecked Sendable {
        let lock = NSLock()
        var snapshot: SensorSnapshot?
        var refreshedAtUptime: TimeInterval = 0
    }

    private static let cache = SnapshotCache()
    #if arch(x86_64)
    private static let cacheLifetimeSeconds: TimeInterval = 4
    #else
    private static let cacheLifetimeSeconds: TimeInterval = 2
    #endif

    static func readSnapshot() -> SensorSnapshot? {
        let now = ProcessInfo.processInfo.systemUptime

        cache.lock.lock()
        let cached = cache.snapshot
        let isFresh = cached != nil && now - cache.refreshedAtUptime < cacheLifetimeSeconds
        cache.lock.unlock()
        if isFresh {
            return cached
        }

        do {
            let kit = try SMCKit(allowKeysEndpointFallback: true)
            let fans = try kit.readFans().map {
                FanInfo(
                    index: $0.index,
                    name: $0.name,
                    minRPM: $0.minRPM,
                    maxRPM: $0.maxRPM,
                    currentRPM: $0.currentRPM,
                    targetRPM: $0.targetRPM,
                    isManual: $0.isManual
                )
            }
            let temps = kit.readTemperatures().map {
                TemperatureReading(key: $0.key, name: $0.name, celsius: $0.celsius)
            }
            let snapshot = SensorSnapshot(
                fans: fans,
                temperatures: temps,
                canControlFans: kit.canControlFans,
                helperAvailable: false
            )
            cache.lock.lock()
            cache.snapshot = snapshot
            cache.refreshedAtUptime = now
            cache.lock.unlock()
            return snapshot
        } catch {
            // A transient SMC read should not blank the UI. A slightly stale
            // snapshot is preferable and the next cache expiry will retry.
            return cached
        }
    }

    private static func invalidateCache() {
        cache.lock.lock()
        cache.refreshedAtUptime = 0
        cache.lock.unlock()
    }

    @discardableResult
    static func setFansAuto() -> Bool {
        do {
            try SMCKit(allowKeysEndpointFallback: false).setAllFansAuto()
            invalidateCache()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func setFansPercent(_ percent: Double) -> Bool {
        do {
            try SMCKit(allowKeysEndpointFallback: false).setAllFansPercent(percent)
            invalidateCache()
            return true
        } catch {
            return false
        }
    }
}
