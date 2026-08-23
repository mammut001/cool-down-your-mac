import XCTest
@testable import CoolDownKit

final class HelperPresentationTests: XCTestCase {
    func testInitialProbeIncompleteWhenUnregisteredResolvesToChecking() {
        let state = HelperPresentationResolver.resolve(
            hasCompletedInitialProbe: false,
            isRegistered: false,
            isConnected: false,
            snapshotHelperAvailable: false,
            canControlFans: false,
            hasFans: false,
            helperLaunchFailed: false
        )
        XCTAssertEqual(state, .checking)
        XCTAssertEqual(state.rawValue, "Checking…")
    }

    func testInitialProbeIncompleteWhenRegisteredResolvesToConnectingNotNotInstalled() {
        let state = HelperPresentationResolver.resolve(
            hasCompletedInitialProbe: false,
            isRegistered: true,
            isConnected: false,
            snapshotHelperAvailable: false,
            canControlFans: false,
            hasFans: false,
            helperLaunchFailed: false
        )
        XCTAssertEqual(state, .connecting)
        XCTAssertEqual(state.rawValue, "Connecting…")
        XCTAssertNotEqual(state, .notInstalled)
    }

    func testProbeCompleteWhenNotRegisteredResolvesToNotInstalled() {
        let state = HelperPresentationResolver.resolve(
            hasCompletedInitialProbe: true,
            isRegistered: false,
            isConnected: false,
            snapshotHelperAvailable: false,
            canControlFans: false,
            hasFans: false,
            helperLaunchFailed: false
        )
        XCTAssertEqual(state, .notInstalled)
        XCTAssertEqual(state.rawValue, "Not installed")
    }

    func testProbeCompleteWhenRegisteredAndConnecting() {
        let state = HelperPresentationResolver.resolve(
            hasCompletedInitialProbe: true,
            isRegistered: true,
            isConnected: false,
            snapshotHelperAvailable: false,
            canControlFans: false,
            hasFans: false,
            helperLaunchFailed: false
        )
        XCTAssertEqual(state, .connecting)
        XCTAssertEqual(state.rawValue, "Connecting…")
    }

    func testReadyWhenConnectedWithControllableFans() {
        let state = HelperPresentationResolver.resolve(
            hasCompletedInitialProbe: true,
            isRegistered: true,
            isConnected: true,
            snapshotHelperAvailable: true,
            canControlFans: true,
            hasFans: true,
            helperLaunchFailed: false
        )
        XCTAssertEqual(state, .enabled)
        XCTAssertEqual(state.rawValue, "Enabled")
    }

    func testNeedsRepairWhenHelperLaunchFailed() {
        let state = HelperPresentationResolver.resolve(
            hasCompletedInitialProbe: true,
            isRegistered: true,
            isConnected: false,
            snapshotHelperAvailable: false,
            canControlFans: false,
            hasFans: false,
            helperLaunchFailed: true
        )
        XCTAssertEqual(state, .needsRepair)
        XCTAssertEqual(state.rawValue, "Needs repair")
    }

    func testUnavailableWhenConnectedWithoutControllableFans() {
        let state = HelperPresentationResolver.resolve(
            hasCompletedInitialProbe: true,
            isRegistered: true,
            isConnected: true,
            snapshotHelperAvailable: true,
            canControlFans: false,
            hasFans: false,
            helperLaunchFailed: false
        )
        XCTAssertEqual(state, .unavailable)
        XCTAssertEqual(state.rawValue, "Unavailable on this Mac")
    }
}
