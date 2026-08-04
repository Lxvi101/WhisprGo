import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
enum TextInjector {
    struct Target {
        let element: AXUIElement
        let processIdentifier: pid_t
    }

    enum Result: Equatable {
        case inserted
        case ignored
        case failed(String)

        var errorMessage: String? {
            guard case let .failed(message) = self else { return nil }
            return message
        }
    }

    /// Capturing the destination before recording prevents transient call and
    /// screen-sharing controls from stealing the insertion target while the
    /// transcript is being produced.
    static func captureTarget() -> Target? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let lookup = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard lookup == .success, let focusedValue else { return nil }

        let focused = focusedValue as! AXUIElement
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focused, &processIdentifier) == .success else { return nil }
        return Target(element: focused, processIdentifier: processIdentifier)
    }

    static func inject(_ text: String, into capturedTarget: Target? = nil) async -> Result {
        guard !text.isEmpty else { return .ignored }
        guard AXIsProcessTrusted() else {
            return .failed("Text could not be inserted. Allow WhisprGo in Accessibility settings.")
        }

        let target = capturedTarget ?? captureTarget()
        if let target,
           AXUIElementSetAttributeValue(
               target.element,
               kAXSelectedTextAttribute as CFString,
               text as CFString
           ) == .success {
            return .inserted
        }

        return await paste(text, into: target)
    }

    private static func paste(_ text: String, into target: Target?) async -> Result {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(on: pasteboard)
            return .failed("Text could not be copied for automatic insertion.")
        }
        let ownedChangeCount = pasteboard.changeCount

        if let target,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            guard let application = NSRunningApplication(
                processIdentifier: target.processIdentifier
            ), application.activate() else {
                snapshot.restore(on: pasteboard, ifChangeCountIs: ownedChangeCount)
                return .failed("The app you were dictating into is no longer available.")
            }

            // Activation is asynchronous. This is only paid on the uncommon
            // fallback path where direct Accessibility insertion was rejected.
            try? await Task.sleep(for: .milliseconds(40))
        }

        guard postPasteCommand() else {
            snapshot.restore(on: pasteboard, ifChangeCountIs: ownedChangeCount)
            return .failed("Text could not be inserted. Check Accessibility permission and try again.")
        }

        // Most apps read the pasteboard synchronously, but delayed restoration
        // also covers web views without adding work to the transcription path.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            snapshot.restore(on: pasteboard, ifChangeCountIs: ownedChangeCount)
        }
        return .inserted
    }

    private static func postPasteCommand() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 9,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 9,
                  keyDown: false
              ) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    struct PasteboardSnapshot {
        struct Item {
            struct Representation {
                let type: NSPasteboard.PasteboardType
                let data: Data
            }

            let representations: [Representation]
        }

        let items: [Item]

        init(pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).compactMap { pasteboardItem in
                let representations = pasteboardItem.types.compactMap { type -> Item.Representation? in
                    guard let data = pasteboardItem.data(forType: type) else { return nil }
                    return Item.Representation(type: type, data: data)
                }
                return representations.isEmpty ? nil : Item(representations: representations)
            }
        }

        @discardableResult
        func restore(
            on pasteboard: NSPasteboard,
            ifChangeCountIs expectedChangeCount: Int? = nil
        ) -> Bool {
            if let expectedChangeCount, pasteboard.changeCount != expectedChangeCount {
                return false
            }

            pasteboard.clearContents()
            guard !items.isEmpty else { return true }

            let restoredItems = items.map { item -> NSPasteboardItem in
                let restoredItem = NSPasteboardItem()
                for representation in item.representations {
                    restoredItem.setData(representation.data, forType: representation.type)
                }
                return restoredItem
            }
            return pasteboard.writeObjects(restoredItems)
        }
    }
}
