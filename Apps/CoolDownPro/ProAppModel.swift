import Foundation
import Combine
import SwiftUI
import CoolDownKit
import ServiceManagement
import UserNotifications
import os

@MainActor
final class ProAppModel: ObservableObject {
    #if DEBUG
    private let smartCurveLogger = Logger(subsystem: "com.cooldown.CoolDownPro", category: "SmartCurve")
    private let smartCurveCSV = SmartCurveCSVWriter()
    #endif
    static var sharedOnTerminate: (() async -> Void)?
    static weak var sharedInstance: ProAppModel?
    static func performSyncRestoreIfNeeded() {
        sharedInstance?.restoreAutoOnExitSync()
    }

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
    private var controlGeneration = 0
    private var isTicking = false
    private var cancellables = Set<AnyCancellable>()

    var menuBarTitle: String {
        SensorFormatting.menuBarTitle(
            temp: snapshot.displayTemperatureC,
            mode: settings.settings.mode,
            showTemp: settings.settings.showTemperatureInMenuBar
        )
    }

    /// An XPC connection can be briefly unavailable while launchd starts an
    /// already-installed helper, so installation and readiness are kept as two
    /// separate states.
    var helperIsRegistered: Bool {
        helper.isHelperInstalled
    }

    var helperControlIsReady: Bool {
        helper.isConnected && snapshot.helperAvailable && snapshot.canControlFans && !snapshot.fans.isEmpty
    }

    var helperNeedsSetup: Bool {
        !helperIsRegistered || helperLaunchFailed || (helper.isConnected && !snapshot.helperAvailable)
    }

    var helperActionTitle: String {
        if !helperIsRegistered { return "Enable Fan Control…" }
        if helperLaunchFailed { return "Repair Fan Control…" }
        if !helperControlIsReady { return "Reconnect Fan Control" }
        return "Fan Control Enabled"
    }

    var helperActionIsEnabled: Bool {
        !helperControlIsReady && !fanControlUnavailableOnThisMac
    }

    var helperStatusText: String {
        if helperControlIsReady { return "Enabled" }
        if !helperIsRegistered { return "Not installed" }
        if helperLaunchFailed { return "Needs repair" }
        if fanControlUnavailableOnThisMac { return "Unavailable on this Mac" }
        return "Connecting…"
    }

    var helperSetupTitle: String {
        helperIsRegistered ? "Repair fan control?" : "Enable fan control?"
    }

    var helperSetupConfirmTitle: String {
        helperIsRegistered ? "Repair" : "Continue"
    }

    var helperSetupMessage: String {
        if helperIsRegistered {
            return "Cool Down Pro will replace its fan-control helper. macOS will ask for an administrator password. Only repair it when the installed helper cannot connect."
        }
        return "Cool Down Pro needs your approval once to install its fan-control helper. macOS will ask for an administrator password next."
    }

    var fanControlUnavailableOnThisMac: Bool {
        helper.isConnected && snapshot.helperAvailable && (!snapshot.canControlFans || snapshot.fans.isEmpty)
    }

    init() {
        Self.sharedInstance = self
        Self.sharedOnTerminate = { [weak self] in
            await self?.restoreAutoOnExit()
        }
        helper.reconnect()
        applyLaunchAtLogin()
        startPolling()
        requestNotificationPermission()
        helper.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.helper.isConnected {
                    self.lastAppliedFanCommand = nil
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
        settings.$settings
            .map(\.sampleIntervalSeconds)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.startPolling() }
            .store(in: &cancellables)
        settings.$settings
            .map(\.launchAtLogin)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.applyLaunchAtLogin() }
            .store(in: &cancellables)
        // Make setup a one-time, explicit decision instead of leaving a
        // persistent warning in the interface.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self,
                  !self.helperIsRegistered,
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
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
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
        let controlTemps = SensorCatalog.controlReadings(smc: smcTemps, hid: hidTemps)
        allTemperatures = mergedAll
        let displayTemps = showAllSensors ? mergedAll : curated

        // Fan RPM is readable without the helper; always prefer a healthy local SMC read
        // so a stale/broken helper snapshot cannot force the UI to show 0 RPM.
        let localFans = localSMC?.fans ?? []

