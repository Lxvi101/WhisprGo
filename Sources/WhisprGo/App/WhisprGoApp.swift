import AppKit
import SwiftUI

@main
struct WhisprGoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = DictationEngine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
        } label: {
            Image(systemName: engine.menuBarSymbol)
                .accessibilityLabel("WhisprGo: \(engine.stateTitle)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(engine: engine)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        StartupAnimationController.shared.show()
        DictationEngine.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationEngine.shared.shutdown()
    }
}
