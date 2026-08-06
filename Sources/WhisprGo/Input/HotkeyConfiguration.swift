import CoreGraphics
import Foundation

enum HotkeyAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case pushToTalk
    case toggleDictation
    case toggleMode
    case cycleProfile
    case pasteLast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .toggleDictation: "Start or stop dictation"
        case .toggleMode: "Switch Fast / Pro Mode"
        case .cycleProfile: "Next Pro profile"
        case .pasteLast: "Paste last dictation"
        }
    }

    var detail: String {
        switch self {
        case .pushToTalk: "Hold this shortcut while speaking"
        case .toggleDictation: "Press once to start, then again to stop"
        case .toggleMode: "Available while WhisprGo is idle"
        case .cycleProfile: "Available in Pro Mode while idle"
        case .pasteLast: "Inserts the most recent completed dictation"
        }
    }

    var firesModifierShortcutOnRelease: Bool {
        self == .toggleMode || self == .cycleProfile
    }
}

enum HotkeyModifier: String, CaseIterable, Codable, Hashable, Sendable {
    case control
    case option
    case shift
    case command
    case function

    var eventFlag: CGEventFlags {
        switch self {
        case .control: .maskControl
        case .option: .maskAlternate
        case .shift: .maskShift
        case .command: .maskCommand
        case .function: .maskSecondaryFn
        }
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    fileprivate var sortIndex: Int {
        switch self {
        case .function: 0
        case .control: 1
        case .option: 2
        case .shift: 3
        case .command: 4
        }
    }
}

enum HotkeyModifierSide: String, Codable, Hashable, Sendable {
    case any
    case left
    case right
}

struct HotkeyModifierRequirement: Codable, Hashable, Sendable {
    let modifier: HotkeyModifier
    let side: HotkeyModifierSide

    init(_ modifier: HotkeyModifier, side: HotkeyModifierSide = .any) {
        self.modifier = modifier
        self.side = side
    }

    var displayText: String {
        switch side {
        case .any:
            modifier.symbol
        case .left:
            "L\(modifier.symbol)"
        case .right:
            "R\(modifier.symbol)"
        }
    }

    static func physicalModifier(for keyCode: CGKeyCode) -> Self? {
        switch keyCode {
        case 54: Self(.command, side: .right)
        case 55: Self(.command, side: .left)
        case 56: Self(.shift, side: .left)
        case 58: Self(.option, side: .left)
        case 59: Self(.control, side: .left)
        case 60: Self(.shift, side: .right)
        case 61: Self(.option, side: .right)
        case 62: Self(.control, side: .right)
        case 63: Self(.function)
        default: nil
        }
    }

    var physicalKeyCodes: Set<CGKeyCode> {
        switch (modifier, side) {
        case (.command, .left): [55]
        case (.command, .right): [54]
        case (.command, .any): [54, 55]
        case (.shift, .left): [56]
        case (.shift, .right): [60]
        case (.shift, .any): [56, 60]
        case (.option, .left): [58]
        case (.option, .right): [61]
        case (.option, .any): [58, 61]
        case (.control, .left): [59]
        case (.control, .right): [62]
        case (.control, .any): [59, 62]
        case (.function, _): [63]
        }
    }
}

struct HotkeyShortcut: Codable, Hashable, Sendable {
    enum Trigger: Codable, Hashable, Sendable {
        case key(code: UInt16, modifiers: [HotkeyModifier])
        case modifierChord([HotkeyModifierRequirement])
    }

    let trigger: Trigger

    static func key(
        _ code: UInt16,
        modifiers: [HotkeyModifier]
    ) -> Self {
        Self(trigger: .key(
            code: code,
            modifiers: normalizedModifiers(modifiers)
        ))
    }

    static func modifierChord(_ requirements: [HotkeyModifierRequirement]) -> Self {
        let normalized = Array(Set(requirements)).sorted(by: requirementSort)
        return Self(trigger: .modifierChord(normalized))
    }

    var displayComponents: [String] {
        switch trigger {
        case let .key(code, modifiers):
            return modifiers.map(\.symbol) + [Self.keyName(for: code)]
        case let .modifierChord(requirements):
            return requirements.map(\.displayText)
        }
    }

    var displayText: String {
        displayComponents.joined(separator: " + ")
    }

