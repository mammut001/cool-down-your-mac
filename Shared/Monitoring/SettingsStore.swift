import Foundation
import Combine

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings

    private let defaults: UserDefaults
    private var persistenceCancellable: AnyCancellable?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: AppSettings.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
        persistenceCancellable = $settings
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] settings in
                self?.persist(settings)
            }
    }

    private func persist(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: AppSettings.storageKey)
    }

    /// Flush pending debounced edits before application termination or when a
    /// caller needs a persistence boundary.
    public func flush() {
        persist(settings)
    }

    public func resetCurveToDefault() {
        settings.curve = CurveProfile()
    }
}
