import Foundation

/// Fallback fan writer when the SMAppService helper cannot spawn (common with ad-hoc debug signing).
/// Shows a one-time macOS admin password prompt, then runs embedded `cooldown-smc` as root.
enum PrivilegedSMCWriter {
    static var toolURL: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("cooldown-smc")
    }

    static func setFansAuto() -> Bool {
        run(arguments: ["auto"])
    }

    static func setFansPercent(_ percent: Double) -> Bool {
        run(arguments: ["percent", String(format: "%.4f", min(max(percent, 0), 1))])
    }

    private static func run(arguments: [String]) -> Bool {
        guard let toolURL, FileManager.default.isExecutableFile(atPath: toolURL.path) else {
            return false
        }

        var lines = [
            "set toolPath to \"\(escape(toolURL.path))\"",
            "set cmd to quoted form of toolPath"
        ]
        for arg in arguments {
            lines.append("set cmd to cmd & \" \" & quoted form of \"\(escape(arg))\"")
        }
        lines.append("do shell script cmd with administrator privileges")

        let script = NSAppleScript(source: lines.joined(separator: "\n"))
        var error: NSDictionary?
        _ = script?.executeAndReturnError(&error)
        if let error {
            NSLog("PrivilegedSMCWriter failed: \(error)")
            return false
        }
        return true
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
