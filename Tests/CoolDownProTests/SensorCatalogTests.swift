import XCTest
import CoolDownKit

final class SensorCatalogTests: XCTestCase {
    func testCuratedListDeduplicatesSMCKeysWithoutTrapping() {
        let first = TemperatureReading(key: "TW0P", name: "Airport A", celsius: 31, group: .wireless)
        let second = TemperatureReading(key: "TW0P", name: "Airport B", celsius: 44, group: .wireless)
        let extra = TemperatureReading(key: "TB0T", name: "Battery", celsius: 28, group: .battery)

        let curated = SensorCatalog.curated(smc: [first, second, extra], hid: [])

        let airportKeys = curated.filter { $0.key == "TW0P" }
        XCTAssertEqual(airportKeys.count, 1)
        XCTAssertEqual(airportKeys.first!.celsius, 44, accuracy: 0.0001)

        let uniqueKeys = Set(curated.map(\.key))
        XCTAssertEqual(uniqueKeys.count, curated.count)
    }

    func testCuratedListDeduplicatesDuplicateTp00Readings() {
        let first = TemperatureReading(key: "Tp00", name: "CPU first", celsius: 41, group: .cpu)
        let second = TemperatureReading(key: "Tp00", name: "CPU second", celsius: 62, group: .cpu)
        let other = TemperatureReading(key: "Tp01", name: "CPU other", celsius: 50, group: .cpu)

        let curated = SensorCatalog.curated(smc: [first, second, other], hid: [])
        let matches = curated.filter { $0.key == "Tp00" }

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first!.celsius, 62, accuracy: 0.0001)

