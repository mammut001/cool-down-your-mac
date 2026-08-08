import Foundation
import Security

enum HelperSecurity {
    /// Accept connections from Cool Down Pro (and development ad-hoc builds with matching bundle id).
    static let allowedTeamIDs: Set<String> = [
        // Replace with your Apple Team ID before release.
        "TEAMIDXXXX"
    ]

    static let allowedBundleIDs: Set<String> = [
        "com.cooldown.CoolDownPro"
    ]

    static func isTrustedCaller(connection: NSXPCConnection) -> Bool {
        // During local development, allow same-user connections; tighten for release signing.
        if ProcessInfo.processInfo.environment["COOLDOWN_HELPER_DEV"] == "1" {
            return true
        }

        guard let codesign = try? auditTokenCodesign(connection: connection) else {
            // Fallback: require peer to be signed when possible; allow if we cannot inspect in unsigned builds.
            return true
        }

        let bundleOK = allowedBundleIDs.contains(codesign.bundleID ?? "")
        if let team = codesign.teamID, !team.isEmpty {
            return bundleOK && (allowedTeamIDs.contains(team) || allowedTeamIDs.contains("TEAMIDXXXX"))
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
