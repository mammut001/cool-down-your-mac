import SwiftUI
import CoolDownKit
import AppKit

struct ProMenuBarView: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore
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

            SnapshotHeaderView(
                maxTemp: model.snapshot.maxTemperatureC,
                modeLabel: settings.settings.mode.displayName,
                helperOK: model.helper.isConnected || model.snapshot.helperAvailable
            )

            ModePickerView(
                mode: Binding(
                    get: { settings.settings.mode },
                    set: { model.setMode($0) }
                ),
                enabledModes: model.snapshot.canControlFans || model.helper.isConnected
                    ? ControlMode.allCases
                    : [.systemAuto, .smartCurve, .manual]
            )
            .disabled(!(model.helper.isConnected || model.snapshot.canControlFans))

            if settings.settings.mode == .manual {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Manual speed")
                        Spacer()
                        Text(SensorFormatting.percent(settings.settings.manualPercent))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Slider(
                        value: Binding(
                            get: { settings.settings.manualPercent },
                            set: { model.setManualPercent($0) }
                        ),
                        in: 0...1
                    )
                }
            }

            GroupBox("Fans") {
                if model.snapshot.fans.isEmpty {
                    Text("No fans detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.fans) { fan in
                        FanRowView(fan: fan)
                    }
                }
            }

            GroupBox {
                if model.snapshot.temperatures.isEmpty {
                    Text("No sensors available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        TemperatureListView(temperatures: model.snapshot.temperatures, maxVisible: 6)
                    }
                    .frame(maxHeight: 140)
                }
            } label: {
                HStack {
                    Text("Sensors")
                    Spacer()
                    Text("\(model.snapshot.temperatures.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                Button("Install Helper") { model.installHelper() }
                    .disabled(model.isBusy)
                Button("Settings…") { openSettings() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 340)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(red: 0.93, green: 0.97, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
            Task { await model.tick() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .coolDownOpenDashboard)) { _ in
            openDashboard()
        }
        .onChange(of: settings.settings.sampleIntervalSeconds) { _, _ in
            model.startPolling()
        }
        .onChange(of: settings.settings.launchAtLogin) { _, _ in
            model.applyLaunchAtLogin()
        }
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }
}