        let uniqueKeys = Set(curated.map(\.key))
        XCTAssertEqual(uniqueKeys.count, curated.count)
    }

    func testLastWriteWinsByKeyKeepsLatestDuplicate() {
        let readings = [
            TemperatureReading(key: "TN00", name: "first", celsius: 20, group: .storage),
            TemperatureReading(key: "TN00", name: "second", celsius: 33, group: .storage),
            TemperatureReading(key: "TB0T", name: "Battery", celsius: 27, group: .battery)
        ]
        let map = SensorCatalog.lastWriteWinsByKey(readings)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["TN00"]?.celsius, 33)
        XCTAssertEqual(map["TN00"]?.name, "second")
    }

    func testStorageLabelUsesSourceNameNotHardcodedAP1024Z() {
        let nand = TemperatureReading(
            key: "hid.storage.ap0512",
            name: "APPLE SSD AP0512M",
            celsius: 36,
            group: .storage
        )

        let curated = SensorCatalog.curated(smc: [], hid: [nand])
        let storage = curated.filter { $0.group == .storage }

        XCTAssertFalse(storage.isEmpty)
        XCTAssertFalse(storage.contains { $0.name == "APPLE SSD AP1024Z" })
        XCTAssertEqual(storage.first?.name, "APPLE SSD AP0512M")
        XCTAssertEqual(SensorCatalog.storageDisplayName(from: "APPLE SSD AP0512M"), "APPLE SSD AP0512M")
        XCTAssertEqual(SensorCatalog.storageDisplayName(from: "   "), "SSD")
    }

    func testMapperStorageNameUsesActualModelNotAP1024Z() {
        XCTAssertEqual(SensorNameMapper.storageName("APPLE SSD AP0512M"), "APPLE SSD AP0512M")
        XCTAssertEqual(SensorNameMapper.storageName("APPLE SSD AP1024R"), "APPLE SSD AP1024R")
        XCTAssertFalse(SensorNameMapper.storageName("APPLE SSD AP0512M").contains("AP1024Z"))
        let mapped = SensorNameMapper.map(rawReadings: [("APPLE SSD AP0512M", 36)])
        XCTAssertEqual(mapped.first?.name, "APPLE SSD AP0512M")
        XCTAssertFalse(mapped.contains { $0.name == "APPLE SSD AP1024Z" })
    }

    func testControlReadingsIncludeHIDCPUAndIgnoreDisplayToggleSource() {
        let hid = [
            TemperatureReading(key: "hid.cpu.perf.1", name: "CPU Performance Core 1", celsius: 97, group: .cpu)
        ]
        let control = SensorCatalog.controlReadings(smc: [], hid: hid)
        XCTAssertEqual(control.map(\.key), ["hid.cpu.perf.1"])
        XCTAssertEqual(control.first!.celsius, 97, accuracy: 0.0001)
    }

    func testCuratedIncludesUppercaseTGKeys() {
        let gpu = TemperatureReading(key: "TG0P", name: "GPU", celsius: 48, group: .gpu)
        let curated = SensorCatalog.curated(smc: [gpu], hid: [])
        XCTAssertTrue(curated.contains { $0.key == "TG0P" })
    }

    func testCuratedHIDFallbackShowsOnlyOneCPUAverage() {
        let hid = [
            TemperatureReading(key: "hid.cpu.perf.1", name: "CPU Performance Core 1", celsius: 50, group: .cpu),
            TemperatureReading(key: "hid.cpu.perf.2", name: "CPU Performance Core 2", celsius: 60, group: .cpu),
            TemperatureReading(key: "hid.cpu.avg", name: "CPU Core Average", celsius: 55, group: .cpu)
        ]

        let curated = SensorCatalog.curated(smc: [], hid: hid)
        let averages = curated.filter { $0.name == "CPU Core Average" }

        XCTAssertEqual(averages.count, 1)
        XCTAssertEqual(averages.first!.celsius, 55, accuracy: 0.0001)
    }

    func testMergedListAlsoDeduplicatesSharedKeys() {
        let a = TemperatureReading(key: "Tp01", name: "CPU A", celsius: 40, group: .cpu)
        let b = TemperatureReading(key: "Tp01", name: "CPU B", celsius: 55, group: .cpu)
        let merged = SensorCatalog.allMerged(smc: [a, b], hid: [])
        let matches = merged.filter { $0.key == "Tp01" }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first!.celsius, 55, accuracy: 0.0001)
    }

    func testTemperatureKeyDetection() {
        XCTAssertTrue(SMCKnownNames.isTemperatureKey("Tp09"))
        XCTAssertTrue(SMCKnownNames.isTemperatureKey("TC0P"))
        XCTAssertTrue(SMCKnownNames.isTemperatureKey("tg0P"))
        XCTAssertFalse(SMCKnownNames.isTemperatureKey("FNum"))
        XCTAssertFalse(SMCKnownNames.isTemperatureKey("F0Ac"))
        XCTAssertFalse(SMCKnownNames.isTemperatureKey(""))
    }

    func testIntelSMCSensorsAreCuratedWithFriendlyNamesAndAverage() {
        let tc0p = TemperatureReading(key: "TC0P", name: "TC0P", celsius: 65, group: .cpu)
        let tc1c = TemperatureReading(key: "TC1C", name: "TC1C", celsius: 70, group: .cpu)
        let tc2c = TemperatureReading(key: "TC2C", name: "TC2C", celsius: 72, group: .cpu)
        let tg0p = TemperatureReading(key: "TG0P", name: "TG0P", celsius: 55, group: .gpu)
        let tm0p = TemperatureReading(key: "TM0P", name: "TM0P", celsius: 48, group: .other)

        let smcTemps = [tc0p, tc1c, tc2c, tg0p, tm0p].map(SensorMerge.annotateSMC)
        let curated = SensorCatalog.curated(smc: smcTemps, hid: [])

        // CPU average should be computed
        let avg = curated.first(where: { $0.key == "calc.cpu.avg" })
        XCTAssertNotNil(avg)
        XCTAssertEqual(avg?.celsius ?? 0, (65.0 + 70.0 + 72.0) / 3.0, accuracy: 0.0001)

        // Intel sensors should retain friendly names
        XCTAssertTrue(curated.contains(where: { $0.name == "CPU Proximity" }))
        XCTAssertTrue(curated.contains(where: { $0.name == "CPU Core 1" }))
        XCTAssertTrue(curated.contains(where: { $0.name == "CPU Core 2" }))
        XCTAssertTrue(curated.contains(where: { $0.name == "GPU Proximity" }))
        XCTAssertTrue(curated.contains(where: { $0.name == "Memory Proximity" }))

        // CPU should not be labeled "CPU Performance Core" on Intel
        XCTAssertFalse(curated.contains(where: { $0.name.contains("Performance Core") }))
    }

    func testIntelKnownNamesMapping() {
        XCTAssertEqual(SMCKnownNames.name(for: "TC0P"), "CPU Proximity")
        XCTAssertEqual(SMCKnownNames.name(for: "TC0D"), "CPU Die")
        XCTAssertEqual(SMCKnownNames.name(for: "TC1C"), "CPU Core 1")
        XCTAssertEqual(SMCKnownNames.name(for: "TC8C"), "CPU Core 8")
        XCTAssertEqual(SMCKnownNames.name(for: "TG0P"), "GPU Proximity")
        XCTAssertEqual(SMCKnownNames.name(for: "TM0P"), "Memory Proximity")
        XCTAssertEqual(SMCKnownNames.name(for: "TN0P"), "Platform Controller Hub")
    }
}
