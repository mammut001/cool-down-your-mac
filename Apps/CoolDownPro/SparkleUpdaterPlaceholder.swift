import Foundation

/// Sparkle integration placeholder.
///
/// After adding the Sparkle SPM package to CoolDownPro:
/// 1. `import Sparkle`
/// 2. Create `SPUStandardUpdaterController` in `AppDelegate`
/// 3. Fill `SUFeedURL` + `SUPublicEDKey` in Info.plist
/// 4. Publish signed updates via Packaging/Sparkle/appcast-template.xml
enum SparkleUpdaterPlaceholder {
    static let feedURLPlaceholder = "https://example.com/cooldown/appcast.xml"
}