        if helper.isConnected || helper.isHelperInstalled {
            do {
                var remote = try await helper.fetchSnapshot()
                remote.temperatures = displayTemps
                remote.fans = preferredFans(remote: remote.fans, local: localFans)
                snapshot = remote
                helperLaunchFailed = false
                if fanControlUnavailableOnThisMac {
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

        let finite = controlTemps.map(\.celsius).filter { $0.isFinite && $0 > 0 && $0 < 150 }
        controlTemperatureC = finite.max()
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
            lastAppliedFanCommand = nil
            statusMessage = helperError.localizedDescription
        }
    }

    func applyControlPolicy() async {
        controlGeneration += 1
        let generation = controlGeneration
        let mode = fanControlUnavailableOnThisMac ? .systemAuto : settings.settings.mode
        // Fan writes are deliberately helper-only. Falling back to an
        // administrator AppleScript here makes a timer look like repeated user
        // authorization requests, which is both surprising and disruptive.
        guard helperControlIsReady else {
            if settings.settings.mode != .systemAuto {
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
                    generation: generation,
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
                    generation: generation,
                    remote: { try await helper.setFansPercent(percent) }
                )
            case .smartCurve:
                guard let temp = controlTemperatureC, temp.isFinite else {
                    try await applyFanWrite(
                        commandKey: "auto-failsafe",
                        generation: generation,
                        remote: { try await helper.setFansAuto() }
                    )
                    return
                }
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
                    generation: generation,
                    remote: { try await helper.setFansPercent(percent) }
                )
                #if DEBUG
                let diagnostics = curveEngine.diagnostics
                smartCurveLogger.info(
                    "[SmartCurve] rawTemp=\(diagnostics.rawTemperatureC, format: .fixed(precision: 1)) filteredTemp=\((diagnostics.filteredTemperatureC ?? temp), format: .fixed(precision: 1)) curve=\(diagnostics.curvePercent * 100, format: .fixed(precision: 1))% cpuLoad=\(self.loadMonitor.cpuLoadPercent, format: .fixed(precision: 1))% boost=\(diagnostics.loadBoostPercent * 100, format: .fixed(precision: 1))% desired=\(diagnostics.desiredPercent * 100, format: .fixed(precision: 1))% final=\(diagnostics.finalPercent * 100, format: .fixed(precision: 1))% hold=\(diagnostics.cooldownRemainingSeconds, format: .fixed(precision: 1))s hot=\(diagnostics.isHotResponse) emergency=\(diagnostics.isEmergency) mode=\(mode.rawValue)"
                )
                let fans = snapshot.fans.isEmpty ? [FanInfo(index: -1, name: "unknown", minRPM: 0, maxRPM: 0, currentRPM: 0)] : snapshot.fans
                let rows = fans.map { fan in
                    SmartCurveCSVRow(
                        timestamp: Date(),
                        uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                        mode: mode.rawValue,
                        rawTemperatureC: diagnostics.rawTemperatureC,
                        filteredTemperatureC: diagnostics.filteredTemperatureC ?? temp,
                        cpuLoadPercent: loadMonitor.cpuLoadPercent,
                        curvePercent: diagnostics.curvePercent,
                        loadBoostPercent: diagnostics.loadBoostPercent,
                        desiredPercent: diagnostics.desiredPercent,
                        finalPercent: diagnostics.finalPercent,
                        targetRPM: fan.targetRPM,
                        actualRPM: fan.currentRPM,
                        holdRemainingSeconds: diagnostics.cooldownRemainingSeconds,
                        emergencyState: diagnostics.isEmergency ? "emergency" : (diagnostics.isHotResponse ? "hot" : "normal"),
                        sampleIntervalSeconds: settings.settings.sampleIntervalSeconds,
                        hottestProcessName: loadMonitor.hottestProcessName,
                        hottestProcessPercent: loadMonitor.hottestProcessPercent,
                        fanIndex: fan.index
                    )
                }
                smartCurveCSV.append(rows)
                #endif
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// The registered helper owns all fan writes after the one-time macOS approval.
    private func applyFanWrite(
        commandKey: String,
        generation: Int,
        remote: () async throws -> Void
    ) async throws {
        if lastAppliedFanCommand == commandKey {
            return
        }
        try await remote()
        guard generation == controlGeneration else { return }
        lastAppliedFanCommand = commandKey
        statusMessage = nil
    }

    func installHelper() {
        isBusy = true
        defer { isBusy = false }
        do {
            // Never acquire administrator rights merely because an installed
            // helper is still starting. Repair is a separate, explicit action.
            guard !helper.isHelperInstalled else {
                helper.reconnect()
                statusMessage = "Fan control helper is already installed"
                Task { await refreshSnapshot() }
                return
            }
            try helper.installHelper()
            helperLaunchFailed = false
            statusMessage = "Fan control helper installed"
            helper.reconnect()
            Task {
                // launchd may need a moment before the first XPC request.
                try? await Task.sleep(for: .milliseconds(600))
                await refreshSnapshot()
                if !helperIsRegistered {
                    statusMessage = "Fan control helper was not installed. Try again and check the administrator password."
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func requestHelperSetup() {
        shouldPresentHelperSetup = true
    }

    func performHelperSetup() {
        if helperIsRegistered {
            reinstallHelper()
        } else {
            installHelper()
        }
    }

    func performHelperAction() {
        if !helperIsRegistered || helperLaunchFailed {
            requestHelperSetup()
        } else {
            helper.reconnect()
            statusMessage = "Reconnecting to fan control…"
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                await refreshSnapshot()
            }
        }
    }

    /// Explicitly replace the installed helper so launchd loads the bundled copy.
    func reinstallHelper() {
        isBusy = true
        defer { isBusy = false }
        do {
            helper.disconnect()
            try helper.installHelper(replacingExisting: true)
            helperLaunchFailed = false
            statusMessage = "Fan control helper repaired"
            helper.reconnect()
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                await refreshSnapshot()
            }
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

    /// Synchronous restore for applicationWillTerminate. Must not wait on a
    /// MainActor Task — that deadlocks the terminate callback.
    func restoreAutoOnExitSync(timeoutSeconds: TimeInterval = 1.2) {
        guard settings.settings.mode != .systemAuto else { return }
        HelperClient.setFansAutoBlocking(timeout: timeoutSeconds)
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

#if DEBUG
private struct SmartCurveCSVRow: Sendable {
    let timestamp: Date
    let uptimeSeconds: TimeInterval
    let mode: String
    let rawTemperatureC: Double
    let filteredTemperatureC: Double
    let cpuLoadPercent: Double
    let curvePercent: Double
    let loadBoostPercent: Double
    let desiredPercent: Double
    let finalPercent: Double
    let targetRPM: Double?
    let actualRPM: Double
    let holdRemainingSeconds: TimeInterval
    let emergencyState: String
    let sampleIntervalSeconds: Double
    let hottestProcessName: String
    let hottestProcessPercent: Double
    let fanIndex: Int
}

private final class SmartCurveCSVWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cooldown.CoolDownPro.smartcurve-csv", qos: .utility)
    private let url = URL(fileURLWithPath: "/tmp/cooldown-smartcurve.csv")
    private let header = "timestamp,uptime_seconds,mode,raw_temp_c,filtered_temp_c,cpu_load_percent,curve_percent,load_boost_percent,desired_percent,final_percent,target_rpm,actual_rpm,hold_remaining_seconds,emergency_state,sample_interval_seconds,hottest_process_name,hottest_process_percent,fan_index\n"

    init() {}

    func append(_ rows: [SmartCurveCSVRow]) {
        guard !rows.isEmpty else { return }
        queue.async { [url, header] in
            do {
                let formatter = ISO8601DateFormatter()
                let manager = FileManager.default
                let fileSize = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if !manager.fileExists(atPath: url.path) || fileSize == 0 {
                    try header.data(using: .utf8)?.write(to: url, options: .atomic)
                }
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                defer { try? handle.close() }
                try handle.seekToEnd()
                let lines = rows.map { row in
                    [
                        formatter.string(from: row.timestamp),
                        self.format(row.uptimeSeconds),
                        self.csv(row.mode),
                        self.format(row.rawTemperatureC),
                        self.format(row.filteredTemperatureC),
                        self.format(row.cpuLoadPercent),
                        self.format(row.curvePercent * 100),
                        self.format(row.loadBoostPercent * 100),
                        self.format(row.desiredPercent * 100),
                        self.format(row.finalPercent * 100),
                        row.targetRPM.map { self.format($0) } ?? "",
                        self.format(row.actualRPM),
                        self.format(row.holdRemainingSeconds),
                        self.csv(row.emergencyState),
                        self.format(row.sampleIntervalSeconds),
                        self.csv(row.hottestProcessName),
                        self.format(row.hottestProcessPercent),
                        String(row.fanIndex)
                    ].joined(separator: ",")
                }.joined(separator: "\n") + "\n"
                try handle.write(contentsOf: Data(lines.utf8))
            } catch {
                // Telemetry must never affect fan-control behavior.
            }
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func csv(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
#endif
