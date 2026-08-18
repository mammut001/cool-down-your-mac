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
            DashboardLaunchLabel()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
        }
        .menuBarExtraStyle(.window)

        Window("Cool Down Pro", id: "dashboard") {
            ProDashboardView()
                .environmentObject(appModel)
                .environmentObject(appModel.settings)
        }
        .defaultSize(width: 640, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Cool Down Pro") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }

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
        // Open dashboard shortly after launch so sensors/RPM are visible without hunting the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .coolDownOpenDashboard, object: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .coolDownOpenDashboard, object: nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ProAppModel.performSyncRestoreIfNeeded()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProAppModel.performSyncRestoreIfNeeded()
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

/// Always-mounted menu bar label so launch/reopen can open the dashboard window.
private struct DashboardLaunchLabel: View {
    @EnvironmentObject private var model: ProAppModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ProMenuBarLabel(title: model.menuBarTitle)
            .onReceive(NotificationCenter.default.publisher(for: .coolDownOpenDashboard)) { _ in
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
