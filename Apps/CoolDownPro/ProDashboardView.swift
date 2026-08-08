import SwiftUI
import CoolDownKit
import AppKit

struct ProDashboardView: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sensorTable
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.tick() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cool Down Pro")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("\(model.snapshot.temperatures.count) sensors · \(settings.settings.mode.displayName)")
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
            VStack(alignment: .trailing, spacing: 2) {
                Text(SensorFormatting.temperature(model.snapshot.maxTemperatureC))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(CoolDownTheme.temperatureColor(model.snapshot.maxTemperatureC ?? 0))
                Text("peak CPU/GPU")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var sensorTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sensor")
                Spacer()
                Text("Value °C")
                    .frame(width: 72, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

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
                                    Text(String(format: "%.0f°C", reading.celsius))
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
            }
        }
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
        case .gpu: return "cloud"
        case .battery: return "battery.100"
        case .storage: return "internaldrive"
        case .wireless: return "wifi"
        case .other: return "thermometer.medium"
        }
    }
}
