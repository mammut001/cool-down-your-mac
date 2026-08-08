import Foundation

final class HelperService: NSObject, CoolDownHelperProtocol {
    private let queue = DispatchQueue(label: "com.cooldown.helper.smc", qos: .userInitiated)
    private var smc: SMCKit?

    private func withSMC<T>(_ body: (SMCKit) throws -> T) throws -> T {
        if smc == nil {
            smc = try SMCKit()
        }
        guard let smc else { throw CoolDownXPCError.smcFailed.nsError }
        return try body(smc)
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func fetchSnapshot(reply: @escaping (Data?, NSError?) -> Void) {
        queue.async {
            do {
                let dto = try self.withSMC { kit -> XPCSnapshotDTO in
                    let fans = try kit.readFans().map {
                        XPCSnapshotDTO.FanDTO(
                            index: $0.index,
                            name: $0.name,
                            minRPM: $0.minRPM,
                            maxRPM: $0.maxRPM,
                            currentRPM: $0.currentRPM,
                            targetRPM: $0.targetRPM,
                            isManual: $0.isManual
                        )
                    }
                    let temps = kit.readTemperatures().map {
                        XPCSnapshotDTO.TempDTO(key: $0.key, name: $0.name, celsius: $0.celsius)
                    }
                    return XPCSnapshotDTO(
                        fans: fans,
                        temperatures: temps,
                        canControlFans: kit.canControlFans
                    )
                }
                let data = try JSONEncoder().encode(dto)
                reply(data, nil)
            } catch let error as NSError {
                reply(nil, error)
            } catch {
                reply(nil, CoolDownXPCError.smcFailed.nsError)
            }
        }
    }

    func setFansAuto(reply: @escaping (NSError?) -> Void) {
        queue.async {
            do {
                try self.withSMC { try $0.setAllFansAuto() }
                reply(nil)
            } catch let error as NSError {
                reply(error)
            } catch {
                reply(CoolDownXPCError.smcFailed.nsError)
            }
        }
    }

    func setFansPercent(_ percent: Double, reply: @escaping (NSError?) -> Void) {
        queue.async {
            do {
                try self.withSMC { try $0.setAllFansPercent(percent) }
                reply(nil)
            } catch let error as NSError {
                reply(error)
            } catch {
                reply(CoolDownXPCError.smcFailed.nsError)
            }
        }
    }

    func setFanRPM(index: Int, rpm: Double, reply: @escaping (NSError?) -> Void) {
        queue.async {
            do {
                try self.withSMC { try $0.setFanRPM(index: index, rpm: rpm) }
                reply(nil)
            } catch let error as NSError {
                reply(error)
            } catch {
                reply(CoolDownXPCError.smcFailed.nsError)
            }
        }
    }
}
