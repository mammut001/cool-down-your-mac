import Foundation
import CoolDownKit
import Darwin

/// Lightweight CPU load sampler used to boost fan speed under sustained work.
@MainActor
final class LoadMonitor: ObservableObject {
    @Published private(set) var cpuLoadPercent: Double = 0
    @Published private(set) var hottestProcessPercent: Double = 0
    @Published private(set) var hottestProcessName: String = "—"

    private var previousCPUTicks: [UInt32]?
    private var loadAboveThresholdSince: TimeInterval?
    private var smoothedFanBoost: Double = 0
    private var lastBoostUpdateUptime: TimeInterval?
    #if DEBUG
    private var lastProcessSampleUptime: TimeInterval?
    #endif

    private let boostActivationSeconds: TimeInterval = 4
    private let boostReleaseHysteresisPercent = 8.0
    private let boostRiseTimeConstant: TimeInterval = 4
    private let boostFallTimeConstant: TimeInterval = 12
    #if DEBUG
    #if arch(x86_64)
    private let processSampleIntervalSeconds: TimeInterval = 10
    #else
    private let processSampleIntervalSeconds: TimeInterval = 6
    #endif
    #endif

    func refresh() {
        cpuLoadPercent = sampleSystemCPULoad() ?? cpuLoadPercent

        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        if lastProcessSampleUptime == nil || now - (lastProcessSampleUptime ?? 0) >= processSampleIntervalSeconds {
            lastProcessSampleUptime = now
            let (_, procs) = Self.sampleProcesses(limit: 8)
            if let top = procs.first {
                hottestProcessPercent = top.cpuPercent
                hottestProcessName = top.name
            } else {
                hottestProcessPercent = 0
                hottestProcessName = "—"
            }
        }
        #endif
    }

    func resetFanBoost() {
        loadAboveThresholdSince = nil
        smoothedFanBoost = 0
        lastBoostUpdateUptime = nil
    }

    /// Uses kernel CPU tick deltas rather than `p_estcpu`, which is a stale
    /// scheduler estimate and can remain zero while CPU-bound work is running.
    private func sampleSystemCPULoad() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        ) == KERN_SUCCESS, let info else {
            return nil
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount)).map { UInt32(bitPattern: $0) }
        defer { previousCPUTicks = ticks }
        guard let previous = previousCPUTicks else { return 0 }
        return CPULoadCalculator.computeSystemLoadPercent(currentTicks: ticks, previousTicks: previous) ?? cpuLoadPercent
    }

    /// Returns a smoothed 0...boostMax value based on sustained *system* CPU
    /// load. Per-process estimates remain useful for the UI, but are too noisy
    /// to directly drive fan commands.
    func fanBoost(threshold: Double, boostMax: Double) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = elapsedBoostSeconds(now: now)
        let threshold = threshold.clamped(to: 20...95)
        let boostMax = boostMax.clamped(to: 0...0.4)

        guard boostMax > 0 else {
            resetFanBoost()
            return 0
        }

        let load = cpuLoadPercent.clamped(to: 0...100)
        if load > threshold {
            if loadAboveThresholdSince == nil {
                loadAboveThresholdSince = now
            }
        } else if load < threshold - boostReleaseHysteresisPercent {
            loadAboveThresholdSince = nil
        }

        let sustained = loadAboveThresholdSince.map { now - $0 >= boostActivationSeconds } ?? false
        let desired: Double
        if sustained, load > threshold {
            let span = max(100 - threshold, 1)
            let t = ((load - threshold) / span).clamped(to: 0...1)
            desired = boostMax * t
        } else {
            desired = 0
        }

        // Approach boost slowly and release even more slowly so short-lived CPU
        // bursts do not translate into audible fan pulses.
        let timeConstant = desired > smoothedFanBoost
            ? boostRiseTimeConstant
            : boostFallTimeConstant
        let alpha = 1 - exp(-dt / timeConstant)
        smoothedFanBoost += (desired - smoothedFanBoost) * alpha
        if smoothedFanBoost < 0.001 {
            smoothedFanBoost = 0
        }
        return smoothedFanBoost.clamped(to: 0...boostMax)
    }

    private func elapsedBoostSeconds(now: TimeInterval) -> TimeInterval {
        defer { lastBoostUpdateUptime = now }
        guard let lastBoostUpdateUptime else { return 2 }
        return (now - lastBoostUpdateUptime).clamped(to: 0.25...10)
    }

    #if DEBUG
    private static func sampleProcesses(limit: Int) -> (Double, [HotProcess]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return (0, [])
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else {
            return (0, [])
        }

        let actual = size / MemoryLayout<kinfo_proc>.stride
        var result: [HotProcess] = []
        for index in 0..<actual {
            let kp = procs[index]
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }
            let name = processName(from: kp)
            if name.hasPrefix("kernel") || name == "launchd" { continue }
            let approx = Double(kp.kp_proc.p_estcpu) / 10.0
            if approx < 1 { continue }
            result.append(HotProcess(pid: pid, name: name, cpuPercent: min(approx, 100)))
        }

        result.sort { $0.cpuPercent > $1.cpuPercent }
        let top = Array(result.prefix(limit))
        let total = min(top.reduce(0.0) { $0 + $1.cpuPercent }, 100)
        return (total, top)
    }

    private static func processName(from kp: kinfo_proc) -> String {
        withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            let chars = raw.bindMemory(to: CChar.self)
            return String(cString: chars.baseAddress!)
        }
    }
    #endif
}
