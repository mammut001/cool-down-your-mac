import SwiftUI
import CoolDownKit
import AppKit

struct ProMenuBarView: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var updateController = UpdateController.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                openDashboard()
            } label: {
                Label("Open Cool Down Pro", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(CoolDownTheme.accent)
            .controlSize(.regular)

            GlassCard(contentPadding: 12) {
                VStack(spacing: 10) {
                    SnapshotHeaderView(
                        maxTemp: model.snapshot.maxTemperatureC,
                        modeLabel: settings.settings.mode.displayName
                    )
                    Divider()
                ModePickerView(
                    mode: Binding(
                        get: { settings.settings.mode },
                        set: { model.setMode($0) }
                    ),
                    enabledModes: ControlMode.allCases
                )
                }
            }

            if settings.settings.mode == .manual {
                GlassCard(contentPadding: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Manual speed", systemImage: "fanblades")
                        Spacer()
                        Text(SensorFormatting.percent(settings.settings.manualPercent))
                            .foregroundStyle(model.helperControlIsReady ? CoolDownTheme.accent : Color.secondary)
                    }
                    .font(.caption)
                    Slider(
                        value: Binding(
                            get: { settings.settings.manualPercent },
                            set: { model.setManualPercent($0) }
                        ),
                        in: 0...1
                    )
                    .disabled(!model.helperControlIsReady)
                    if !model.helperControlIsReady {
                        Text("Fan control must be enabled before manual speed can be changed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                }
            }

            GlassCard(contentPadding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                Label("Fans", systemImage: "fanblades")
                    .font(.subheadline.weight(.semibold))
                if model.snapshot.fans.isEmpty {
                    Text(model.fanControlUnavailableOnThisMac
                         ? "Fan controller not supported yet"
                         : "No fans detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.fans) { fan in
                        FanRowView(fan: fan)
                    }
                }
                }
            }

            GlassCard(contentPadding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Sensors", systemImage: "thermometer.medium")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(model.snapshot.temperatures.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if model.snapshot.temperatures.isEmpty {
                    Text("No sensors available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TemperatureListView(temperatures: menuTemperatures)
                }
                }
            }

            if let status = model.statusMessage {
                HStack(spacing: 6) {
                    Image(systemName: model.helperControlIsReady ? "info.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.helperControlIsReady ? CoolDownTheme.accent : CoolDownTheme.warning)
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if model.helperActionIsEnabled {
                        Button(model.helperActionTitle) {
                            openDashboard()
                            model.performHelperAction()
                        }
                        .disabled(model.isBusy)
                        .controlSize(.mini)
                    }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack {
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!updateController.canCheckForUpdates)
                Button { openSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Button("Quit Cool Down Pro") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Stops background monitoring so the app can be deleted or replaced.")
        }
        .padding(14)
        .frame(width: 340)
        .background(GlassBackdrop())
        .onAppear {
            Task { await model.tick() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .coolDownOpenDashboard)) { _ in
            openDashboard()
        }
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }

    /// One representative per hardware group is more useful in the compact
    /// popover than showing five adjacent CPU core readings.
    private var menuTemperatures: [TemperatureReading] {
        let groups = SensorGroup.allCases.sorted { $0.sortOrder < $1.sortOrder }
        var result = groups.compactMap { group in
            model.snapshot.temperatures
                .filter { $0.group == group }
                .max(by: { $0.celsius < $1.celsius })
        }
        let representedKeys = Set(result.map(\.key))
        let extras = model.snapshot.temperatures
            .filter { !representedKeys.contains($0.key) }
            .sorted { $0.celsius > $1.celsius }
        result.append(contentsOf: extras)
        return Array(result.prefix(6))
    }
}
