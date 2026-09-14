import Foundation
import Darwin

// Read-only microbenchmark. Compile with the SMC sources and sensor bridge.
// Never opens the helper or writes fan settings. CPU time excludes time asleep.
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

let iterations = max(1, Int(CommandLine.arguments.dropFirst().first ?? "100") ?? 100)
let kit = try SMCKit(allowKeysEndpointFallback: true)
let includeAll = !CommandLine.arguments.contains("--curated")
var temperatureCount = 0
var fanCount = 0
var hidCount = 0
func sample() throws {
    try autoreleasepool {
        fanCount = try kit.readFans().count
        temperatureCount = kit.readTemperatures(includeAll: includeAll).count
        hidCount = 0
        CoolDownEnumerateHIDTemperatures { _, _ in hidCount += 1 }
    }
}
try sample()
let cpuStart = cpuSeconds()
let wallStart = ProcessInfo.processInfo.systemUptime
for _ in 0..<iterations { try sample() }
let wall = ProcessInfo.processInfo.systemUptime - wallStart
let cpu = cpuSeconds() - cpuStart
print(String(format: "samples=%d fans=%d smcTemps=%d hidTemps=%d CPU_ms/sample=%.3f wall_ms/sample=%.3f", iterations, fanCount, temperatureCount, hidCount, cpu * 1000 / Double(iterations), wall * 1000 / Double(iterations)))
