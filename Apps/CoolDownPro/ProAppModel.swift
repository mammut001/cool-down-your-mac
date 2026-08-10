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
    @Published var targetFanPercent: Double = 0
    @Published var loadBoostPercent: Double = 0
    @Published var controlTemperatureC: Double?
    @Published var shouldPresentHelperSetup = false
    @Published private(set) var helperLaunchFailed = false

    let settings = SettingsStore()
    let helper = HelperClient.shared
    let loadMonitor = LoadMonitor()
    private let curveEngine = SmartCurveEngine()
    private var timer: Timer?
    private var lastAlertAt: Date?
    private let helperSetupPromptShownKey = "hasShownHelperSetupPrompt"
    /// Avoid re-prompting admin auth / rewriting the same fan command every poll tick.
    private var lastAppliedFanCommand: String?

    var menuBarTitle: String {
        SensorFormatting.menuBarTitle(
            temp: snapshot.maxTemperatureC,
            mode: settings.settings.mode,
            showTemp: settings.settings.showTemperatureInMenuBar
        )
    }

    /// Registration is the reliable source of truth here. An XPC connection can
    /// be briefly unavailable while launchd starts an already-installed helper.
    var helperIsRegistered: Bool {
        helper.helperStatus == .enabled
    }

    var helperControlIsReady: Bool {
        helper.isConnected && snapshot.helperAvailable && snapshot.canControlFans && !snapshot.fans.isEmpty
    }

    var helperNeedsSetup: Bool {
        !helperIsRegistered || helperLaunchFailed || (helper.isConnected && !snapshot.helperAvailable)
    }

    var helperActionTitle: String {
        if helperIsRegistered && !helperControlIsReady { return "Repair Fan Control…" }
        return helper.helperStatus == .requiresApproval ? "Approve Fan Control…" : "Enable Fan Control…"
    }

    var fanControlUnavailableOnThisMac: Bool {
        helper.isConnected && snapshot.helperAvailable && (!snapshot.canControlFans || snapshot.fans.isEmpty)
    }

    init() {
        Self.sharedOnTerminate = { [weak self] in
            await self?.restoreAutoOnExit()
        }
        helper.reconnect()
        applyLaunchAtLogin()
        startPolling()
        requestNotificationPermission()
        // Make setup a one-time, explicit decision instead of leaving a
        // persistent warning in the interface.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self,
                  self.helperNeedsSetup,
                  !UserDefaults.standard.bool(forKey: self.helperSetupPromptShownKey) else { return }
            UserDefaults.standard.set(true, forKey: self.helperSetupPromptShownKey)
            self.shouldPresentHelperSetup = true
        }
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
        loadMonitor.refresh()
        await refreshSnapshot()
        await applyControlPolicy()
        evaluateAlerts()
    }

    func refreshSnapshot() async {
        let hidTemps = IOHIDTemperatureReader.readAll()
        let localSMC = DirectSMCReader.readSnapshot()
        let smcTemps = (localSMC?.temperatures ?? []).map(SensorMerge.annotateSMC)
        let curated = SensorCatalog.curated(smc: smcTemps, hid: hidTemps)
        let mergedAll = SensorCatalog.allMerged(smc: smcTemps, hid: hidTemps)
        allTemperatures = mergedAll
        let displayTemps = showAllSensors ? mergedAll : curated

        // Fan RPM is readable without the helper; always prefer a healthy local SMC read
        // so a stale/broken helper snapshot cannot force the UI to show 0 RPM.
        let localFans = localSMC?.fans ?? []

        if helper.isConnected || helper.helperStatus == .enabled {
            do {
                var remote = try await helper.fetchSnapshot()
                remote.temperatures = displayTemps
                remote.fans = preferredFans(remote: remote.fans, local: localFans)
                snapshot = remote
                helperLaunchFailed = false
                if fanControlUnavailableOnThisMac {
                    // Do not leave the app in Manual/Smart Curve after the helper
                    // has explicitly reported that it cannot address a fan.
                    settings.settings.mode = .systemAuto
                    targetFanPercent = 0
                    loadBoostPercent = 0
                    lastAppliedFanCommand = nil
                    statusMessage = "Fan telemetry is unavailable on this Mac. Manual speed was not applied."
                } else {
                    statusMessage = nil
                }
            } catch {
                helperLaunchFailed = helperIsRegistered
                applyLocalSnapshot(localSMC: localSMC, temperatures: displayTemps, helperError: error)
            }
        } else {
            applyLocalSnapshot(localSMC: localSMC, temperatures: displayTemps, helperError: nil)
        }

        controlTemperatureC = snapshot.primaryTemperature?.celsius ?? snapshot.maxTemperatureC
    }

    private func preferredFans(remote: [FanInfo], local: [FanInfo]) -> [FanInfo] {
        let remoteAlive = remote.contains { $0.currentRPM > 1 }
        let localAlive = local.contains { $0.currentRPM > 1 }
        if localAlive && !remoteAlive { return local }
        if remote.isEmpty { return local }
        return remote
    }

    private func applyLocalSnapshot(
        localSMC: SensorSnapshot?,
        temperatures: [TemperatureReading],
        helperError: Error?
    ) {
        if var local = localSMC {
            local.temperatures = temperatures
            snapshot = local
            statusMessage = "Read-only (install helper to control fans)"
        } else if !temperatures.isEmpty {
            snapshot = SensorSnapshot(
                fans: [],
                temperatures: temperatures,
                canControlFans: false,
                helperAvailable: false
            )
            statusMessage = "Sensors available — install helper to control fans"
        } else if let helperError {
            statusMessage = helperError.localizedDescription
        }
    }

    func applyControlPolicy() async {
        let mode = settings.settings.mode
        // Fan writes are deliberately helper-only. Falling back to an
        // administrator AppleScript here makes a timer look like repeated user
        // authorization requests, which is both surprising and disruptive.
        guard helperControlIsReady else {
            if mode != .systemAuto {
                statusMessage = fanControlUnavailableOnThisMac
                    ? "Manual fan control is unavailable on this Mac."
                    : "Enable fan control once to use Manual or Smart Curve."
            }
            return
        }
        do {
            switch mode {
            case .systemAuto:
                targetFanPercent = 0
                loadBoostPercent = 0
                curveEngine.reset()
                loadMonitor.resetFanBoost()
                try await applyFanWrite(
                    commandKey: "auto",
                    remote: { try await helper.setFansAuto() }
                )
            case .manual:
                loadBoostPercent = 0
                targetFanPercent = settings.settings.manualPercent
                curveEngine.reset()
                loadMonitor.resetFanBoost()
                let percent = settings.settings.manualPercent
                try await applyFanWrite(
                    commandKey: String(format: "manual-%.3f", percent),
                    remote: { try await helper.setFansPercent(percent) }
                )
            case .smartCurve:
                guard let temp = controlTemperatureC else { return }
                let boost = loadMonitor.fanBoost(
                    threshold: settings.settings.loadBoostThreshold,
                    boostMax: settings.settings.loadBoostMax
                )
                loadBoostPercent = boost
                let percent = curveEngine.targetPercent(
                    temperatureC: temp,
                    profile: settings.settings.curve,
                    loadBoost: boost
                )
                targetFanPercent = percent
                try await applyFanWrite(
                    commandKey: String(format: "smart-%.3f", percent),
                    remote: { try await helper.setFansPercent(percent) }
                )
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// The registered helper owns all fan writes after the one-time macOS approval.
    private func applyFanWrite(
        commandKey: String,
        remote: () async throws -> Void
    ) async throws {
        if lastAppliedFanCommand == commandKey {
            return
        }
        try await remote()
        lastAppliedFanCommand = commandKey
        statusMessage = nil
    }

    func installHelper() {
        isBusy = true
        defer { isBusy = false }
        do {
            // Never unregister an existing daemon merely because the user
            // opened this screen. Re-registering a service that is already
            // pending approval resets macOS's authorization state and causes
            // an unnecessary password prompt on every launch.
            switch helper.helperStatus {
            case .enabled:
                // SMJobBless atomically replaces an existing tool. This keeps
                // the privileged SMC implementation in sync with app updates.
                try helper.installHelper()
                helperLaunchFailed = false
                statusMessage = "Fan control helper updated"
            case .requiresApproval:
                // A new app bundle version can inherit a stale Service
                // Management record. Replace it once so launchd receives the
                // helper path and signing requirement from this release.
                try? helper.uninstallHelper()
                try helper.installHelper()
                helperLaunchFailed = false
                statusMessage = "Fan control is ready for approval"
            case .notRegistered, .notFound:
                try helper.installHelper()
                helperLaunchFailed = false
                statusMessage = "Fan control is ready for approval"
            @unknown default:
                try helper.installHelper()
                helperLaunchFailed = false
                statusMessage = "Fan control is ready for approval"
            }
            helper.reconnect()
            Task {
                // launchd may need a moment before the first XPC request.
                try? await Task.sleep(for: .milliseconds(600))
                await refreshSnapshot()
                if !helperIsRegistered {
                    statusMessage = "Allow fan control in System Settings, then reopen Cool Down Pro."
                }
            }
        } catch {
            statusMessage = error.localizedDescription
            shouldPresentHelperSetup = true
        }
    }

    func requestHelperSetup() {
        shouldPresentHelperSetup = true
    }

    /// Unregister + register to force launchd to load a newly built helper binary.
    func reinstallHelper() {
        isBusy = true
        defer { isBusy = false }
        do {
            try? helper.uninstallHelper()
            try helper.installHelper()
            statusMessage = "Helper reinstalled — toggle CoolDownPro in Login Items if it does not start"
            helper.reconnect()
            Task { await refreshSnapshot() }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setMode(_ mode: ControlMode) {
        settings.settings.mode = mode
        lastAppliedFanCommand = nil
        if mode != .smartCurve {
            curveEngine.reset()
            loadMonitor.resetFanBoost()
        }
        Task { await applyControlPolicy() }
    }

    func setManualPercent(_ percent: Double) {
        settings.settings.manualPercent = percent
        settings.settings.mode = .manual
        curveEngine.reset()
        loadMonitor.resetFanBoost()
        lastAppliedFanCommand = nil // force write on slider changes
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
