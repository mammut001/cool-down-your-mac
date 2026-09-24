import Foundation
import os.log

let logger = Logger(subsystem: "com.cooldown.CoolDownPro.PrivilegedHelper", category: "boot")
logger.info("helper boot uid=\(getuid()) pid=\(getpid(), privacy: .public)")

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: coolDownHelperMachServiceName)
listener.delegate = delegate
listener.resume()

logger.info("listener ready for \(coolDownHelperMachServiceName, privacy: .public)")

// Restore fans to system-managed auto when launchd sends SIGTERM (OS update,
// reboot, or manual unload). Without this, fans stay stuck in manual mode.
signal(SIGTERM, SIG_IGN)
let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSource.setEventHandler {
    logger.info("SIGTERM received — restoring fans to auto")
    do {
        try HelperService.restoreFansBeforeExit()
        logger.info("SIGTERM fan restore OK")
    } catch {
        logger.error("SIGTERM fan restore failed: \(String(describing: error), privacy: .public)")
    }
    exit(0)
}
sigSource.resume()

RunLoop.current.run()
