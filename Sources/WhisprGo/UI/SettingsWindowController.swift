import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var windowController: NSWindowController?

    func show(engine: DictationEngine, tab: SettingsTab = .general) {
        SettingsNavigation.shared.selection = tab
        let controller: NSWindowController
        if let existing = windowController {
            controller = existing
        } else {
            let hostingController = NSHostingController(
                rootView: SettingsView(engine: engine)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "WhisprGo Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 760, height: 560))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()

            let created = NSWindowController(window: window)
            windowController = created
            controller = created
        }

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
