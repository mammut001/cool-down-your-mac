import Foundation
import os.log

let logger = Logger(subsystem: "com.cooldown.CoolDownPro.PrivilegedHelper", category: "boot")
logger.info("helper boot uid=\(getuid()) pid=\(getpid(), privacy: .public)")

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: coolDownHelperMachServiceName)
listener.delegate = delegate
listener.resume()

logger.info("listener ready for \(coolDownHelperMachServiceName, privacy: .public)")

RunLoop.current.run()
