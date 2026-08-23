import Foundation
import Sparkle
import Combine
import CoolDownKit

/// Manages in-app software updates via Sparkle 2.
@MainActor
public final class UpdateController: ObservableObject {
    public static let shared = UpdateController()

    @Published public private(set) var canCheckForUpdates: Bool = false
    @Published public private(set) var isChecking: Bool = false
    @Published public var automaticallyChecksForUpdates: Bool = true {
        didSet {
            updaterController?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published public private(set) var lastUpdateCheckDate: Date? = nil

    private var updaterController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    public init(startingUpdater: Bool = true) {
        if startingUpdater {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            self.updaterController = controller

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
    }

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
}
