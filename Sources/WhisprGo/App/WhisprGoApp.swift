import AppKit
import SwiftUI

@main
struct WhisprGoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = DictationEngine.shared
    @StateObject private var updates = UpdateChecker.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine, updates: updates)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: BrandAssets.menuBarIcon)
                    .renderingMode(.template)
                if updates.availableUpdate != nil {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                        .offset(x: 3, y: -2)
                }
            }
            .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(engine: engine)
        }
    }

    private var menuBarAccessibilityLabel: String {
        if let update = updates.availableUpdate {
            return "WhisprGo: update \(update.version) available"
        }
        return "WhisprGo: \(engine.stateTitle)"
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        StartupAnimationController.shared.show()
        DictationEngine.shared.start()
        UpdateChecker.shared.checkOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationEngine.shared.shutdown()
    }
}
