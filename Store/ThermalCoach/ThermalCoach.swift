import Foundation
import CoolDownKit
import Darwin

@MainActor
public final class ThermalCoach: ObservableObject {
    @Published public private(set) var pressure: ThermalPressureLevel = .nominal
    @Published public private(set) var hotProcesses: [HotProcess] = []
    @Published public private(set) var cpuLoadPercent: Double = 0

    public init() {}

    public func refresh() {
        pressure = Self.currentPressure()
        let (load, procs) = Self.sampleProcesses(limit: 8)
        cpuLoadPercent = load
        hotProcesses = procs
    }

    public func terminate(process: HotProcess) -> Bool {
        kill(process.pid, SIGTERM) == 0
    }

    private static func currentPressure() -> ThermalPressureLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .fair
        }
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
        result.reserveCapacity(min(limit, actual))

        // Lightweight heuristic: prefer user processes with non-zero priority hints.
        // Full CPU% needs two-sample rusage; we approximate with task thread counts.
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
        let total = top.reduce(0.0) { $0 + $1.cpuPercent }
        return (min(total, 100), top)
    }

    private static func processName(from kp: kinfo_proc) -> String {
        withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            let chars = raw.bindMemory(to: CChar.self)
            return String(cString: chars.baseAddress!)
        }
    }
}
