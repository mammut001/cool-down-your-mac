import XCTest

final class SMCConnectionRecoveryTests: XCTestCase {
    private struct Connection { let id: Int }
    private enum Failure: Error { case io, open }

    func testIOFailureReopensInsteadOfReturningCachedResult() throws {
        var cached: Connection?
        var opens = 0
        var attempts: [Int] = []
        let open = { () -> Connection in
            opens += 1
            return Connection(id: opens)
        }
        let operation = { (connection: Connection) throws -> Int in
            attempts.append(connection.id)
            if connection.id == 1 { throw Failure.io }
            return connection.id
        }

        let result = try SMCConnectionRecovery.run(cached: &cached, open: open, operation: operation)
        XCTAssertEqual(result, 2)
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertEqual(cached?.id, 2)

        XCTAssertEqual(try SMCConnectionRecovery.run(cached: &cached, open: open, operation: operation), 2)
        XCTAssertEqual(opens, 2)
    }

    func testSecondIOFailureDropsReopenedConnection() {
        var cached: Connection?
        var opens = 0

        XCTAssertThrowsError(try SMCConnectionRecovery.run(
            cached: &cached,
            open: { opens += 1; return Connection(id: opens) },
            operation: { (_: Connection) throws -> Int in throw Failure.io }
        ))
        XCTAssertEqual(opens, 2)
        XCTAssertNil(cached)
    }

    func testOpenFailureLeavesNoCachedConnection() {
        var cached: Connection?

        XCTAssertThrowsError(try SMCConnectionRecovery.run(
            cached: &cached,
            open: { throw Failure.open },
            operation: { (_: Connection) -> Int in 1 }
        ))
        XCTAssertNil(cached)
    }

    func testReopenFailureDropsFailedCachedConnection() {
        var cached: Connection? = Connection(id: 1)
        var opens = 0

        XCTAssertThrowsError(try SMCConnectionRecovery.run(
            cached: &cached,
            open: { opens += 1; throw Failure.open },
            operation: { (_: Connection) throws -> Int in throw Failure.io }
        ))
        XCTAssertEqual(opens, 1)
        XCTAssertNil(cached)
    }
}
