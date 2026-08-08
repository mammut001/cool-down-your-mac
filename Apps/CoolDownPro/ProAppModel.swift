import Foundation
import Combine
import SwiftUI
import CoolDownKit
import ServiceManagement
import UserNotifications

@MainActor
final class ProAppModel: ObservableObject {
    static var sharedOnTerminate: (() async -> Void)?

    @Published var snapshot = SensorSnapshot()
    @Published var allTemperatures: [TemperatureReading] = []
    @Published var showAllSensors = false
    @Published var statusMessage: String?
    @Published var isBusy = false

    let settings = SettingsStore()
    let helper = HelperClient.shared
    private let curveEngine = SmartCurveEngine()
    private var timer: Timer?
    private var lastAlertAt: Date?

    var menuBarTitle: String {
        SensorFormatting.menuBarTitle(
            temp: snapshot.maxTemperatureC,
            mode: settings.settings.mode,
            showTemp: settings.settings.showTemperatureInMenuBar
        )
    }

    init() {
        Self.sharedOnTerminate = { [weak self] in
            await self?.restoreAutoOnExit()
        }
        helper.reconnect()
        applyLaunchAtLogin()
        startPolling()
        requestNotificationPermission()
    }

    func startPolling() {
        timer?.invalidate()
        let interval = max(1.0, settings.settings.sampleIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.tick()
            }
        }
        Task { await tick() }
    }

    func tick() async {
        await refreshSnapshot()
        await applyControlPolicy()
        evaluateAlerts()
    }

    func refreshSnapshot() async {
        let hidTemps = IOHIDTemperatureReader.readAll()
        // Prefer in-process SMC reads (correct float endian) for temperature completeness.
        let localSMC = DirectSMCReader.readSnapshot()
        let smcTemps = (localSMC?.temperatures ?? []).map(SensorMerge.annotateSMC)
        let curated = SensorCatalog.curated(smc: smcTemps, hid: hidTemps)
        let mergedAll = SensorCatalog.allMerged(smc: smcTemps, hid: hidTemps)
        allTemperatures = mergedAll

        do {
            var remote = try await helper.fetchSnapshot()
            // Keep helper fans/control flags; replace temps with curated/local list.
            remote.temperatures = showAllSensors ? mergedAll : curated
            if let localSMC {
                if remote.fans.isEmpty { remote.fans = localSMC.fans }
            }
            snapshot = remote
            statusMessage = nil
        } catch {
            if var local = localSMC {
                local.temperatures = showAllSensors ? mergedAll : curated
                snapshot = local
                statusMessage = "Read-only (install helper to control fans)"
            } else if !curated.isEmpty {
                snapshot = SensorSnapshot(
                    fans: [],
                    temperatures: curated,
                    canControlFans: false,
                    helperAvailable: false
                )
                statusMessage = "Sensors available — install helper to control fans"
            } else {
                statusMessage = error.localizedDescription
            }
        }
    }

    func applyControlPolicy() async {
        guard snapshot.helperAvailable || helper.isConnected else { return }
        let mode = settings.settings.mode
        do {
            switch mode {
            case .systemAuto:
                try await helper.setFansAuto()
                curveEngine.reset()
            case .manual:
                try await helper.setFansPercent(settings.settings.manualPercent)
            case .smartCurve:
                guard let temp = snapshot.primaryTemperature?.celsius ?? snapshot.maxTemperatureC else { return }
                let percent = curveEngine.targetPercent(temperatureC: temp, profile: settings.settings.curve)
                try await helper.setFansPercent(percent)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func installHelper() {
        isBusy = true
        defer { isBusy = false }
        do {
            try helper.installHelper()
            statusMessage = "Helper registered — approve in System Settings if prompted"
            Task { await refreshSnapshot() }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setMode(_ mode: ControlMode) {
        settings.settings.mode = mode
        if mode == .systemAuto {
            curveEngine.reset()
        }
        Task { await applyControlPolicy() }
    }

    func setManualPercent(_ percent: Double) {
        settings.settings.manualPercent = percent
        settings.settings.mode = .manual
        Task { await applyControlPolicy() }
    }

    func restoreAutoOnExit() async {
        guard settings.settings.mode != .systemAuto else { return }
        try? await helper.setFansAuto()
    }

    func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if settings.settings.launchAtLogin {
                try service.register()
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            statusMessage = "Launch at login: \(error.localizedDescription)"
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func evaluateAlerts() {
        guard settings.settings.alertsEnabled,
              let temp = snapshot.maxTemperatureC,
              temp >= settings.settings.alertTemperatureC else { return }
        if let last = lastAlertAt, Date().timeIntervalSince(last) < 120 { return }
        lastAlertAt = Date()
        let content = UNMutableNotificationContent()
        content.title = "Cool Down Pro"
        content.body = String(format: "Temperature reached %.0f°C", temp)
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
