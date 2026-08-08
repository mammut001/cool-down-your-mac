import SwiftUI
import CoolDownKit

struct ProSettingsView: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            Form {
                Section("General") {
                    Toggle("Show temperature in menu bar", isOn: $settings.settings.showTemperatureInMenuBar)
                    Toggle("Launch at login", isOn: $settings.settings.launchAtLogin)
                    HStack {
                        Text("Sample interval")
                        Slider(value: $settings.settings.sampleIntervalSeconds, in: 1...10, step: 0.5)
                        Text("\(settings.settings.sampleIntervalSeconds, specifier: "%.1f")s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Section("Helper") {
                    LabeledContent("Status") {
                        Text(model.helper.isConnected ? "Connected" : "Not connected")
                    }
                    Button("Install / Register Helper") { model.installHelper() }
                    Text("Helper requires admin approval via System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Smart Curve") {
                    ForEach(Array(settings.settings.curve.points.enumerated()), id: \.element.id) { index, _ in
                        HStack {
                            TextField(
                                "°C",
                                value: $settings.settings.curve.points[index].temperatureC,
                                format: .number
                            )
                            Text("→")
                            TextField(
                                "%",
                                value: Binding(
                                    get: { settings.settings.curve.points[index].fanPercent * 100 },
                                    set: { settings.settings.curve.points[index].fanPercent = ($0 / 100).clamped(to: 0...1) }
                                ),
                                format: .number
                            )
                        }
                    }
                    HStack {
                        Text("Hysteresis")
                        Slider(value: $settings.settings.curve.hysteresisC, in: 0.5...5, step: 0.5)
                        Text("\(settings.settings.curve.hysteresisC, specifier: "%.1f")°C")
                            .frame(width: 48, alignment: .trailing)
                    }
                    Button("Reset to default curve") { settings.resetCurveToDefault() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Curve", systemImage: "chart.xyaxis.line") }

            Form {
                Section("Alerts") {
                    Toggle("Enable temperature alerts", isOn: $settings.settings.alertsEnabled)
                    HStack {
                        Text("Alert at")
                        Slider(value: $settings.settings.alertTemperatureC, in: 70...105, step: 1)
                        Text("\(Int(settings.settings.alertTemperatureC))°C")
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Product", value: "Cool Down Pro")
                    Text("Independent build with SMC fan control. Not affiliated with Apple.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Alerts", systemImage: "bell") }
        }
        .padding()
    }
}
