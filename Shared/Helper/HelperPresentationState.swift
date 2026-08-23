import Foundation

public enum HelperPresentationState: String, Equatable, Sendable {
    case checking = "Checking…"
    case notInstalled = "Not installed"
    case connecting = "Connecting…"
    case enabled = "Enabled"
    case needsRepair = "Needs repair"
    case unavailable = "Unavailable on this Mac"
}

public enum HelperPresentationResolver {
    public static func resolve(
        hasCompletedInitialProbe: Bool,
        isRegistered: Bool,
        isConnected: Bool,
        snapshotHelperAvailable: Bool,
        canControlFans: Bool,
        hasFans: Bool,
        helperLaunchFailed: Bool
    ) -> HelperPresentationState {
        let controlReady = isConnected && snapshotHelperAvailable && canControlFans && hasFans
        if controlReady {
            return .enabled
        }
        if !hasCompletedInitialProbe {
            return isRegistered ? .connecting : .checking
        }
        if !isRegistered {
            return .notInstalled
        }
        if helperLaunchFailed {
            return .needsRepair
        }
        let fanControlUnavailable = isConnected && snapshotHelperAvailable && (!canControlFans || !hasFans)
        if fanControlUnavailable {
            return .unavailable
        }
        return .connecting
    }
}
