import SwiftUI
import AppKit

@main
struct ThunderboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = ServiceStore()

    var body: some Scene {
        WindowGroup("Thunderbox") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 640, minHeight: 440)
                .dynamicTypeSize(.xLarge)          // slightly larger type across the UI
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 880, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}  // no "New Window"
            CommandGroup(replacing: .appInfo) { AboutMenuButton() }
        }

        // One console window per service, opened on demand.
        WindowGroup("Console", id: "console", for: UUID.self) { $serviceID in
            ConsoleWindow(serviceID: serviceID)
                .environmentObject(store)
                .frame(minWidth: 580, minHeight: 380)
                .dynamicTypeSize(.xLarge)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 800, height: 560)

        // Custom About panel (single window).
        Window("About Thunderbox", id: "about") {
            AboutView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Opens the custom About window from the app menu.
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About Thunderbox") { openWindow(id: "about") }
    }
}

/// Ensures every running service is torn down before the app exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: ServiceStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.stopAllForQuit()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // stay alive if only console windows are closed; quit via Cmd-Q / menu
    }
}
