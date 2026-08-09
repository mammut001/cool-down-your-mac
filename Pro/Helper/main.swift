import Foundation

let bootLog = URL(fileURLWithPath: "/tmp/cooldown-helper-boot.log")
let bootLine = "\(Date()): helper boot uid=\(getuid()) pid=\(getpid())\n"
try? (bootLine.data(using: .utf8))?.write(to: bootLog)

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: coolDownHelperMachServiceName)
listener.delegate = delegate
listener.resume()

let readyLine = "\(Date()): listener ready for \(coolDownHelperMachServiceName)\n"
if let data = readyLine.data(using: .utf8),
   let handle = try? FileHandle(forWritingTo: bootLog) {
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
} else {
    try? readyLine.data(using: .utf8)?.write(to: bootLog)
}

RunLoop.current.run()
