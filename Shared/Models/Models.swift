import Foundation

public enum ControlMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case systemAuto
    case smartCurve
    case manual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .systemAuto: return String(localized: "System Auto")
        case .smartCurve: return String(localized: "Smart Curve")
        case .manual: return String(localized: "Manual")
        }
    }
}

public struct FanInfo: Identifiable, Codable, Hashable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var name: String
    public var minRPM: Double
    public var maxRPM: Double
    public var currentRPM: Double
    public var targetRPM: Double?
    public var isManual: Bool

    public init(
        index: Int,
        name: String,
        minRPM: Double,
        maxRPM: Double,
        currentRPM: Double,
        targetRPM: Double? = nil,
        isManual: Bool = false
    ) {
        self.index = index
        self.name = name
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.currentRPM = currentRPM
        self.targetRPM = targetRPM
        self.isManual = isManual
    }

    public var percent: Double {
        guard maxRPM > minRPM else { return 0 }
        return ((currentRPM - minRPM) / (maxRPM - minRPM)).clamped(to: 0...1)
    }
}

public enum SensorGroup: String, Codable, Hashable, Sendable, CaseIterable {
    case cpu
    case gpu
    case battery
    case storage
    case wireless
    case other

    public var sortOrder: Int {
        switch self {
        case .cpu: return 0
        case .gpu: return 1
        case .wireless: return 2
        case .battery: return 3
        case .storage: return 4
        case .other: return 5
        }
    }

    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .storage: return "Storage"
        case .wireless: return "Wireless"
        case .other: return "Other"
        }
    }

    /// Used for fan-curve decisions / menu-bar peak temp.
    public var affectsThermalControl: Bool {
        self == .cpu || self == .gpu
    }
}

public struct TemperatureReading: Identifiable, Codable, Hashable, Sendable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var celsius: Double
    public var group: SensorGroup

    public init(key: String, name: String, celsius: Double, group: SensorGroup = .other) {
        self.key = key
        self.name = name
        self.celsius = celsius
        self.group = group
    }
}

public struct CurvePoint: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var temperatureC: Double
    public var fanPercent: Double

    public init(id: UUID = UUID(), temperatureC: Double, fanPercent: Double) {
        self.id = id
        self.temperatureC = temperatureC
        self.fanPercent = fanPercent.clamped(to: 0...1)
    }
}

public struct CurveProfile: Codable, Hashable, Sendable {
    public var name: String
    public var points: [CurvePoint]
    public var hysteresisC: Double

    public init(
        name: String = "Default",
        points: [CurvePoint] = CurveProfile.defaultPoints,
        hysteresisC: Double = 2.0
    ) {
        self.name = name
        self.points = points.sorted { $0.temperatureC < $1.temperatureC }
        self.hysteresisC = hysteresisC
    }

    public static let defaultPoints: [CurvePoint] = [
        CurvePoint(temperatureC: 45, fanPercent: 0.15),
        CurvePoint(temperatureC: 55, fanPercent: 0.30),
        CurvePoint(temperatureC: 65, fanPercent: 0.50),
        CurvePoint(temperatureC: 75, fanPercent: 0.75),
        CurvePoint(temperatureC: 85, fanPercent: 1.00)
    ]

    public func fanPercent(for temperatureC: Double) -> Double {
        let sorted = points.sorted { $0.temperatureC < $1.temperatureC }
        guard let first = sorted.first else { return 0.3 }
        if temperatureC <= first.temperatureC { return first.fanPercent }
        guard let last = sorted.last else { return first.fanPercent }
        if temperatureC >= last.temperatureC { return last.fanPercent }

        for index in 0..<(sorted.count - 1) {
            let a = sorted[index]
            let b = sorted[index + 1]
            if temperatureC >= a.temperatureC && temperatureC <= b.temperatureC {
                let span = b.temperatureC - a.temperatureC
                guard span > 0 else { return b.fanPercent }
                let t = (temperatureC - a.temperatureC) / span
                return a.fanPercent + (b.fanPercent - a.fanPercent) * t
            }
        }
        return last.fanPercent
    }
}

public struct SensorSnapshot: Codable, Hashable, Sendable {
    public var fans: [FanInfo]
    public var temperatures: [TemperatureReading]
    public var timestamp: Date
    public var canControlFans: Bool
    public var helperAvailable: Bool

    public init(
        fans: [FanInfo] = [],
        temperatures: [TemperatureReading] = [],
        timestamp: Date = Date(),
        canControlFans: Bool = false,
        helperAvailable: Bool = false
    ) {
        self.fans = fans
        self.temperatures = temperatures
        self.timestamp = timestamp
        self.canControlFans = canControlFans
        self.helperAvailable = helperAvailable
    }

    public var maxTemperatureC: Double? {
        controlTemperatures.map(\.celsius).max() ?? temperatures.map(\.celsius).max()
    }

