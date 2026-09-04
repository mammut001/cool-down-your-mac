import Foundation
import Combine

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings

    private let defaults: UserDefaults
    private var persistenceCancellable: AnyCancellable?
    private let encoder = JSONEncoder()
    private var lastPersistedSettings: AppSettings?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: AppSettings.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
            self.lastPersistedSettings = decoded
        } else {
            let initial = AppSettings()
            self.settings = initial
            self.lastPersistedSettings = initial
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
        guard settings != lastPersistedSettings else { return }
        guard let data = try? encoder.encode(settings) else { return }
        lastPersistedSettings = settings
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
