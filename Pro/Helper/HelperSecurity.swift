import Foundation
import Security

enum HelperSecurity {
    static let allowedTeamIDs: Set<String> = [
        "Z5D5N7CU6L"
    ]

    static let allowedBundleIDs: Set<String> = [
        "com.cooldown.CoolDownPro"
    ]

    /// Developer ID Application requirement for the GUI client.
    static let clientRequirement =
        "identifier \"com.cooldown.CoolDownPro\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = Z5D5N7CU6L"

    /// Developer ID Application requirement for the privileged helper.
    static let helperRequirement =
        "identifier \"com.cooldown.CoolDownPro.PrivilegedHelper\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = Z5D5N7CU6L"

    static func isTrustedCaller(connection: NSXPCConnection) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["COOLDOWN_HELPER_DEV"] == "1" {
            return true
        }
#endif
        guard let codesign = try? guestCodesign(connection: connection) else {
            return false
        }
        guard let team = codesign.teamID, !team.isEmpty, allowedTeamIDs.contains(team) else {
            return false
        }
        guard let bundleID = codesign.bundleID, allowedBundleIDs.contains(bundleID) else {
            return false
        }
        return codesign.signatureValid
    }

    private struct CodesignInfo {
        var bundleID: String?
        var teamID: String?
        var signatureValid: Bool
    }

    private static func guestCodesign(connection: NSXPCConnection) throws -> CodesignInfo {
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

        var requirement: SecRequirement?
        err = SecRequirementCreateWithString(clientRequirement as CFString, [], &requirement)
        guard err == errSecSuccess, let requirement else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        let validity = SecCodeCheckValidity(code, [], requirement)

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
        return CodesignInfo(
            bundleID: identifiers,
            teamID: team,
            signatureValid: validity == errSecSuccess
        )
    }
}
