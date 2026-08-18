import SwiftUI
import CoolDownKit

struct ProSettingsView: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
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
                        Text(model.helperStatusText)
                    }
                    Button(model.helperActionTitle) {
                        model.performHelperAction()
                    }
                    .disabled(!model.helperActionIsEnabled)
                    Text("macOS asks for an administrator password on first install and explicit repairs only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Smart Curve") {
                    Text("Edit the temperature → fan curve in the Cool Down Pro window under the Fan Curve tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Hysteresis")
                        Slider(value: $settings.settings.curve.hysteresisC, in: 0.5...5, step: 0.5)
                        Text("\(settings.settings.curve.hysteresisC, specifier: "%.1f")°C")
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Load boost max")
                        Slider(value: $settings.settings.loadBoostMax, in: 0...0.4, step: 0.05)
                        Text("\(Int(settings.settings.loadBoostMax * 100))%")
                            .frame(width: 40, alignment: .trailing)
                    }
                    HStack {
                        Text("Boost above load")
                        Slider(value: $settings.settings.loadBoostThreshold, in: 20...95, step: 5)
                        Text("\(Int(settings.settings.loadBoostThreshold))%")
                            .frame(width: 40, alignment: .trailing)
                    }
                    Button("Reset curve to default") { settings.resetCurveToDefault() }
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
                    LabeledContent("Version", value: AppMarketingVersion.string(from: .main))
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
        .onChange(of: settings.settings.sampleIntervalSeconds) { _, _ in
            model.startPolling()
        }
        .onChange(of: settings.settings.launchAtLogin) { _, _ in
            model.applyLaunchAtLogin()
        }
        if let status = model.statusMessage {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .bottom])
        }
        }
    }
}
