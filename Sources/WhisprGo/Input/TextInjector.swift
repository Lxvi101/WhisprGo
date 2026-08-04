import ApplicationServices
import CoreGraphics
import Foundation

enum TextInjector {
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }
        if insertThroughAccessibility(text) == .success {
            return
        }
        insertThroughKeyboardEvents(text)
    }

    private static func insertThroughAccessibility(_ text: String) -> AXError {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let lookup = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard lookup == .success, let focusedValue else { return lookup }
        let focused = focusedValue as! AXUIElement
        return AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
    }

    private static func insertThroughKeyboardEvents(_ text: String) {
        let utf16 = Array(text.utf16)
        let chunkSize = 20
        utf16.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0

            while offset < buffer.count {
                let count = min(chunkSize, buffer.count - offset)
                let characters = baseAddress.advanced(by: offset)
                post(characters, count: count, keyDown: true)
                post(characters, count: count, keyDown: false)
                offset += count
            }
        }
    }

    private static func post(
        _ characters: UnsafePointer<UniChar>,
        count: Int,
        keyDown: Bool
    ) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: keyDown
        ) else { return }
        event.keyboardSetUnicodeString(
            stringLength: count,
            unicodeString: characters
        )
        event.post(tap: .cgSessionEventTap)
    }
}
