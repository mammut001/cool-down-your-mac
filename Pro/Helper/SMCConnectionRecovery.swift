import Foundation

/// Keeps a connection only after an operation succeeds. A failed I/O attempt
/// gets one fresh connection and one retry; a second failure leaves no cache.
enum SMCConnectionRecovery {
    static func run<Connection, Value>(
        cached: inout Connection?,
        open: () throws -> Connection,
        onReopen: () -> Void = {},
        operation: (Connection) throws -> Value
    ) throws -> Value {
        let current: Connection
        if let existing = cached {
            current = existing
        } else {
            current = try open()
            cached = current
        }
        do {
            return try operation(current)
        } catch {
            cached = nil
            let reopened = try open()
            onReopen()
            do {
                let value = try operation(reopened)
                cached = reopened
                return value
            } catch {
                cached = nil
                throw error
            }
        }
    }
}
