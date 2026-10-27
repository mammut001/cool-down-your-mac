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

    // Observed on an M5 Pro: a 1.0.18 app driving a lease-capable helper. The
    // app never renewed, the lease expired 45 s after each write, the helper
    // restored auto (fans off at 63 °C), and the next curve change rewrote
    // manual. Neither side may restart that cycle.
    func testLeaseUnawareClientCannotTakeManualControl() {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) })
        let oldApp = HelperService(clientBuild: 29) // Cool Down Pro 1.0.18
        let unknownApp = HelperService(clientBuild: nil)

        XCTAssertEqual(setPercent(oldApp, 0.5).flatMap(CoolDownXPCError.code(of:)), .clientOutdated)
        XCTAssertEqual(setRPM(oldApp, 3000).flatMap(CoolDownXPCError.code(of:)), .clientOutdated)
        XCTAssertEqual(setPercent(unknownApp, 0.5).flatMap(CoolDownXPCError.code(of:)), .clientOutdated)
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
        XCTAssertNil(setAuto(oldApp), "auto is always allowed")

        let currentApp = HelperService(clientBuild: HelperService.minimumLeaseClientBuild)
        XCTAssertNil(setPercent(currentApp, 0.5))
        XCTAssertEqual(device.mode(0), 1)
    }

    func testClientWhoseLeaseExpiredWhileConnectedCannotRestartTheCycle() {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) }, uptime: 100)
        let client = HelperService()

        XCTAssertNil(setPercent(client, 0.5))
        HelperService.setUptimeForTests(146)
        HelperService.watchdogTickForTests()
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)

        // Still connected, silent for 45 s: a new target must not go manual.
        XCTAssertEqual(setPercent(client, 0.55).flatMap(CoolDownXPCError.code(of:)), .leaseNotRenewed)
        XCTAssertEqual(setRPM(client, 3000).flatMap(CoolDownXPCError.code(of:)), .leaseNotRenewed)
        XCTAssertNotNil(renew(client))
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
        XCTAssertNil(setAuto(client))

        // Only a fresh connection (the app reconnected) may take control again.
        client.clientGone()
        let reconnected = HelperService()
        XCTAssertNil(setPercent(reconnected, 0.55))
        XCTAssertEqual(device.mode(0), 1)
        XCTAssertEqual(device.mode(1), 1)
    }

    func testRenewingClientKeepsManualControlAcrossLeasePeriods() {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) }, uptime: 100)
        let client = HelperService()

        XCTAssertNil(setPercent(client, 0.5))
        for uptime in stride(from: 120.0, through: 400.0, by: 20.0) {
            HelperService.setUptimeForTests(uptime)
            HelperService.watchdogTickForTests()
            XCTAssertNil(renew(client), "renewal at \(uptime)")
            XCTAssertEqual(device.mode(0), 1, "manual at \(uptime)")
            XCTAssertEqual(device.mode(1), 1, "manual at \(uptime)")
        }
        XCTAssertNil(setPercent(client, 0.6), "a renewing client is never refused")
    }

    func testClientBuildNumberParsing() {
        XCTAssertEqual(HelperService.buildNumber(fromBundleVersion: "32"), 32)
        XCTAssertEqual(HelperService.buildNumber(fromBundleVersion: " 31 "), 31)
        XCTAssertEqual(HelperService.buildNumber(fromBundleVersion: "32.1"), 32)
        XCTAssertEqual(HelperService.buildNumber(fromBundleVersion: NSNumber(value: 31)), 31)
        XCTAssertNil(HelperService.buildNumber(fromBundleVersion: nil))
        XCTAssertNil(HelperService.buildNumber(fromBundleVersion: "dev"))
        XCTAssertNil(HelperService.buildNumber(fromBundleVersion: ""))
    }

    private func renew(_ client: HelperService) -> NSError? {
        let done = DispatchSemaphore(value: 0)
        var result: NSError?
        client.renewFanControlLease { error in
            result = error
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 4), .success)
        return result
    }

    private func setRPM(_ client: HelperService, _ rpm: Double) -> NSError? {
        let done = DispatchSemaphore(value: 0)
        var result: NSError?
        client.setFanRPM(index: 0, rpm: rpm) { error in
            result = error
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 4), .success)
        return result
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
