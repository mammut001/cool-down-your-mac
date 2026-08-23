import XCTest
import CoolDownKit

final class UpdateFormattingTests: XCTestCase {
    func testVersionStringFormatting() {
        XCTAssertEqual(UpdateFormatting.versionString(marketing: "1.0.8", build: "18"), "1.0.8 (18)")
        XCTAssertEqual(UpdateFormatting.versionString(marketing: "1.0.8", build: "1.0.8"), "1.0.8")
        XCTAssertEqual(UpdateFormatting.versionString(marketing: "1.0.8", build: ""), "1.0.8")
        XCTAssertEqual(UpdateFormatting.versionString(marketing: "1.0.8", build: nil), "1.0.8")
        XCTAssertEqual(UpdateFormatting.versionString(marketing: nil, build: "18"), "—")
        XCTAssertEqual(UpdateFormatting.versionString(marketing: "", build: "18"), "—")
    }

    func testLastCheckDescription() {
        XCTAssertEqual(UpdateFormatting.lastCheckDescription(date: nil), "Never checked")
        
        let now = Date()
        XCTAssertEqual(UpdateFormatting.lastCheckDescription(date: now.addingTimeInterval(-10), now: now), "Just now")
        XCTAssertEqual(UpdateFormatting.lastCheckDescription(date: now.addingTimeInterval(-120), now: now), "2m ago")
        XCTAssertEqual(UpdateFormatting.lastCheckDescription(date: now.addingTimeInterval(-7200), now: now), "2h ago")
        
        let olderDate = now.addingTimeInterval(-100000)
        let formatted = UpdateFormatting.lastCheckDescription(date: olderDate, now: now)
        XCTAssertFalse(formatted.isEmpty)
        XCTAssertNotEqual(formatted, "Never checked")
    }
}
