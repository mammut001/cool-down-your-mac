import Foundation

typealias ClientCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
typealias ClientSetMatching = @convention(c) (UnsafeMutableRawPointer?, CFDictionary?) -> Void
typealias ClientCopyServices = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFArray>?
typealias ServiceCopyProperty = @convention(c) (UnsafeRawPointer?, CFString) -> Unmanaged<CFTypeRef>?
typealias ServiceCopyEvent = @convention(c) (UnsafeRawPointer?, Int64, UnsafeRawPointer?, Int32) -> UnsafeMutableRawPointer?
typealias EventGetFloatValue = @convention(c) (UnsafeRawPointer?, Int32) -> Double

let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
func load<T>(_ name: String) -> T {
    guard let iokit, let sym = dlsym(iokit, name) else {
        fputs("missing symbol \(name)\n", stderr)
        exit(1)
    }
    return unsafeBitCast(sym, to: T.self)
}

let create: ClientCreate = load("IOHIDEventSystemClientCreate")
let setMatching: ClientSetMatching = load("IOHIDEventSystemClientSetMatching")
let copyServices: ClientCopyServices = load("IOHIDEventSystemClientCopyServices")
let copyProperty: ServiceCopyProperty = load("IOHIDServiceClientCopyProperty")
let copyEvent: ServiceCopyEvent = load("IOHIDServiceClientCopyEvent")
let getFloat: EventGetFloatValue = load("IOHIDEventGetFloatValue")

let client = create(kCFAllocatorDefault)
setMatching(client, [
    "PrimaryUsagePage": 0xff00,
    "PrimaryUsage": 5
] as CFDictionary)

guard let arr = copyServices(client)?.takeUnretainedValue() else {
    print("No services")
    exit(0)
}

let count = CFArrayGetCount(arr)
print("HID temperature services: \(count)\n")
print(String(format: "%-44s %8s", "Sensor", "°C"))
print(String(repeating: "-", count: 54))

var rows: [(String, Double)] = []
for i in 0..<count {
    guard let service = CFArrayGetValueAtIndex(arr, i) else { continue }
    let name = (copyProperty(service, "Product" as CFString)?.takeUnretainedValue() as? String) ?? "Unknown"
    // kIOHIDEventTypeTemperature = 15; field = type << 16
    guard let event = copyEvent(service, 15, nil, 0) else { continue }
    let value = getFloat(event, 15 << 16)
    if value.isFinite { rows.append((name, value)) }
}

rows.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
for (name, value) in rows {
    print(String(format: "%-44s %7.1f", name, value))
}
print("\nTotal: \(rows.count)")
