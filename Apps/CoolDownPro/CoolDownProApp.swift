import SwiftUI
import CoolDownKit
import AppKit

@main
struct CoolDownProApp: App {
    @StateObject private var appModel = ProAppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ProMenuBarView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
        } label: {
            ProMenuBarLabel(title: appModel.menuBarTitle)
        }
        .menuBarExtraStyle(.window)

        Window("Cool Down Pro", id: "dashboard") {
            ProDashboardView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
        }
        .defaultSize(width: 560, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            ProSettingsView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
                .frame(width: 480, height: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .coolDownOpenDashboard, object: nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            await ProAppModel.sharedOnTerminate?()
        }
    }
}

extension Notification.Name {
    static let coolDownOpenDashboard = Notification.Name("coolDownOpenDashboard")
}

struct ProMenuBarLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "fanblades")
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}
