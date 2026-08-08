import Foundation

struct SMCFanReading {
    var index: Int
    var name: String
    var minRPM: Double
    var maxRPM: Double
    var currentRPM: Double
    var targetRPM: Double?
    var isManual: Bool
}

struct SMCTempReading {
    var key: String
    var name: String
    var celsius: Double
}
