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

    func testUnsignedAppExplainsWhyHelperCannotBeRepaired() {
        let state = HelperPresentationResolver.resolve(
            hasCompletedInitialProbe: true,
            isRegistered: true,
            isConnected: false,
            snapshotHelperAvailable: false,
            canControlFans: false,
            hasFans: false,
            helperLaunchFailed: true,
            appSigningValid: false
        )
        XCTAssertEqual(state, .invalidAppSignature)
        XCTAssertEqual(state.rawValue, "App build not signed")
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

    func testSetupPromptNotPresentedWhenProbeIncomplete() {
        let shouldPresent = InitialHelperSetupResolver.shouldPresent(
            probeCompleted: false,
            isRegistered: false,
            alreadyShown: false
        )
        XCTAssertFalse(shouldPresent)
    }

    func testSetupPromptPresentedWhenProbeCompletesAndHelperAbsent() {
        let shouldPresent = InitialHelperSetupResolver.shouldPresent(
            probeCompleted: true,
            isRegistered: false,
            alreadyShown: false
        )
        XCTAssertTrue(shouldPresent)
    }

    func testSetupPromptNotPresentedWhenHelperAlreadyInstalled() {
        let shouldPresent = InitialHelperSetupResolver.shouldPresent(
            probeCompleted: true,
            isRegistered: true,
            alreadyShown: false
        )
        XCTAssertFalse(shouldPresent)
    }

    func testSetupPromptNotPresentedWhenAlreadyShown() {
        let shouldPresent = InitialHelperSetupResolver.shouldPresent(
            probeCompleted: true,
            isRegistered: false,
            alreadyShown: true
        )
        XCTAssertFalse(shouldPresent)
    }

    func testSlowProbeStillPresentsSetupWhenItEventuallyCompletes() {
        // Step 1: During slow probe (e.g. >1.2s), probeCompleted is false
        let duringProbe = InitialHelperSetupResolver.shouldPresent(
            probeCompleted: false,
            isRegistered: false,
            alreadyShown: false
        )
        XCTAssertFalse(duringProbe)

        // Step 2: Once probe finishes, evaluation succeeds without loss
        let afterSlowProbe = InitialHelperSetupResolver.shouldPresent(
            probeCompleted: true,
            isRegistered: false,
            alreadyShown: false
        )
        XCTAssertTrue(afterSlowProbe)
    }
}
