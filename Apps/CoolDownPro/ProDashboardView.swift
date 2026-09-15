import SwiftUI
import CoolDownKit
import AppKit

struct ProDashboardView: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore
    @State private var selectedTab: DashboardTab = .overview
    @State private var sensorSearchText = ""

    private enum DashboardTab: Hashable {
        case overview
        case fanCurve
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            sensorsTab
                .tabItem { Label("Overview", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(DashboardTab.overview)

            FanCurveEditorView()
                .environmentObject(model)
                .environmentObject(settings)
                .tabItem { Label("Fan Curve", systemImage: "chart.xyaxis.line") }
                .tag(DashboardTab.fanCurve)
        }
        .frame(minWidth: 640, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
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
            model.isDashboardVisible = true
            Task { await model.tick() }
        }
        .onDisappear {
            model.isDashboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .coolDownOpenFanCurve)) { _ in
            selectedTab = .fanCurve
        }
    }

    private var sensorsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                TelemetryContent(updates: model.telemetryUpdates) { sensorsHeader }
                TelemetryContent(updates: model.telemetryUpdates) { liveMetrics }
                if let status = model.statusMessage {
                    statusBanner(status)
                }
                TelemetryContent(updates: model.telemetryUpdates) { sensorTable }
            }
            .padding(20)
        }
    }

    private var sensorsHeader: some View {
        let displayTemp = model.snapshot.displayTemperatureC ?? model.snapshot.maxTemperatureC
        let maxTemp = model.snapshot.maxTemperatureC
        let label: String
        if let maxTemp, let displayTemp, maxTemp - displayTemp >= 8.0 {
            label = "avg · peak \(SensorFormatting.temperature(maxTemp))"
        } else {
            label = model.snapshot.displayTemperatureC != nil ? "chip average" : "hottest component"
        }
        return DashboardSensorHeader(
            mode: settings.settings.mode.displayName,
            count: model.snapshot.temperatures.count,
            temperature: SensorFormatting.temperature(displayTemp),
            label: label,
            tint: CoolDownTheme.temperatureColor(displayTemp),
            showAll: model.showAllSensors,
            setShowAll: { value in
                model.showAllSensors = value
                Task { await model.refreshSnapshot() }
            }
        ).equatable()
    }

    private var liveMetrics: some View {
        HStack(spacing: 12) {
            metricCard("Control", value: settings.settings.mode.displayName, icon: "slider.horizontal.3", tint: CoolDownTheme.accent)
            metricCard(
                "Fan target",
                value: fanTargetLabel,
                icon: "fanblades",
                tint: model.helperControlIsReady || settings.settings.mode == .systemAuto ? CoolDownTheme.calm : .secondary
            )
            metricCard("CPU load", value: String(format: "%.0f%%", model.loadMonitor.cpuLoadPercent), icon: "cpu", tint: CoolDownTheme.warning)
            metricCard(
                "Fan control",
                value: model.helperStatusText,
                icon: model.helperControlIsReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                tint: model.helperControlIsReady ? CoolDownTheme.calm : CoolDownTheme.warning
            )
        }
    }

    private func statusBanner(_ status: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.helperControlIsReady ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.helperControlIsReady ? CoolDownTheme.accent : CoolDownTheme.warning)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.helperActionIsEnabled {
                Button(model.helperActionTitle) {
                    model.performHelperAction()
                }
                .disabled(model.isBusy)
                .liquidGlassButtonStyle(prominent: true)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func metricCard(_ title: String, value: String, icon: String, tint: Color) -> some View {
        DashboardMetricCard(title: title, value: value, icon: icon, tint: tint).equatable()
    }

    private var sensorTable: some View {
        DashboardCard {
            VStack(spacing: 0) {
            HStack {
                Label("Sensors", systemImage: "thermometer.medium")
                Spacer()
                TextField("Filter sensors", text: $sensorSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .accessibilityLabel("Filter sensors")
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
            } else if groupedSensors.isEmpty {
                ContentUnavailableView.search(text: sensorSearchText)
                    .frame(minHeight: 180)
            } else {
                NativeSensorTable(sections: groupedSensors)
                    .frame(height: 380)
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
        SensorGroup.allCases.sorted { $0.sortOrder < $1.sortOrder }.compactMap { group in
            let items = model.snapshot.temperatures.filter {
                guard $0.group == group else { return false }
                guard !sensorSearchText.isEmpty else { return true }
                return $0.name.localizedCaseInsensitiveContains(sensorSearchText)
                    || $0.key.localizedCaseInsensitiveContains(sensorSearchText)
            }
            guard !items.isEmpty else { return nil }
            return (group, items)
        }
    }

}

/// Native cell reuse keeps the full sensor view cheap even with hundreds of keys.
/// Only changed, visible cells receive text/color updates; telemetry stays full precision.
private struct NativeSensorTable: NSViewRepresentable {
    let sections: [(group: SensorGroup, items: [TemperatureReading])]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.setAccessibilityLabel("Temperature sensors")
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Sensor"
        name.width = 360
        name.minWidth = 150
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        value.title = "Temperature"
        value.width = 90
        value.minWidth = 90
        value.maxWidth = 90
        // Cell-based drawing avoids an Auto Layout view tree for every value.
        for column in [name, value] {
            let cell = NSTextFieldCell(textCell: "")
            cell.isEditable = false
            cell.lineBreakMode = .byTruncatingTail
            cell.alignment = column === value ? .right : .left
            column.dataCell = cell
        }
        table.addTableColumn(name)
        table.addTableColumn(value)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.update(sections: sections, table: table)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct Row {
            let id: String
            let name: String
            let value: String
            let color: NSColor
            let isGroup: Bool
        }
        private var rows: [Row] = []
        private let groupFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        private let nameFont = NSFont.systemFont(ofSize: 13)
        private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

        func update(sections: [(group: SensorGroup, items: [TemperatureReading])], table: NSTableView) {
            var next: [Row] = []
            for section in sections {
                next.append(Row(id: "group.\(section.group.rawValue)", name: section.group.displayName,
                                value: "\(section.items.count)", color: .secondaryLabelColor, isGroup: true))
                for item in section.items {
                    next.append(Row(id: "sensor.\(item.key)", name: item.name,
                                    value: SensorFormatting.temperature(item.celsius),
                                    color: NSColor(CoolDownTheme.temperatureColor(item.celsius)), isGroup: false))
                }
            }
            let structureChanged = rows.map(\.id) != next.map(\.id)
            let previous = rows
            rows = next
            if structureChanged {
                table.reloadData()
                return
            }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            var changed = IndexSet()
            for index in visible.location..<min(NSMaxRange(visible), rows.count) {
                let old = previous[index], new = rows[index]
                if old.name != new.name || old.value != new.value || old.color != new.color {
                    changed.insert(index)
                }
            }
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<2))
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
            guard rows.indices.contains(row) else { return nil }
            return tableColumn?.identifier.rawValue == "value" ? rows[row].value : rows[row].name
        }

        func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
            guard rows.indices.contains(row), let cell = cell as? NSTextFieldCell else { return }
            let item = rows[row]
            let isValue = tableColumn?.identifier.rawValue == "value"
            cell.font = item.isGroup ? groupFont : (isValue ? valueFont : nameFont)
            cell.textColor = item.isGroup ? .secondaryLabelColor : (isValue ? item.color : .labelColor)
        }
    }
}

private struct DashboardSensorHeader: View, Equatable {
    let mode: String
    let count: Int
    let temperature: String
    let label: String
    let tint: Color
    let showAll: Bool
    let setShowAll: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode && lhs.count == rhs.count && lhs.temperature == rhs.temperature
            && lhs.label == rhs.label && lhs.tint == rhs.tint && lhs.showAll == rhs.showAll
    }

    var body: some View {
        DashboardCard {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Cool Down Pro", systemImage: "fanblades.fill")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("\(mode) · \(count) sensors live").font(.caption).foregroundStyle(.secondary)
                    Toggle("Show all raw sensors", isOn: Binding(get: { showAll }, set: setShowAll))
                        .font(.caption).toggleStyle(.switch).controlSize(.small)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(temperature)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(tint)
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Static colors avoid recompositing live glass surfaces on every sensor update.
private struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

private struct DashboardMetricCard: View, Equatable {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
