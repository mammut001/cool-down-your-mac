import SwiftUI
import CoolDownKit
import AppKit

struct ProDashboardView: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            sensorsTab
                .tabItem { Label("Overview", systemImage: "gauge.with.dots.needle.67percent") }

            FanCurveEditorView()
                .environmentObject(model)
                .environmentObject(settings)
                .tabItem { Label("Fan Curve", systemImage: "chart.xyaxis.line") }
        }
        .frame(minWidth: 640, minHeight: 700)
        .background(GlassBackdrop())
        .alert(model.helperSetupTitle, isPresented: $model.shouldPresentHelperSetup) {
            Button("Not Now", role: .cancel) {}
            Button(model.helperSetupConfirmTitle) { model.performHelperSetup() }
        } message: {
            Text(model.helperSetupMessage)
        }
        .onAppear {
            // Show in the Dock so users can right-click → Quit or press ⌘Q
            // without using Terminal. The menu-bar extra stays available.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.tick() }
        }
    }

    private var sensorsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                sensorsHeader
                liveMetrics
                if let status = model.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                sensorTable
            }
            .padding(20)
        }
    }

    private var sensorsHeader: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Cool Down Pro", systemImage: "fanblades.fill")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("\(settings.settings.mode.displayName) · \(model.snapshot.temperatures.count) sensors live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show all raw sensors", isOn: $model.showAllSensors)
                    .font(.caption)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: model.showAllSensors) { _, _ in
                        Task { await model.refreshSnapshot() }
                    }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(SensorFormatting.temperature(model.snapshot.maxTemperatureC))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(CoolDownTheme.temperatureColor(model.snapshot.maxTemperatureC))
                Text("hottest component")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        }
    }

    private var liveMetrics: some View {
        HStack(spacing: 12) {
            metricCard("Control", value: settings.settings.mode.displayName, icon: "slider.horizontal.3", tint: CoolDownTheme.accent)
            metricCard("Fan target", value: fanTargetLabel, icon: "fanblades", tint: CoolDownTheme.calm)
            metricCard("CPU load", value: String(format: "%.0f%%", model.loadMonitor.cpuLoadPercent), icon: "cpu", tint: CoolDownTheme.warning)
            metricCard("Fan control", value: model.helperStatusText, icon: "checkmark.shield", tint: model.helperControlIsReady ? CoolDownTheme.calm : CoolDownTheme.warning)
        }
    }

    private func metricCard(_ title: String, value: String, icon: String, tint: Color) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sensorTable: some View {
        GlassCard {
            VStack(spacing: 0) {
            HStack {
                Label("Sensors", systemImage: "thermometer.medium")
                Spacer()
                Text("Value °C")
                    .frame(width: 72, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 10)

            Divider()

            if model.snapshot.temperatures.isEmpty {
                ContentUnavailableView(
                    "No sensors",
                    systemImage: "thermometer.medium",
                    description: Text("Temperature sensors will appear here when available.")
                )
            } else {
                List {
                    ForEach(groupedSensors, id: \.group) { section in
                        Section(section.group.displayName) {
                            ForEach(section.items) { reading in
                                HStack(spacing: 10) {
                                    Image(systemName: icon(for: reading.group))
                                        .foregroundStyle(CoolDownTheme.temperatureColor(reading.celsius))
                                        .frame(width: 16)
                                    Text(reading.name)
                                        .font(.body)
                                    Spacer()
                                    Text(SensorFormatting.temperature(reading.celsius))
                                        .font(.body.monospacedDigit().weight(.medium))
                                        .foregroundStyle(CoolDownTheme.temperatureColor(reading.celsius))
                                        .frame(width: 72, alignment: .trailing)
                                }
                                .padding(.vertical, 2)
                                .listRowSeparator(.visible)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 250)
            }
        }
        }
    }

    private var fanTargetLabel: String {
        if settings.settings.mode == .systemAuto { return "Auto" }
        if !model.helperControlIsReady { return "—" }
        return SensorFormatting.percent(model.targetFanPercent)
    }

    private var groupedSensors: [(group: SensorGroup, items: [TemperatureReading])] {
        SensorGroup.allCases.compactMap { group in
            let items = model.snapshot.temperatures.filter { $0.group == group }
            guard !items.isEmpty else { return nil }
            return (group, items)
        }
    }

    private func icon(for group: SensorGroup) -> String {
        switch group {
        case .cpu: return "cpu"
        case .gpu: return "rectangle.3.group.fill"
        case .battery: return "battery.100"
        case .storage: return "internaldrive"
        case .wireless: return "wifi"
        case .other: return "thermometer.medium"
        }
    }
}
