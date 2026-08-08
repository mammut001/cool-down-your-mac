import SwiftUI
import CoolDownKit
import AppKit

@main
struct CoolDownStoreApp: App {
    @StateObject private var model = StoreAppModel()
    @NSApplicationDelegateAdaptor(StoreAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StoreMenuBarView()
                .environmentObject(model)
                .environmentObject(model.settings)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                Text(model.menuBarTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            StoreSettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .frame(width: 440, height: 360)
        }
    }
}

final class StoreAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
