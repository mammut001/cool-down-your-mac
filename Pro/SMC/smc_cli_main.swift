import Foundation

/// Tiny privileged CLI used when the SMAppService helper cannot spawn.
/// Usage:
///   cooldown-smc auto
///   cooldown-smc percent 0.35
@main
struct SMCCLI {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("usage: cooldown-smc auto|percent <0...1>|inspect|read\n", stderr)
            exit(2)
        }
        do {
            let kit = try SMCKit()
            switch args[1] {
            case "auto":
                try kit.setAllFansAuto()
            case "percent":
                guard args.count >= 3, let p = Double(args[2]) else {
                    fputs("invalid percent\n", stderr)
                    exit(2)
                }
                try kit.setAllFansPercent(p)
            case "inspect":
                for description in kit.fanKeyDescriptions() { print(description) }
                return
            case "read":
                for fan in try kit.readFans() {
                    print("Fan\(fan.index) cur=\(Int(fan.currentRPM)) tgt=\(Int(fan.targetRPM ?? -1)) manual=\(fan.isManual)")
                }
                return
            default:
                fputs("unknown command\n", stderr)
                exit(2)
            }
            let fans = try kit.readFans()
            for fan in fans {
                print("Fan\(fan.index) cur=\(Int(fan.currentRPM)) tgt=\(Int(fan.targetRPM ?? -1))")
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }
}
