import SwiftUI
import CoolDownKit

struct StoreSettingsView: View {
    @EnvironmentObject private var model: StoreAppModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show status in menu bar", isOn: $settings.settings.showTemperatureInMenuBar)
                Toggle("Launch at login", isOn: $settings.settings.launchAtLogin)
                HStack {
                    Text("Refresh interval")
                    Slider(value: $settings.settings.sampleIntervalSeconds, in: 1.5...10, step: 0.5)
                    Text("\(settings.settings.sampleIntervalSeconds, specifier: "%.1f")s")
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Section("Alerts") {
                Toggle("Thermal pressure alerts", isOn: $settings.settings.alertsEnabled)
            }
            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                Text("This App Store edition does not control hardware fans. It monitors thermal pressure and helps you reduce load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
