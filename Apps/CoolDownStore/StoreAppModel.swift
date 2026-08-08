import Foundation
import Combine
import SwiftUI
import CoolDownKit
import ServiceManagement
import UserNotifications

@MainActor
final class StoreAppModel: ObservableObject {
    @Published var pressure: ThermalPressureLevel = .nominal
    @Published var hotProcesses: [HotProcess] = []
    @Published var cpuLoadPercent: Double = 0
    @Published var statusMessage: String?
    @Published var coachingTip: String = "Keep vents clear and quit heavy apps when thermal pressure rises."

    let settings = SettingsStore()
    let coach = ThermalCoach()
    private var timer: Timer?
    private var lastAlertAt: Date?

    var menuBarTitle: String {
        if settings.settings.showTemperatureInMenuBar {
            return pressure.displayName
        }
        return "Cool"
    }

    init() {
        applyLaunchAtLogin()
        startPolling()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func startPolling() {
        timer?.invalidate()
        let interval = max(1.5, settings.settings.sampleIntervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        coach.refresh()
        pressure = coach.pressure
        hotProcesses = coach.hotProcesses
        cpuLoadPercent = coach.cpuLoadPercent
        coachingTip = tip(for: pressure)
        evaluateAlerts()
    }

    func coolDownNow() {
        // Soft cool-down: terminate the hottest non-system process the user confirms via UI buttons.
        statusMessage = "Select a process below to quit and reduce heat."
        refresh()
    }

    func quitProcess(_ process: HotProcess) {
        if coach.terminate(process: process) {
            statusMessage = "Quit \(process.name)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.refresh()
            }
        } else {
            statusMessage = "Could not quit \(process.name)"
        }
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
            statusMessage = error.localizedDescription
        }
    }

    private func tip(for level: ThermalPressureLevel) -> String {
        switch level {
        case .nominal:
            return "Thermal pressure is nominal. Smart cool-down is standing by."
        case .fair:
            return "Warming up — close unused browsers or pause exports to stay cool."
        case .serious:
            return "Serious thermal pressure — quit heavy apps or plug into power and elevate the Mac."
        case .critical:
            return "Critical heat — stop intensive tasks now and let the system recover."
        }
    }

    private func evaluateAlerts() {
        guard settings.settings.alertsEnabled else { return }
        guard pressure == .serious || pressure == .critical else { return }
        if let last = lastAlertAt, Date().timeIntervalSince(last) < 180 { return }
        lastAlertAt = Date()
        let content = UNMutableNotificationContent()
        content.title = "Cool Down"
        content.body = "Thermal pressure is \(pressure.displayName.lowercased())."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
