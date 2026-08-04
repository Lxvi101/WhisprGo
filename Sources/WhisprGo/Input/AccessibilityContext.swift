import AppKit
import ApplicationServices
import Foundation

struct AccessibilityContextSnapshot: Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String?
    let windowTitle: String?
    let documentURL: String?
    let focusedRole: String?
    let textBeforeCursor: String
    let selectedText: String
    let textAfterCursor: String
    let nearbyText: String

    var isEmpty: Bool {
        applicationName.isEmpty
            && windowTitle == nil
            && documentURL == nil
            && textBeforeCursor.isEmpty
            && selectedText.isEmpty
            && textAfterCursor.isEmpty
            && nearbyText.isEmpty
    }
}

@MainActor
enum AccessibilityContextReader {
    static let beforeCharacterLimit = 1_600
    static let selectedCharacterLimit = 800
    static let afterCharacterLimit = 1_600
    static let nearbyCharacterLimit = 2_800

    static func capture(from target: TextInjector.Target?) -> AccessibilityContextSnapshot? {
        guard AXIsProcessTrusted(), let target else { return nil }

        let runningApplication = NSRunningApplication(
            processIdentifier: target.processIdentifier
        )
        let applicationName = runningApplication?.localizedName ?? ""
        let bundleIdentifier = runningApplication?.bundleIdentifier
        let element = target.element
        _ = AXUIElementSetMessagingTimeout(element, 0.04)

        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let window = elementAttribute(element, kAXWindowAttribute)
        if let window {
            _ = AXUIElementSetMessagingTimeout(window, 0.04)
        }

        let windowTitle = window.flatMap { stringAttribute($0, kAXTitleAttribute) }
        let documentURL = stringAttribute(element, kAXURLAttribute)
            ?? window.flatMap { stringAttribute($0, kAXURLAttribute) }
            ?? window.flatMap { stringAttribute($0, kAXDocumentAttribute) }

        guard subrole != kAXSecureTextFieldSubrole else {
            return AccessibilityContextSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                documentURL: documentURL,
                focusedRole: role,
                textBeforeCursor: "",
                selectedText: "",
                textAfterCursor: "",
                nearbyText: ""
            )
        }

        let focusedText = textAroundCursor(in: element)
        let excluded = Set([
            focusedText.before,
            focusedText.selected,
            focusedText.after,
            windowTitle ?? "",
        ].filter { !$0.isEmpty })
        let nearbyText = window.map {
            collectNearbyText(from: $0, excluding: excluded)
        } ?? ""

        let snapshot = AccessibilityContextSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            documentURL: documentURL,
            focusedRole: role,
            textBeforeCursor: focusedText.before,
            selectedText: focusedText.selected,
            textAfterCursor: focusedText.after,
            nearbyText: nearbyText
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func textAroundCursor(
        in element: AXUIElement
    ) -> (before: String, selected: String, after: String) {
        guard let selectedRange = rangeAttribute(element, kAXSelectedTextRangeAttribute) else {
            let value = stringAttribute(element, kAXValueAttribute) ?? ""
            return (boundedSuffix(value, limit: beforeCharacterLimit), "", "")
        }

        let location = max(0, selectedRange.location)
        let selectedLength = max(0, selectedRange.length)
        let totalLength = max(
            location + selectedLength,
            integerAttribute(element, kAXNumberOfCharactersAttribute) ?? 0
        )

        let beforeRange = CFRange(
            location: max(0, location - beforeCharacterLimit),
            length: min(beforeCharacterLimit, location)
        )
        let selectedBoundedRange = CFRange(
            location: location,
            length: min(selectedCharacterLimit, selectedLength)
        )
        let afterLocation = location + selectedLength
        let afterRange = CFRange(
            location: afterLocation,
            length: min(afterCharacterLimit, max(0, totalLength - afterLocation))
        )

        if let before = string(in: beforeRange, of: element),
           let selected = string(in: selectedBoundedRange, of: element),
           let after = string(in: afterRange, of: element) {
            return (before, selected, after)
        }

        guard let value = stringAttribute(element, kAXValueAttribute) else {
            return ("", stringAttribute(element, kAXSelectedTextAttribute) ?? "", "")
        }
        return split(value, around: selectedRange)
    }

    private static func split(
        _ value: String,
        around selectedRange: CFRange
    ) -> (before: String, selected: String, after: String) {
        let text = value as NSString
        let location = min(max(0, selectedRange.location), text.length)
        let selectionEnd = min(
            text.length,
            location + max(0, selectedRange.length)
        )
        let beforeStart = max(0, location - beforeCharacterLimit)
        let before = text.substring(with: NSRange(
            location: beforeStart,
            length: location - beforeStart
        ))
        let selected = text.substring(with: NSRange(
            location: location,
            length: min(selectedCharacterLimit, selectionEnd - location)
        ))
        let after = text.substring(with: NSRange(
            location: selectionEnd,
            length: min(afterCharacterLimit, text.length - selectionEnd)
        ))
        return (before, selected, after)
    }

    private static func collectNearbyText(
        from root: AXUIElement,
        excluding excluded: Set<String>
    ) -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
        var queue = [root]
        var queueIndex = 0
        var visited = Set<CFHashCode>()
        var seenText = excluded
        var fragments: [String] = []
        var characterCount = 0

        while queueIndex < queue.count,
              queueIndex < 90,
              characterCount < nearbyCharacterLimit,
              ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue[queueIndex]
            queueIndex += 1

            let identifier = CFHash(element)
            guard visited.insert(identifier).inserted else { continue }
            _ = AXUIElementSetMessagingTimeout(element, 0.02)

            let role = stringAttribute(element, kAXRoleAttribute)
            let subrole = stringAttribute(element, kAXSubroleAttribute)
            if subrole != kAXSecureTextFieldSubrole {
                let candidates: [String?]
                switch role {
                case kAXStaticTextRole,
                     kAXTextFieldRole,
                     kAXTextAreaRole:
                    candidates = [
                        stringAttribute(element, kAXValueAttribute),
                        stringAttribute(element, kAXTitleAttribute),
                        stringAttribute(element, kAXDescriptionAttribute),
                    ]
                default:
                    candidates = [stringAttribute(element, kAXTitleAttribute)]
                }

                for candidate in candidates.compactMap({ $0 }) {
                    let normalized = candidate
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard normalized.count > 1,
                          !seenText.contains(normalized)
                    else { continue }

                    let remaining = nearbyCharacterLimit - characterCount
                    guard remaining > 0 else { break }
                    let fragment = boundedPrefix(normalized, limit: min(320, remaining))
                    fragments.append(fragment)
                    seenText.insert(normalized)
                    characterCount += fragment.count + 1
                }
            }

            if queue.count < 90 {
                queue.append(contentsOf: childrenAttribute(element).prefix(90 - queue.count))
            }
        }

        return fragments.joined(separator: "\n")
    }

    private static func string(in range: CFRange, of element: AXUIElement) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func integerAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        let rangeValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
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

    private static func childrenAttribute(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let visibleResult = AXUIElementCopyAttributeValue(
            element,
            kAXVisibleChildrenAttribute as CFString,
            &value
        )
        if visibleResult != .success {
            value = nil
            guard AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &value
            ) == .success else { return [] }
        }
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { item in
            let value = item as CFTypeRef
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    private static func boundedPrefix(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit))
    }

    private static func boundedSuffix(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.suffix(limit))
    }
}
