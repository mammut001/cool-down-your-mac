import SwiftUI
import CoolDownKit

struct StoreMenuBarView: View {
    @EnvironmentObject private var model: StoreAppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cool Down")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("App Store edition — monitors heat, no fan override")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.pressure.displayName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(color(for: model.pressure))
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                Label("System", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.subheadline.weight(.semibold))
                LabeledContent("Thermal pressure", value: model.pressure.displayName)
                LabeledContent("Approx. active load") {
                    Text(SensorFormatting.percent(model.cpuLoadPercent / 100))
                }
                Text(model.coachingTip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                Label("Hot processes", systemImage: "flame")
                    .font(.subheadline.weight(.semibold))
                if model.hotProcesses.isEmpty {
                    Text("No notable hot processes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.hotProcesses.prefix(6)) { proc in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(proc.name).font(.caption.weight(.medium))
                                Text("PID \(proc.pid)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.0f", proc.cpuPercent))
                                .font(.caption.monospacedDigit())
                            Button("Quit") { model.quitProcess(proc) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
                }
            }

            if let status = model.statusMessage {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Button("Cool Down Tips") { model.coolDownNow() }
                Button("Settings…") { openSettings() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 320)
        .background(GlassBackdrop())
        .onAppear { model.refresh() }
        .onChange(of: settings.settings.sampleIntervalSeconds) { _, _ in model.startPolling() }
        .onChange(of: settings.settings.launchAtLogin) { _, _ in model.applyLaunchAtLogin() }
    }

    private func color(for level: ThermalPressureLevel) -> Color {
        switch level {
        case .nominal: return CoolDownTheme.calm
        case .fair: return CoolDownTheme.accent
        case .serious: return CoolDownTheme.warning
        case .critical: return CoolDownTheme.danger
        }
    }
}
