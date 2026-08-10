import Foundation
import Security

enum HelperSecurity {
    static let allowedTeamIDs: Set<String> = [
        "Z5D5N7CU6L"
    ]

    static let allowedBundleIDs: Set<String> = [
        "com.cooldown.CoolDownPro"
    ]

    static func isTrustedCaller(connection: NSXPCConnection) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["COOLDOWN_HELPER_DEV"] == "1" {
            return true
        }
#endif
        guard let codesign = try? auditTokenCodesign(connection: connection) else {
            return false
        }

        let bundleOK = allowedBundleIDs.contains(codesign.bundleID ?? "")
        if let team = codesign.teamID, !team.isEmpty {
            return bundleOK && allowedTeamIDs.contains(team)
        }
        return bundleOK
    }

    private struct CodesignInfo {
        var bundleID: String?
        var teamID: String?
    }

    private static func auditTokenCodesign(connection: NSXPCConnection) throws -> CodesignInfo {
        var code: SecCode?
        var err = SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary,
            [],
            &code
        )
        guard err == errSecSuccess, let code else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        var staticCode: SecStaticCode?
        err = SecCodeCopyStaticCode(code, [], &staticCode)
        guard err == errSecSuccess, let staticCode else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        var infoCF: CFDictionary?
        err = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF)
        guard err == errSecSuccess, let info = infoCF as? [String: Any] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        let identifiers = info[kSecCodeInfoIdentifier as String] as? String
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        return CodesignInfo(bundleID: identifiers, teamID: team)
    }
}
