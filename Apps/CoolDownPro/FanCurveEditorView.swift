import SwiftUI
import CoolDownKit

struct FanCurveEditorView: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore

    @State private var draggingID: UUID?
    @State private var selectedID: UUID?

    private let tempRange: ClosedRange<Double> = 30...100
    private let fanRange: ClosedRange<Double> = 0...1

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            headerControls

            GlassCard {
                curveCanvas
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .opacity(settings.settings.mode == .smartCurve ? 1 : 0.45)
            }

            if settings.settings.mode == .manual {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Manual fan speed")
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

            GlassCard { statusRow }
            editorButtons
        }
        .padding(20)
        }
        .background(GlassBackdrop())
    }

    private var headerControls: some View {
        GlassCard {
        VStack(alignment: .leading, spacing: 10) {
            Label("Fan Curve", systemImage: "chart.xyaxis.line")
                .font(.title2.weight(.semibold))
            ModePickerView(
                mode: Binding(
                    get: { settings.settings.mode },
                    set: { model.setMode($0) }
                ),
                enabledModes: model.helperControlIsReady ? ControlMode.allCases : [.systemAuto]
            )
            .disabled(!model.helperControlIsReady)
            Text(modeHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        }
    }

    private var modeHint: String {
        switch settings.settings.mode {
        case .systemAuto:
            return model.fanControlUnavailableOnThisMac
                ? "Fan telemetry is unavailable for this Mac's controller, so manual control is disabled."
                : "macOS controls fans. Curve editing is disabled."
        case .smartCurve:
            return "Fans follow the curve from CPU/GPU temperature. Heavy load adds up to \(Int(settings.settings.loadBoostMax * 100))% boost."
        case .manual:
            return "Fixed fan speed. Use the slider below."
        }
    }

    private var statusRow: some View {
        HStack(spacing: 16) {
            labeled("Temp", SensorFormatting.temperature(model.controlTemperatureC))
            if settings.settings.mode == .systemAuto {
                // System Auto does not command a target; show measured fan duty instead of "Target 0%".
                labeled("Actual", SensorFormatting.percent(model.snapshot.fans.first?.percent ?? 0))
            } else {
                labeled("Target", SensorFormatting.percent(model.targetFanPercent))
            }
            labeled("Boost", SensorFormatting.percent(model.loadBoostPercent))
            labeled("Load", String(format: "%.0f%%", model.loadMonitor.cpuLoadPercent))
            if let fan = model.snapshot.fans.first {
                labeled("RPM", SensorFormatting.rpm(fan.currentRPM))
            } else {
                labeled("RPM", "—")
            }
            Spacer()
        }
        .font(.caption.monospacedDigit())
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold)
        }
    }

    private var editorButtons: some View {
        HStack {
            Button("Add Point") { addPoint() }
                .disabled(settings.settings.mode != .smartCurve)
            Button("Remove Point") { removeSelected() }
                .disabled(
                    selectedID == nil
                        || settings.settings.curve.points.count <= 2
                        || settings.settings.mode != .smartCurve
                )
            Spacer()
            Button("Reset Curve") {
                settings.resetCurveToDefault()
                selectedID = nil
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var curveCanvas: some View {
        GeometryReader { geo in
            let pad: CGFloat = 16
            let plot = CGSize(
                width: max(0, geo.size.width - pad * 2),
                height: max(0, geo.size.height - pad * 2)
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.thinMaterial)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)

                Canvas { context, _ in
                    var grid = Path()
                    for i in 0...7 {
                        let x = pad + plot.width * CGFloat(i) / 7
                        grid.move(to: CGPoint(x: x, y: pad))
                        grid.addLine(to: CGPoint(x: x, y: pad + plot.height))
                        let y = pad + plot.height * CGFloat(i) / 7
                        grid.move(to: CGPoint(x: pad, y: y))
                        grid.addLine(to: CGPoint(x: pad + plot.width, y: y))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 1)

                    let points = settings.settings.curve.points.sorted { $0.temperatureC < $1.temperatureC }
                    if points.count >= 2 {
                        var curve = Path()
                        for (index, point) in points.enumerated() {
                            let p = pointToView(point, origin: CGPoint(x: pad, y: pad), size: plot)
                            if index == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                        }
                        context.stroke(
                            curve,
                            with: .color(CoolDownTheme.accent),
                            style: StrokeStyle(lineWidth: 2.5, lineJoin: .round)
                        )
                    }

                    if let temp = model.controlTemperatureC {
                        let x = pad + tempToX(temp, width: plot.width)
                        var v = Path()
                        v.move(to: CGPoint(x: x, y: pad))
                        v.addLine(to: CGPoint(x: x, y: pad + plot.height))
                        context.stroke(
                            v,
                            with: .color(CoolDownTheme.warning.opacity(0.85)),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                    }

                    let targetY = pad + fanToY(model.targetFanPercent, height: plot.height)
                    var h = Path()
                    h.move(to: CGPoint(x: pad, y: targetY))
                    h.addLine(to: CGPoint(x: pad + plot.width, y: targetY))
                    context.stroke(
                        h,
                        with: .color(CoolDownTheme.calm.opacity(0.9)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )

                    context.draw(
                        Text("30°C").font(.caption2).foregroundColor(.secondary),
                        at: CGPoint(x: pad + 2, y: pad + plot.height - 14),
                        anchor: .topLeading
                    )
                    context.draw(
                        Text("100°C").font(.caption2).foregroundColor(.secondary),
                        at: CGPoint(x: pad + plot.width - 36, y: pad + plot.height - 14),
                        anchor: .topLeading
                    )
                    context.draw(
                        Text("100%").font(.caption2).foregroundColor(.secondary),
                        at: CGPoint(x: pad + 2, y: pad + 2),
                        anchor: .topLeading
                    )
                }

                ForEach(settings.settings.curve.points) { point in
                    let pos = pointToView(point, origin: CGPoint(x: pad, y: pad), size: plot)
                    Circle()
                        .fill(selectedID == point.id ? CoolDownTheme.accent : Color.primary)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .position(pos)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(pad: pad, plot: plot))
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { event in
                        guard settings.settings.mode == .smartCurve else { return }
                        let local = CGPoint(x: event.location.x - pad, y: event.location.y - pad)
                        addPoint(at: local, canvas: plot)
                    }
            )
        }
        .padding(4)
    }

    private func dragGesture(pad: CGFloat, plot: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard settings.settings.mode == .smartCurve else { return }
                let location = CGPoint(x: value.location.x - pad, y: value.location.y - pad)
                if draggingID == nil {
                    let start = CGPoint(x: value.startLocation.x - pad, y: value.startLocation.y - pad)
                    draggingID = nearestPoint(to: start, in: plot)
                    selectedID = draggingID
                }
                if let id = draggingID {
                    updatePoint(id: id, location: location, canvas: plot)
                }
            }
            .onEnded { _ in
                draggingID = nil
            }
    }

    private func nearestPoint(to location: CGPoint, in plot: CGSize) -> UUID? {
        let points = settings.settings.curve.points
        var best: (UUID, CGFloat)?
        for point in points {
            let p = pointToView(point, origin: .zero, size: plot)
            let dist = hypot(p.x - location.x, p.y - location.y)
            if dist < 24, best == nil || dist < best!.1 {
                best = (point.id, dist)
            }
        }
        return best?.0
    }

    private func pointToView(_ point: CurvePoint, origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: origin.x + tempToX(point.temperatureC, width: size.width),
            y: origin.y + fanToY(point.fanPercent, height: size.height)
        )
    }

    private func tempToX(_ temp: Double, width: CGFloat) -> CGFloat {
        let t = ((temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)).clamped(to: 0...1)
        return CGFloat(t) * width
    }

    private func fanToY(_ fan: Double, height: CGFloat) -> CGFloat {
        CGFloat(1 - fan.clamped(to: fanRange)) * height
    }

    private func viewToTemp(_ x: CGFloat, width: CGFloat) -> Double {
        let t = Double(x / max(width, 1)).clamped(to: 0...1)
        return tempRange.lowerBound + (tempRange.upperBound - tempRange.lowerBound) * t
    }

    private func viewToFan(_ y: CGFloat, height: CGFloat) -> Double {
        (1 - Double(y / max(height, 1))).clamped(to: fanRange)
    }

    private func updatePoint(id: UUID, location: CGPoint, canvas: CGSize) {
        var points = settings.settings.curve.points.sorted { $0.temperatureC < $1.temperatureC }
        guard let sortedIndex = points.firstIndex(where: { $0.id == id }) else { return }

        let minTemp = sortedIndex == 0 ? tempRange.lowerBound : points[sortedIndex - 1].temperatureC + 1
        let maxTemp = sortedIndex == points.count - 1 ? tempRange.upperBound : points[sortedIndex + 1].temperatureC - 1
        var temp = viewToTemp(location.x, width: canvas.width)
        temp = min(max(temp, minTemp), max(minTemp, maxTemp))
        let fan = viewToFan(location.y, height: canvas.height)

        points[sortedIndex].temperatureC = temp
        points[sortedIndex].fanPercent = fan
        settings.settings.curve.points = points
    }

    private func addPoint() {
        let points = settings.settings.curve.points.sorted { $0.temperatureC < $1.temperatureC }
        guard let first = points.first, let last = points.last else { return }
        let midTemp = (first.temperatureC + last.temperatureC) / 2
        let midFan = settings.settings.curve.fanPercent(for: midTemp)
        let point = CurvePoint(temperatureC: midTemp, fanPercent: midFan)
        settings.settings.curve.points.append(point)
        settings.settings.curve.points.sort { $0.temperatureC < $1.temperatureC }
        selectedID = point.id
    }

    private func addPoint(at location: CGPoint, canvas: CGSize) {
        let temp = viewToTemp(location.x, width: canvas.width)
        let fan = viewToFan(location.y, height: canvas.height)
        let point = CurvePoint(temperatureC: temp, fanPercent: fan)
        settings.settings.curve.points.append(point)
        settings.settings.curve.points.sort { $0.temperatureC < $1.temperatureC }
        selectedID = point.id
    }

    private func removeSelected() {
        guard let selectedID else { return }
        guard settings.settings.curve.points.count > 2 else { return }
        settings.settings.curve.points.removeAll { $0.id == selectedID }
        self.selectedID = nil
    }
}
