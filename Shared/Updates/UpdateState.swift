import Foundation

public enum UpdateFormatting {
    public static func versionString(marketing: String?, build: String?) -> String {
        let cleanMarketing = marketing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanBuild = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanMarketing.isEmpty else { return "—" }
        if cleanBuild.isEmpty || cleanBuild == cleanMarketing {
            return cleanMarketing
        }
        return "\(cleanMarketing) (\(cleanBuild))"
    }

    public static func lastCheckDescription(date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never checked" }
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = max(1, Int(interval / 60))
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = max(1, Int(interval / 3600))
            return "\(hours)h ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }
}
