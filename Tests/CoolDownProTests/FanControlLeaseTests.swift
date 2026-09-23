import XCTest

final class FanControlLeaseTests: XCTestCase {
    func testStalledClientExpiresAndCannotRenewAfterDeadline() {
        let client = UUID()
        var lease = FanControlLease()
        lease.acquire(clientID: client, now: 100, duration: 45)

        XCTAssertFalse(lease.hasExpired(now: 144.9))
        XCTAssertTrue(lease.hasExpired(now: 145))
        XCTAssertFalse(lease.renew(clientID: client, now: 145, duration: 45))
    }

    func testOnlyCurrentControllingConnectionCanRenew() {
        let oldClient = UUID()
        let newClient = UUID()
        var lease = FanControlLease()
        lease.acquire(clientID: oldClient, now: 100, duration: 45)
        lease.acquire(clientID: newClient, now: 110, duration: 45)

        XCTAssertFalse(lease.isOwned(by: oldClient))
        XCTAssertFalse(lease.renew(clientID: oldClient, now: 120, duration: 45))
        XCTAssertTrue(lease.renew(clientID: newClient, now: 120, duration: 45))
        XCTAssertFalse(lease.hasExpired(now: 155))
        XCTAssertTrue(lease.hasExpired(now: 165))
    }

    func testRestoringAutoRevokesLease() {
        let client = UUID()
        var lease = FanControlLease()
        lease.acquire(clientID: client, now: 100, duration: 45)
        lease.clear()

        XCTAssertFalse(lease.isOwned(by: client))
        XCTAssertFalse(lease.renew(clientID: client, now: 110, duration: 45))
        XCTAssertFalse(lease.hasExpired(now: 1000))
    }

    func testOldHelperSnapshotCannotClaimLeaseSupport() throws {
        let oldPayload = Data(#"{"fans":[],"temperatures":[],"canControlFans":true}"#.utf8)
        let old = try JSONDecoder().decode(XPCSnapshotDTO.self, from: oldPayload)
        XCTAssertFalse(old.supportsFanLease)

        let currentPayload = try JSONEncoder().encode(
            XPCSnapshotDTO(fans: [], temperatures: [], canControlFans: true)
        )
        let current = try JSONDecoder().decode(XPCSnapshotDTO.self, from: currentPayload)
        XCTAssertTrue(current.supportsFanLease)
    }
}
