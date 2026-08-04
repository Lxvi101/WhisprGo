import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
enum TextInjector {
    private static let webAreaRole = "AXWebArea"
    private static let richEditorBundleIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.outlook",
        "com.mimestream.mimestream",
        "com.readdle.smartemail-macos",
        "io.canarymail.mac",
    ]

    struct Target {
        let element: AXUIElement
        let processIdentifier: pid_t
        let prefersPaste: Bool
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
        let bundleIdentifier = NSRunningApplication(
            processIdentifier: processIdentifier
        )?.bundleIdentifier?.lowercased()
        let role = stringAttribute(focused, kAXRoleAttribute)
        let isKnownRichEditor = role == kAXTextAreaRole
            && bundleIdentifier.map(richEditorBundleIDs.contains) == true
        return Target(
            element: focused,
            processIdentifier: processIdentifier,
            prefersPaste: isKnownRichEditor || isInsideWebContent(focused)
        )
    }

    static func inject(_ text: String, into capturedTarget: Target? = nil) async -> Result {
        guard !text.isEmpty else { return .ignored }
        guard AXIsProcessTrusted() else {
            return .failed("Text could not be inserted. Allow WhisprGo in Accessibility settings.")
        }

        let target = capturedTarget ?? captureTarget()
        if let target, !target.prefersPaste, insertDirectly(text, into: target.element) {
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
        let valueBeforePaste = target.flatMap { stringAttribute($0.element, kAXValueAttribute) }
        let selectionBeforePaste = target.flatMap {
            rangeAttribute($0.element, kAXSelectedTextRangeAttribute)
        }

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
            try? await Task.sleep(for: .milliseconds(70))
        }

        if let target {
            _ = AXUIElementSetAttributeValue(
                target.element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            // WebKit and Chromium commit focus asynchronously after their app
            // or editor is reactivated.
            try? await Task.sleep(for: .milliseconds(16))
        }

        guard postPasteCommand() else {
            snapshot.restore(on: pasteboard, ifChangeCountIs: ownedChangeCount)
            return .failed("Text could not be inserted. Check Accessibility permission and try again.")
        }

        if let target, let valueBeforePaste {
            try? await Task.sleep(for: .milliseconds(45))
            var valueAfterPaste = stringAttribute(target.element, kAXValueAttribute)
            var selectionAfterPaste = rangeAttribute(
                target.element,
                kAXSelectedTextRangeAttribute
            )
            if valueAfterPaste == valueBeforePaste,
               rangesMatch(selectionBeforePaste, selectionAfterPaste) {
                try? await Task.sleep(for: .milliseconds(80))
                valueAfterPaste = stringAttribute(target.element, kAXValueAttribute)
                selectionAfterPaste = rangeAttribute(
                    target.element,
                    kAXSelectedTextRangeAttribute
                )
            }
            if valueAfterPaste == valueBeforePaste,
               rangesMatch(selectionBeforePaste, selectionAfterPaste) {
                snapshot.restore(on: pasteboard, ifChangeCountIs: ownedChangeCount)
                return .failed(
                    "The editor ignored the paste command. Click in the message body and try again."
                )
            }
        }

        // Most apps read the pasteboard synchronously, but delayed restoration
        // also covers web views without adding work to the transcription path.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            snapshot.restore(on: pasteboard, ifChangeCountIs: ownedChangeCount)
        }
        return .inserted
    }

    private static func rangesMatch(_ left: CFRange?, _ right: CFRange?) -> Bool {
        switch (left, right) {
        case let (left?, right?):
            return left.location == right.location && left.length == right.length
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private static func insertDirectly(_ text: String, into element: AXUIElement) -> Bool {
        let valueBefore = stringAttribute(element, kAXValueAttribute)
        let selectedRange = rangeAttribute(element, kAXSelectedTextRangeAttribute)
        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else { return false }

        guard let valueBefore else {
            // Native controls occasionally expose a writable selection without
            // exposing their full value. Web controls never take this branch.
            return true
        }
        guard let valueAfter = stringAttribute(element, kAXValueAttribute) else {
            return false
        }
        if let selectedRange,
           let expected = replacing(valueBefore, range: selectedRange, with: text) {
            return valueAfter == expected || valueAfter != valueBefore
        }
        return valueAfter != valueBefore
    }

    private static func isInsideWebContent(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard let candidate = current else { break }
            if stringAttribute(candidate, kAXRoleAttribute) == webAreaRole {
                return true
            }
            current = elementAttribute(candidate, kAXParentAttribute)
        }
        return false
    }

    static func replacing(
        _ value: String,
        range: CFRange,
        with replacement: String
    ) -> String? {
        let source = value as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.location <= source.length,
              range.location + range.length <= source.length
        else { return nil }
        return source.replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: replacement
        )
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success, let value else { return nil }
        if let string = value as? String { return string }
        return (value as? NSAttributedString)?.string
    }

    private static func rangeAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
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
