import XCTest

final class HelperServiceFaultTests: XCTestCase {
    override func tearDown() {
        HelperService.resetForTests()
        super.tearDown()
    }

    func testDisconnectBeforeQueuedManualCommandRejectsIt() {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) })
        let client = HelperService()

        client.clientGone()
        XCTAssertNotNil(setPercent(client, 0.5))
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
    }

    func testOldDisconnectCannotRestoreNewClientsManualCommand() {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) })
        let oldClient = HelperService()
        let newClient = HelperService()

        XCTAssertNil(setPercent(oldClient, 0.4))
        XCTAssertNil(setPercent(newClient, 0.5))
        oldClient.clientGone()
        HelperService.drainForTests()
        XCTAssertEqual(device.mode(0), 1)
        XCTAssertEqual(device.mode(1), 1)

        newClient.clientGone()
        HelperService.drainForTests()
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
    }

    func testDisconnectedClientsLateAutoCannotOverrideNewOwner() {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) })
        let oldClient = HelperService()
        let newClient = HelperService()

        oldClient.clientGone()
        XCTAssertNil(setPercent(newClient, 0.5))
        XCTAssertNotNil(setAuto(oldClient))
        XCTAssertEqual(device.mode(0), 1)
        XCTAssertEqual(device.mode(1), 1)
    }

    func testLeaseExpiryWatchdogRestoresBothFans() {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) }, uptime: 100)
        let client = HelperService()

        XCTAssertNil(setPercent(client, 0.5))
        HelperService.setUptimeForTests(146)
        HelperService.watchdogTickForTests()
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
    }

    func testFailedAutoRestoreIsRetriedByWatchdog() {
        let device = FakeSMC()
        device.setMode(0, 1)
        device.setMode(1, 1)
        device.failedAutoWrites["F1md"] = 2 // Initial attempt and reopened SMC retry.
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) })
        let client = HelperService()

        XCTAssertNotNil(setAuto(client))
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 1)
        XCTAssertEqual(device.target(1), 5000, accuracy: 1)

        HelperService.watchdogTickForTests()
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
    }

    func testSIGTERMRestoreUsesSameSerialQueue() throws {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) })
        let client = HelperService()

        XCTAssertNil(setPercent(client, 0.5))
        try HelperService.restoreFansBeforeExit()
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
    }

    private func setPercent(_ client: HelperService, _ percent: Double) -> NSError? {
        let done = DispatchSemaphore(value: 0)
        var result: NSError?
        client.setFansPercent(percent) { error in
            result = error
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 4), .success)
        return result
    }

    private func setAuto(_ client: HelperService) -> NSError? {
        let done = DispatchSemaphore(value: 0)
        var result: NSError?
        client.setFansAuto { error in
            result = error
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 4), .success)
        return result
    }
}