    /// User-facing temperature: prefer the calculated CPU average so the
    /// menu bar reflects the general chip temperature rather than a single
    /// transient hotspot.
    public var displayTemperatureC: Double? {
        if let average = temperatures.first(where: { $0.key == "calc.cpu.avg" || $0.key == "hid.cpu.avg" }) {
            return average.celsius
        }
        let cpuTemperatures = temperatures.filter { $0.group == .cpu }
        if !cpuTemperatures.isEmpty {
            return cpuTemperatures.map(\.celsius).reduce(0, +) / Double(cpuTemperatures.count)
        }
        return maxTemperatureC
    }

    /// Thermal-control temperature: use the hottest valid CPU/GPU reading so
    /// a local hotspot cannot be hidden by the display average.
    public var thermalControlTemperatureC: Double? {
        controlTemperatures.map(\.celsius).max() ?? temperatures.map(\.celsius).max()
    }

    public var controlTemperatures: [TemperatureReading] {
        let control = temperatures.filter(\.group.affectsThermalControl)
        return control.isEmpty ? temperatures : control
    }

    public var primaryTemperature: TemperatureReading? {
        if let avg = temperatures.first(where: { $0.key == "hid.cpu.avg" }) {
            return avg
        }
        let preferredKeys = ["TC0P", "TC0E", "TC0F", "Tp09", "Tp0C", "Ts0S", "TG0P"]
        for key in preferredKeys {
            if let match = temperatures.first(where: { $0.key == key }) {
                return match
            }
        }
        return controlTemperatures.max(by: { $0.celsius < $1.celsius })
            ?? temperatures.max(by: { $0.celsius < $1.celsius })
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var mode: ControlMode
    public var curve: CurveProfile
    public var manualPercent: Double
    public var sampleIntervalSeconds: Double
    public var launchAtLogin: Bool
    public var alertTemperatureC: Double
    public var alertsEnabled: Bool
    public var showTemperatureInMenuBar: Bool
    /// Max extra fan fraction added under heavy CPU load in Smart Curve mode (0...0.4).
    public var loadBoostMax: Double
    /// Aggregate process load % above which boost starts ramping.
    public var loadBoostThreshold: Double

    public init(
        mode: ControlMode = .smartCurve,
        curve: CurveProfile = CurveProfile(),
        manualPercent: Double = 0.4,
        sampleIntervalSeconds: Double = 2.0,
        launchAtLogin: Bool = false,
        alertTemperatureC: Double = 90,
        alertsEnabled: Bool = true,
        showTemperatureInMenuBar: Bool = true,
        loadBoostMax: Double = 0.20,
        loadBoostThreshold: Double = 60
    ) {
        self.mode = mode
        self.curve = curve
        self.manualPercent = manualPercent.clamped(to: 0...1)
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.launchAtLogin = launchAtLogin
        self.alertTemperatureC = alertTemperatureC
        self.alertsEnabled = alertsEnabled
        self.showTemperatureInMenuBar = showTemperatureInMenuBar
        self.loadBoostMax = loadBoostMax.clamped(to: 0...0.4)
        self.loadBoostThreshold = loadBoostThreshold.clamped(to: 20...95)
    }

    public static let storageKey = "cooldown.settings.v1"

    enum CodingKeys: String, CodingKey {
        case mode, curve, manualPercent, sampleIntervalSeconds, launchAtLogin
        case alertTemperatureC, alertsEnabled, showTemperatureInMenuBar
        case loadBoostMax, loadBoostThreshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(ControlMode.self, forKey: .mode) ?? .smartCurve
        curve = try c.decodeIfPresent(CurveProfile.self, forKey: .curve) ?? CurveProfile()
        manualPercent = (try c.decodeIfPresent(Double.self, forKey: .manualPercent) ?? 0.4).clamped(to: 0...1)
        sampleIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .sampleIntervalSeconds) ?? 2.0
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        alertTemperatureC = try c.decodeIfPresent(Double.self, forKey: .alertTemperatureC) ?? 90
        alertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? true
        showTemperatureInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showTemperatureInMenuBar) ?? true
        loadBoostMax = (try c.decodeIfPresent(Double.self, forKey: .loadBoostMax) ?? 0.20).clamped(to: 0...0.4)
        loadBoostThreshold = (try c.decodeIfPresent(Double.self, forKey: .loadBoostThreshold) ?? 60).clamped(to: 20...95)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(curve, forKey: .curve)
        try c.encode(manualPercent, forKey: .manualPercent)
        try c.encode(sampleIntervalSeconds, forKey: .sampleIntervalSeconds)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(alertTemperatureC, forKey: .alertTemperatureC)
        try c.encode(alertsEnabled, forKey: .alertsEnabled)
        try c.encode(showTemperatureInMenuBar, forKey: .showTemperatureInMenuBar)
        try c.encode(loadBoostMax, forKey: .loadBoostMax)
        try c.encode(loadBoostThreshold, forKey: .loadBoostThreshold)
    }
}

public enum ThermalPressureLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    public var displayName: String {
        switch self {
        case .nominal: return String(localized: "Nominal")
        case .fair: return String(localized: "Fair")
        case .serious: return String(localized: "Serious")
        case .critical: return String(localized: "Critical")
        }
    }
}

public struct HotProcess: Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var cpuPercent: Double

    public init(pid: Int32, name: String, cpuPercent: Double) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
    }
}

public extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
