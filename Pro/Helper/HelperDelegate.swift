import Foundation

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let caller = HelperSecurity.trustedCaller(connection: newConnection) else {
            return false
        }
        if #available(macOS 13.0, *) {
            newConnection.setCodeSigningRequirement(HelperSecurity.clientRequirement)
        }
        let service = HelperService(clientBuild: caller.buildNumber)
        newConnection.exportedInterface = NSXPCInterface(with: CoolDownHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.interruptionHandler = {
            // XPC interruption (client crash mid-call) may not trigger
            // invalidation immediately. Restore fans during this window.
            service.clientGone()
        }
        newConnection.invalidationHandler = {
            // Force-quit / crash skip applicationWillTerminate. Put fans back
            // to firmware auto when the trusted client goes away.
            service.clientGone()
        }
        newConnection.resume()
        return true
    }
}
