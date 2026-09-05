import Foundation
import CoolDownKit
import Darwin

/// Lightweight cross-thread signal used by direct SMC telemetry so rising CPU
/// load can shorten the temperature cache before the sampled temperature has
/// already climbed. This avoids performing a second CPU-load measurement.
enum ThermalLoadSignal {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var latestLoadPercent: Double?
    }

    private static let state = State()

    static func update(_ loadPercent: Double) {
        guard loadPercent.isFinite else { return }
        state.lock.lock()
        state.latestLoadPercent = min(max(loadPercent, 0), 100)
        state.lock.unlock()
    }

    static var currentLoadPercent: Double? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.latestLoadPercent
    }
}

/// Lightweight CPU load sampler used to boost fan speed under sustained work.
@MainActor
final class LoadMonitor: ObservableObject {
    @Published private(set) var cpuLoadPercent: Double = 0
    @Published private(set) var hottestProcessPercent: Double = 0
    @Published private(set) var hottestProcessName: String = "—"

    private var previousCPUTicksTuple: (UInt32, UInt32, UInt32, UInt32)?
    private var loadAboveThresholdSince: TimeInterval?
    private var smoothedFanBoost: Double = 0
    private var lastBoostUpdateUptime: TimeInterval?
    #if DEBUG
    private var lastProcessSampleUptime: TimeInterval?
    #endif

    private let boostReleaseHysteresisPercent = 8.0
    private let boostFallTimeConstant: TimeInterval = 12
    #if DEBUG
    #if arch(x86_64)
    private let processSampleIntervalSeconds: TimeInterval = 10
    #else
    private let processSampleIntervalSeconds: TimeInterval = 6
    #endif
    #endif

    func refresh() {
        if let sampledLoad = sampleSystemCPULoad() {
            cpuLoadPercent = sampledLoad
            ThermalLoadSignal.update(sampledLoad)
        }

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

    /// Uses lightweight stack-allocated Mach host statistics rather than
    /// `host_processor_info`, avoiding kernel vm_allocate/deallocate churn
    /// on every sample tick.
    private func sampleSystemCPULoad() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuInfo = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt32(cpuInfo.cpu_ticks.0)
        let system = UInt32(cpuInfo.cpu_ticks.1)
        let idle = UInt32(cpuInfo.cpu_ticks.2)
        let nice = UInt32(cpuInfo.cpu_ticks.3)
        defer { previousCPUTicksTuple = (user, system, idle, nice) }
        guard let prev = previousCPUTicksTuple else { return 0 }

        let dUser = user &- prev.0
        let dSystem = system &- prev.1
        let dIdle = idle &- prev.2
        let dNice = nice &- prev.3
        let busy = UInt64(dUser) + UInt64(dSystem) + UInt64(dNice)
        let total = busy + UInt64(dIdle)
        guard total > 0 else { return cpuLoadPercent }
        return (Double(busy) / Double(total)) * 100.0
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

        let activationDelay = LoadBoostPolicy.activationDelaySeconds(
            loadPercent: load,
            threshold: threshold
        )
        let sustained = loadAboveThresholdSince.map { now - $0 >= activationDelay } ?? false
        let desired = sustained
            ? LoadBoostPolicy.desiredBoost(
                loadPercent: load,
                threshold: threshold,
                boostMax: boostMax
            )
            : 0

        // Feed forward progressively under real sustained load: the higher the
        // utilization, the shorter the activation delay and rise time. Release
        // remains deliberately slow so load drops do not create fan pulsing.
        let timeConstant = desired > smoothedFanBoost
            ? LoadBoostPolicy.riseTimeConstantSeconds(
                loadPercent: load,
                threshold: threshold
            )
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
