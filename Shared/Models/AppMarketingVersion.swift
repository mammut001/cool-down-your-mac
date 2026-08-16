import Foundation

/// Marketing version shown in Settings → About.
public enum AppMarketingVersion {
    public static func string(from bundle: Bundle) -> String {
        string(fromInfoDictionary: bundle.infoDictionary)
    }

    public static func string(fromInfoDictionary info: [String: Any]?) -> String {
        let raw = info?["CFBundleShortVersionString"] as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "—" : trimmed
    }
}
