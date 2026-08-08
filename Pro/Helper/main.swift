import Foundation

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: coolDownHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
