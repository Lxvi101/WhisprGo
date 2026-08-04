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
            Image(nsImage: BrandAssets.menuBarIcon)
                .renderingMode(.template)
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
        if let preview = ProcessInfo.processInfo.environment["WHISPRGO_UI_PREVIEW"] {
            NSApp.setActivationPolicy(.regular)
            PreviewWindowController.shared.show(preview, engine: .shared)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        StartupAnimationController.shared.show()
        DictationEngine.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationEngine.shared.shutdown()
    }
}

@MainActor
private final class PreviewWindowController {
    static let shared = PreviewWindowController()
    private var window: NSWindow?

    func show(_ preview: String, engine: DictationEngine) {
        let rootView: AnyView
        let size: NSSize
        if preview == "settings" {
            rootView = AnyView(SettingsView(engine: engine))
            size = NSSize(width: 660, height: 520)
        } else {
            rootView = AnyView(MenuBarView(engine: engine))
            size = NSSize(width: 360, height: 540)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = preview == "settings" ? "WhisprGo Settings" : "WhisprGo Menu Preview"
        window.level = .floating
        window.setContentSize(size)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
