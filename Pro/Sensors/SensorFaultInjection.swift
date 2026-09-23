import Foundation

#if DEBUG
/// A process-specific marker lets a signed Debug app exercise the complete
/// missing-telemetry policy against the real helper without touching AppleSMC.
enum SensorFaultInjection {
    static var outageMarkerPath: String {
        "/tmp/com.cooldown.CoolDownPro.sensor-outage.\(ProcessInfo.processInfo.processIdentifier)"
    }

    static var isOutageActive: Bool {
        FileManager.default.fileExists(atPath: outageMarkerPath)
    }
}
#endif
