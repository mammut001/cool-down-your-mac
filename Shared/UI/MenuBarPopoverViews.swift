import SwiftUI

public struct SnapshotHeaderView: View {
    public let maxTemp: Double?
    public let modeLabel: String

    public init(maxTemp: Double?, modeLabel: String) {
        self.maxTemp = maxTemp
        self.modeLabel = modeLabel
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cool Down Pro")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(SensorFormatting.temperature(maxTemp))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(CoolDownTheme.temperatureColor(maxTemp))
                    .contentTransition(.numericText())
                Text("Hottest")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)

    }
}

public struct FanRowView: View {
    public let fan: FanInfo
    public let onManualChange: ((Double) -> Void)?

    public init(fan: FanInfo, onManualChange: ((Double) -> Void)? = nil) {
        self.fan = fan
        self.onManualChange = onManualChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(fan.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(SensorFormatting.rpm(fan.currentRPM))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fan.percent)
                .tint(CoolDownTheme.accent)
                .accessibilityLabel("\(fan.name) speed")
                .accessibilityValue(SensorFormatting.rpm(fan.currentRPM))
            if let onManualChange {
                Slider(
                    value: Binding(
                        get: { fan.targetRPM.map { rpm in
                            guard fan.maxRPM > fan.minRPM else { return fan.percent }
                            return ((rpm - fan.minRPM) / (fan.maxRPM - fan.minRPM)).clamped(to: 0...1)
                        } ?? fan.percent },
                        set: { onManualChange($0) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

public struct TemperatureListView: View {
    public let temperatures: [TemperatureReading]
    public var maxVisible: Int?

    public init(temperatures: [TemperatureReading], maxVisible: Int? = nil) {
        self.temperatures = temperatures
        self.maxVisible = maxVisible
    }

    public var body: some View {
        let items = maxVisible.map { Array(temperatures.prefix($0)) } ?? temperatures
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { reading in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: reading.group))
                        .font(.caption2)
                        .foregroundStyle(CoolDownTheme.temperatureColor(reading.celsius))
                        .frame(width: 12)
                    Text(reading.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(SensorFormatting.temperature(reading.celsius))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(CoolDownTheme.temperatureColor(reading.celsius))
                }
            }
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

public struct ModePickerView: View {
    @Binding public var mode: ControlMode
    public let enabledModes: [ControlMode]

    public init(mode: Binding<ControlMode>, enabledModes: [ControlMode] = ControlMode.allCases) {
        self._mode = mode
        self.enabledModes = enabledModes
    }

    public var body: some View {
        Picker("Mode", selection: $mode) {
            ForEach(enabledModes) { item in
                Text(item.displayName).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
