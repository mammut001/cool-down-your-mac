import Foundation
import AppKit
import Sparkle
import Combine
import UserNotifications
import CoolDownKit

/// Manages in-app software updates via Sparkle 2.
///
/// Cool Down Pro is a menu-bar-only (`LSUIElement`) app, and automatic
/// installation is off, so an update only lands when the user accepts
/// Sparkle's alert. Without the gentle-reminder delegate below, Sparkle shows
/// that alert for a scheduled check behind every other window and never
/// activates the app: a Mac ran 1.0.18 for a month with 1.0.21 published and
/// daily checks succeeding. Scheduled updates are now surfaced in the menu-bar
/// popover and as a notification; either brings Sparkle's alert into focus.
@MainActor
public final class UpdateController: NSObject, ObservableObject {
    public static let shared = UpdateController()

    @Published public private(set) var canCheckForUpdates: Bool = false
    @Published public private(set) var isChecking: Bool = false
    @Published public var automaticallyChecksForUpdates: Bool = true {
        didSet {
            updaterController?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published public private(set) var lastUpdateCheckDate: Date? = nil
    /// Display version of an update found by a scheduled check that the user
    /// has not looked at yet. Drives the reminder row in the menu-bar popover.
    @Published public private(set) var pendingUpdateVersion: String? = nil

    private var updaterController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()
    private static let updateNotificationIdentifier = "com.cooldown.CoolDownPro.update-available"

    public init(startingUpdater: Bool = true) {
        super.init()
        guard startingUpdater else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.updaterController = controller
        UNUserNotificationCenter.current().delegate = self

        self.canCheckForUpdates = controller.updater.canCheckForUpdates
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        self.lastUpdateCheckDate = controller.updater.lastUpdateCheckDate

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)

        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecksForUpdates)

        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .assign(to: &$lastUpdateCheckDate)
    }

    /// Opens Sparkle's update alert in focus. For an update a scheduled check
    /// already found, Sparkle brings that pending alert forward instead of
    /// checking again.
    public func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    public var formattedCurrentVersion: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return UpdateFormatting.versionString(marketing: marketing, build: build)
    }

    public var formattedLastCheckDate: String {
        UpdateFormatting.lastCheckDescription(date: lastUpdateCheckDate)
    }

    // MARK: Gentle reminders

    private func rememberPendingUpdate(_ update: SUAppcastItem) {
        let version = update.displayVersionString
        pendingUpdateVersion = version
        NSApp.activate(ignoringOtherApps: false)

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // Never raise the permission prompt for an update; the popover row
            // is the fallback when notifications are off.
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Cool Down Pro \(version) is available"
            content.body = "Open Cool Down Pro from the menu bar to install the update."
            let request = UNNotificationRequest(
                identifier: Self.updateNotificationIdentifier,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    private func clearPendingUpdate() {
        pendingUpdateVersion = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.updateNotificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.updateNotificationIdentifier])
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated public var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated public func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Right after launch (or after a long idle) Sparkle activates the app
        // and shows the alert as the key window: keep that. Any other scheduled
        // update would be shown behind other apps, so this controller shows it.
        immediateFocus
    }

    nonisolated public func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated, !handleShowingUpdate else { return }
        MainActor.assumeIsolated { rememberPendingUpdate(update) }
    }

    nonisolated public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { clearPendingUpdate() }
    }

    nonisolated public func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { clearPendingUpdate() }
    }
}

extension UpdateController: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A menu-bar app counts as "foreground" whenever its popover is open;
        // temperature alerts and update reminders must still be visible then.
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isUpdateNotification = response.notification.request.identifier == Self.updateNotificationIdentifier
        Task { @MainActor in
            if isUpdateNotification {
                self.checkForUpdates()
            }
            completionHandler()
        }
    }
}
