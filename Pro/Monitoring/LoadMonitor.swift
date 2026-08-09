import Foundation
import CoolDownKit
import Darwin

/// Lightweight CPU load sampler used to boost fan speed under heavy work.
@MainActor
final class LoadMonitor: ObservableObject {
    @Published private(set) var cpuLoadPercent: Double = 0
    @Published private(set) var hottestProcessPercent: Double = 0
    @Published private(set) var hottestProcessName: String = "—"
    private var previousCPUTicks: [UInt64]?

    func refresh() {
        let (_, procs) = Self.sampleProcesses(limit: 8)
        cpuLoadPercent = sampleSystemCPULoad() ?? cpuLoadPercent
        if let top = procs.first {
            hottestProcessPercent = top.cpuPercent
            hottestProcessName = top.name
        } else {
            hottestProcessPercent = 0
            hottestProcessName = "—"
        }
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

        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount)).map { UInt64($0) }
        defer { previousCPUTicks = ticks }
        guard let previous = previousCPUTicks, previous.count == ticks.count else { return 0 }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for offset in stride(from: 0, to: ticks.count, by: Int(CPU_STATE_MAX)) {
            let user = ticks[offset + Int(CPU_STATE_USER)] - previous[offset + Int(CPU_STATE_USER)]
            let system = ticks[offset + Int(CPU_STATE_SYSTEM)] - previous[offset + Int(CPU_STATE_SYSTEM)]
            let nice = ticks[offset + Int(CPU_STATE_NICE)] - previous[offset + Int(CPU_STATE_NICE)]
            let idle = ticks[offset + Int(CPU_STATE_IDLE)] - previous[offset + Int(CPU_STATE_IDLE)]
            busy += user + system + nice
            total += user + system + nice + idle
        }
        guard total > 0 else { return cpuLoadPercent }
        return (Double(busy) / Double(total) * 100).clamped(to: 0...100)
    }

    /// Returns 0...boostMax based on load vs threshold.
    func fanBoost(threshold: Double, boostMax: Double) -> Double {
        let load = max(cpuLoadPercent, hottestProcessPercent)
        guard load > threshold, boostMax > 0 else { return 0 }
        let span = max(100 - threshold, 1)
        let t = ((load - threshold) / span).clamped(to: 0...1)
        return boostMax * t
    }

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
}
