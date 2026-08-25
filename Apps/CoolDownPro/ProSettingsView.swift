import SwiftUI
import CoolDownKit
import AppKit

struct ProSettingsView: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updateController = UpdateController.shared
    @State private var confirmingCurveReset = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
            curveSettings
                .tabItem { Label("Curve", systemImage: "chart.xyaxis.line") }
            alertSettings
                .tabItem { Label("Alerts", systemImage: "bell") }
            updateSettings
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .padding()
        .onChange(of: settings.settings.alertsEnabled) { _, enabled in
            if enabled {
                model.requestNotificationPermission()
            }
        }
        .confirmationDialog(
            "Reset the fan curve?",
            isPresented: $confirmingCurveReset,
            titleVisibility: .visible
        ) {
            Button("Reset to Default", role: .destructive) {
                settings.resetCurveToDefault()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current curve points will be replaced with the balanced default curve.")
        }
        .alert(model.helperSetupTitle, isPresented: $model.shouldPresentHelperSetup) {
            Button("Not Now", role: .cancel) {}
            Button(model.helperSetupConfirmTitle) {
                model.performHelperSetup()
            }
        } message: {
            Text(model.helperSetupMessage)
        }
    }

    private var generalSettings: some View {
        Form {
            Section("General") {
                Toggle("Show temperature in menu bar", isOn: $settings.settings.showTemperatureInMenuBar)
                Toggle("Launch at login", isOn: $settings.settings.launchAtLogin)
                HStack {
                    Text("Sample interval")
                    Slider(value: $settings.settings.sampleIntervalSeconds, in: 1...10, step: 0.5)
                        .accessibilityLabel("Sample interval")
                    Text("\(settings.settings.sampleIntervalSeconds, specifier: "%.1f")s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Section("Helper") {
                LabeledContent("Status") {
                    Label(model.helperStatusText, systemImage: helperStatusIcon)
                        .foregroundStyle(model.helperControlIsReady ? CoolDownTheme.calm : CoolDownTheme.warning)
                }
                Button(model.helperActionTitle) {
                    model.performHelperAction()
                }
                .disabled(!model.helperActionIsEnabled)
                .help("Installs or repairs the privileged helper used to control fan speed.")
                Text("macOS asks for an administrator password on first install and explicit repairs only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var curveSettings: some View {
        Form {
            Section("Smart Curve") {
                LabeledContent {
                    Button("Open Fan Curve…") { openFanCurve() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Curve editor")
                        Text("Edit temperature and fan-speed points in the main window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Hysteresis")
                    Slider(value: $settings.settings.curve.hysteresisC, in: 0.5...5, step: 0.5)
                        .accessibilityLabel("Hysteresis")
                    Text("\(settings.settings.curve.hysteresisC, specifier: "%.1f")°C")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                HStack {
                    Text("Load boost max")
                    Slider(value: $settings.settings.loadBoostMax, in: 0...0.4, step: 0.05)
                        .accessibilityLabel("Maximum load boost")
                    Text("\(Int(settings.settings.loadBoostMax * 100))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Boost above load")
                    Slider(value: $settings.settings.loadBoostThreshold, in: 20...95, step: 5)
                        .accessibilityLabel("Boost load threshold")
                    Text("\(Int(settings.settings.loadBoostThreshold))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Button("Reset curve to default…", role: .destructive) {
                    confirmingCurveReset = true
                }
            }
        }
        .formStyle(.grouped)
    }

    private var alertSettings: some View {
        Form {
            Section("Alerts") {
                Toggle("Enable temperature alerts", isOn: $settings.settings.alertsEnabled)
                HStack {
                    Text("Alert at")
                    Slider(value: $settings.settings.alertTemperatureC, in: 70...105, step: 1)
                        .accessibilityLabel("Alert temperature")
                    Text("\(Int(settings.settings.alertTemperatureC))°C")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!settings.settings.alertsEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var updateSettings: some View {
        Form {
            Section("Software Update") {
                LabeledContent("Installed Version", value: updateController.formattedCurrentVersion)
                LabeledContent("Last Checked", value: updateController.formattedLastCheckDate)
                Toggle("Automatically check for updates", isOn: $updateController.automaticallyChecksForUpdates)
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
                Text("Updates are cryptographically signed via Sparkle EdDSA and verified with Apple Developer ID / Notarization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }

    private var helperStatusIcon: String {
        model.helperControlIsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func openFanCurve() {
        openWindow(id: "dashboard")
        NotificationCenter.default.post(name: .coolDownOpenFanCurve, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
