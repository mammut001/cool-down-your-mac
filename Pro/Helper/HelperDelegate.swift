import Foundation

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard HelperSecurity.isTrustedCaller(connection: newConnection) else {
            return false
        }
        if #available(macOS 13.0, *) {
            do {
                try newConnection.setCodeSigningRequirement(HelperSecurity.clientRequirement)
            } catch {
                return false
            }
        }
        newConnection.exportedInterface = NSXPCInterface(with: CoolDownHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.invalidationHandler = {
            // Force-quit / crash skip applicationWillTerminate. Put fans back
            // to firmware auto when the trusted client goes away.
            HelperService.restoreFansBestEffort()
        }
        newConnection.resume()
        return true
    }
}