    var validationMessage: String? {
        switch trigger {
        case let .key(code, modifiers):
            guard HotkeyModifierRequirement.physicalModifier(for: CGKeyCode(code)) == nil else {
                return "Record modifier-only shortcuts by releasing the keys together."
            }
            guard !modifiers.isEmpty || Self.functionKeyCodes.contains(code) else {
                return "Add Command, Option, Control, or fn so ordinary typing stays available."
            }
        case let .modifierChord(requirements):
            guard !requirements.isEmpty else {
                return "Press at least one modifier key."
            }
            guard Set(requirements.map(\.modifier)).count == requirements.count else {
                return "Use only one side of each modifier in a shortcut."
            }
        }
        return nil
    }

    func conflicts(with other: Self) -> Bool {
        switch (trigger, other.trigger) {
        case let (.key(lhsCode, lhsModifiers), .key(rhsCode, rhsModifiers)):
            return lhsCode == rhsCode && lhsModifiers == rhsModifiers
        case let (.modifierChord(lhs), .modifierChord(rhs)):
            guard Set(lhs.map(\.modifier)) == Set(rhs.map(\.modifier)) else { return false }
            return lhs.allSatisfy { lhsRequirement in
                guard let rhsRequirement = rhs.first(where: {
                    $0.modifier == lhsRequirement.modifier
                }) else { return false }
                return lhsRequirement.side == .any
                    || rhsRequirement.side == .any
                    || lhsRequirement.side == rhsRequirement.side
            }
        case (.key, .modifierChord), (.modifierChord, .key):
            return false
        }
    }

    var requiredFlags: CGEventFlags {
        switch trigger {
        case let .key(_, modifiers):
            return modifiers.reduce(into: CGEventFlags()) { $0.insert($1.eventFlag) }
        case let .modifierChord(requirements):
            return requirements.reduce(into: CGEventFlags()) { $0.insert($1.modifier.eventFlag) }
        }
    }

    static let relevantFlags: CGEventFlags = [
        .maskControl,
        .maskAlternate,
        .maskShift,
        .maskCommand,
        .maskSecondaryFn,
    ]

    static func flagsMatch(_ actual: CGEventFlags, expected: CGEventFlags) -> Bool {
        actual.intersection(relevantFlags) == expected
    }

    static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
        50: "`", 51: "Delete", 53: "Esc", 65: ".", 67: "*", 69: "+",
        71: "Clear", 75: "/", 76: "Enter", 78: "−", 81: "=", 82: "0",
        83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
        91: "8", 92: "9", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 115: "Home",
        116: "Page Up", 117: "⌦", 118: "F4", 119: "End", 120: "F2",
        121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private static func normalizedModifiers(_ modifiers: [HotkeyModifier]) -> [HotkeyModifier] {
        Array(Set(modifiers)).sorted { $0.sortIndex < $1.sortIndex }
    }

    private static func requirementSort(
        _ lhs: HotkeyModifierRequirement,
        _ rhs: HotkeyModifierRequirement
    ) -> Bool {
        if lhs.modifier.sortIndex != rhs.modifier.sortIndex {
            return lhs.modifier.sortIndex < rhs.modifier.sortIndex
        }
        return lhs.side.rawValue < rhs.side.rawValue
    }
}

struct HotkeyConfiguration: Codable, Equatable, Sendable {
    static let storageKey = "hotkeyConfiguration.v1"

    var pushToTalk: HotkeyShortcut
    var toggleDictation: HotkeyShortcut
    var toggleMode: HotkeyShortcut
    var cycleProfile: HotkeyShortcut
    var pasteLast: HotkeyShortcut

    static let `default` = Self(
        pushToTalk: .modifierChord([.init(.function)]),
        toggleDictation: .modifierChord([.init(.function), .init(.shift)]),
        toggleMode: .modifierChord([.init(.shift, side: .right)]),
        cycleProfile: .modifierChord([
            .init(.control, side: .right),
            .init(.shift, side: .right),
        ]),
        pasteLast: .key(9, modifiers: [.option, .command])
    )

    subscript(action: HotkeyAction) -> HotkeyShortcut {
        get {
            switch action {
            case .pushToTalk: pushToTalk
            case .toggleDictation: toggleDictation
            case .toggleMode: toggleMode
            case .cycleProfile: cycleProfile
            case .pasteLast: pasteLast
            }
        }
        set {
            switch action {
            case .pushToTalk: pushToTalk = newValue
            case .toggleDictation: toggleDictation = newValue
            case .toggleMode: toggleMode = newValue
            case .cycleProfile: cycleProfile = newValue
            case .pasteLast: pasteLast = newValue
            }
        }
    }

    func action(conflictingWith shortcut: HotkeyShortcut, excluding action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first {
            $0 != action && self[$0].conflicts(with: shortcut)
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let configuration = try? JSONDecoder().decode(Self.self, from: data)
        else { return .default }
        return configuration
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
