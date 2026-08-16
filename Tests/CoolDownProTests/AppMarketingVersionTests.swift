import XCTest
import CoolDownKit

final class AppMarketingVersionTests: XCTestCase {
    func testReadsCFBundleShortVersionString() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.0.4"]
        XCTAssertEqual(AppMarketingVersion.string(fromInfoDictionary: info), "1.0.4")
    }

    func testTrimsWhitespaceAndFallsBackWhenMissing() {
        XCTAssertEqual(
            AppMarketingVersion.string(fromInfoDictionary: ["CFBundleShortVersionString": "  2.1.0  "]),
            "2.1.0"
        )
        XCTAssertEqual(AppMarketingVersion.string(fromInfoDictionary: [:]), "—")
        XCTAssertEqual(AppMarketingVersion.string(fromInfoDictionary: nil), "—")
    }

    func testBundleHelperUsesMarketingVersionKey() {
        let fromMain = AppMarketingVersion.string(from: .main)
        let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = expected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            XCTAssertEqual(fromMain, "—")
        } else {
            XCTAssertEqual(fromMain, trimmed)
            XCTAssertNotEqual(fromMain, "1.0.0")
        }
    }
}
