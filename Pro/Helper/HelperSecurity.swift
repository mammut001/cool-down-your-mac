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

    struct TrustedCaller {
        /// `CFBundleVersion` from the client's signed Info.plist. `nil` when
        /// the plist carries no usable build number; the helper then refuses
        /// manual fan control rather than guess that the app renews leases.
        let buildNumber: Int?
    }

    static func trustedCaller(connection: NSXPCConnection) -> TrustedCaller? {
#if DEBUG
        if ProcessInfo.processInfo.environment["COOLDOWN_HELPER_DEV"] == "1" {
            return TrustedCaller(buildNumber: HelperService.minimumLeaseClientBuild)
        }
#endif
        guard let codesign = try? guestCodesign(connection: connection) else {
            return nil
        }
        guard let team = codesign.teamID, !team.isEmpty, allowedTeamIDs.contains(team) else {
            return nil
        }
        guard let bundleID = codesign.bundleID, allowedBundleIDs.contains(bundleID) else {
            return nil
        }
        guard codesign.signatureValid else { return nil }
        return TrustedCaller(buildNumber: codesign.buildNumber)
    }

    private struct CodesignInfo {
        var bundleID: String?
        var teamID: String?
        var buildNumber: Int?
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
        // The sealed Info.plist is part of the signature, so a valid signature
        // also vouches for this build number.
        let plist = info[kSecCodeInfoPList as String] as? [String: Any]
        return CodesignInfo(
            bundleID: identifiers,
            teamID: team,
            buildNumber: HelperService.buildNumber(fromBundleVersion: plist?["CFBundleVersion"]),
            signatureValid: validity == errSecSuccess
        )
    }
}
