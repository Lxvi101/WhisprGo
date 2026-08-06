import ApplicationServices
import CoreGraphics
import Foundation

struct HotkeyGestureState {
    enum Action: Equatable {
        case schedulePushToTalk
        case cancelPendingPushToTalk
        case endPushToTalk
        case cancelActivePushToTalk
        case toggle
    }

    private(set) var functionIsDown = false
    private(set) var shiftIsDown = false
    private(set) var chordWasConsumed = false

    var canBeginPushToTalk: Bool {
        functionIsDown && !shiftIsDown && !chordWasConsumed
    }

    mutating func consume(
        flags: CGEventFlags,
        pushToTalkIsActive: Bool
    ) -> [Action] {
        let wasFunctionDown = functionIsDown
        functionIsDown = flags.contains(.maskSecondaryFn)
        shiftIsDown = flags.contains(.maskShift)

        if functionIsDown && shiftIsDown {
            guard !chordWasConsumed else { return [] }
            chordWasConsumed = true
            var actions: [Action] = [.cancelPendingPushToTalk]
            if pushToTalkIsActive {
                actions.append(.cancelActivePushToTalk)
            }
            actions.append(.toggle)
            return actions
        }

        if !functionIsDown {
            var actions: [Action] = [.cancelPendingPushToTalk]
            if pushToTalkIsActive {
                actions.append(.endPushToTalk)
            }
            if !shiftIsDown {
                chordWasConsumed = false
            }
            return actions
        }

        guard !wasFunctionDown, !chordWasConsumed else { return [] }
        return [.schedulePushToTalk]
    }
}

struct ModeShortcutState {
    enum Action: Equatable {
        case toggleMode
        case cycleProfile
    }

    private static let rightShiftKeyCode: CGKeyCode = 60
    private static let leftShiftKeyCode: CGKeyCode = 56
    private static let rightControlKeyCode: CGKeyCode = 62

    private var rightShiftCandidate = false
    private var profileChord = false
    private var rightControlIsDown = false
    private var leftShiftIsDown = false

    mutating func consume(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> Action? {
        if type == .keyDown {
            rightShiftCandidate = false
            profileChord = false
            return nil
        }

        guard type == .flagsChanged else { return nil }

        if keyCode == Self.leftShiftKeyCode {
            if flags.contains(.maskShift) {
                leftShiftIsDown.toggle()
            } else {
                leftShiftIsDown = false
            }
            rightShiftCandidate = false
            profileChord = false
            return nil
        }

        if flags.contains(.maskSecondaryFn)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskCommand) {
            rightShiftCandidate = false
            profileChord = false
            return nil
        }

        if keyCode == Self.rightControlKeyCode {
            if flags.contains(.maskControl) {
                rightControlIsDown.toggle()
            } else {
                rightControlIsDown = false
            }
            if rightShiftCandidate, rightControlIsDown {
                profileChord = true
            }
            return nil
        }

        guard keyCode == Self.rightShiftKeyCode else { return nil }
        if flags.contains(.maskShift) {
            guard !leftShiftIsDown,
                  !flags.contains(.maskControl) || rightControlIsDown
            else {
                rightShiftCandidate = false
                profileChord = false
                return nil
            }
            rightShiftCandidate = true
            profileChord = rightControlIsDown
            return nil
        }

        guard rightShiftCandidate else { return nil }
        defer {
            rightShiftCandidate = false
            profileChord = false
        }
        return profileChord ? .cycleProfile : .toggleMode
    }
}

final class HotkeyMonitor {
    enum Event {
        case pushToTalkBegan
        case pushToTalkEnded
        case pushToTalkCancelled
        case toggle
        case toggleMode
        case cycleProfile
        case pasteLast
    }

    enum HotkeyError: LocalizedError {
        case accessibilityPermissionRequired
        case eventTapCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionRequired:
                return "Accessibility permission is required for the global shortcut."
            case .eventTapCreationFailed:
                return "macOS could not register the global shortcut."
            }
        }
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onEvent: ((Event) -> Void)?
    private var configuration = HotkeyConfiguration.default
    private var pressedModifierKeyCodes: Set<CGKeyCode> = []
    private var activeModifierActions: Set<HotkeyAction> = []
    private var modifierReleaseCandidates: Set<HotkeyAction> = []
    private var suppressedKeyCodes: Set<CGKeyCode> = []
    private var activeKeyPushToTalkCode: CGKeyCode?
    private var pendingPushToTalk: DispatchWorkItem?
    private var pushToTalkIsActive = false
    private var pushToTalkWasConsumed = false

    func start(
        configuration: HotkeyConfiguration,
        onEvent: @escaping (Event) -> Void
    ) throws {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            throw HotkeyError.accessibilityPermissionRequired
        }
        self.configuration = configuration
        self.onEvent = onEvent

        let eventMask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
        )
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyEventCallback,
            userInfo: userInfo
        ) else {
            self.onEvent = nil
            throw HotkeyError.eventTapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func update(configuration: HotkeyConfiguration) {
        resetShortcutState(cancelActivePushToTalk: true)
        self.configuration = configuration
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        resetShortcutState(cancelActivePushToTalk: false)
        onEvent = nil
    }

    /// Returns true for key-based shortcuts so their keystrokes do not also
    /// reach the foreground application.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetShortcutState(cancelActivePushToTalk: true)
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .flagsChanged:
            handleModifierChange(keyCode: keyCode, flags: event.flags)
            return false
        case .keyDown:
            return handleKeyDown(
                keyCode: keyCode,
                flags: event.flags,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp:
            return handleKeyUp(keyCode: keyCode)
        default:
            return false
        }
    }

    static func isPasteLastChord(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> Bool {
        type == .keyDown
            && keyCode == 9
            && flags.contains(.maskCommand)
            && flags.contains(.maskAlternate)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskSecondaryFn)
    }

    static func isPasteLastShortcut(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool = false
    ) -> Bool {
        Self.isPasteLastChord(type: type, keyCode: keyCode, flags: flags)
            && !isRepeat
    }

    private func handleModifierChange(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let changedModifier = HotkeyModifierRequirement.physicalModifier(for: keyCode) else {
            modifierReleaseCandidates.removeAll()
            return
        }

        let changedKeyIsDown: Bool
        if pressedModifierKeyCodes.contains(keyCode) {
            pressedModifierKeyCodes.remove(keyCode)
            changedKeyIsDown = false
        } else if flags.contains(changedModifier.modifier.eventFlag) {
            pressedModifierKeyCodes.insert(keyCode)
            changedKeyIsDown = true
        } else {
            changedKeyIsDown = false
        }

        let previouslyActive = activeModifierActions
        let nowActive = Set(HotkeyAction.allCases.filter { action in
            Self.modifierShortcutMatches(
                configuration: configuration,
                action: action,
                flags: flags,
                pressedModifierKeyCodes: pressedModifierKeyCodes
            )
        })
        activeModifierActions = nowActive

        for action in previouslyActive.subtracting(nowActive) {
            if action == .pushToTalk {
                finishModifierPushToTalk(cancelled: changedKeyIsDown)
            } else {
                let shouldFire = !changedKeyIsDown
                    && modifierReleaseCandidates.contains(action)
                    && action.firesModifierShortcutOnRelease
                modifierReleaseCandidates.remove(action)
                if shouldFire {
                    consumePushToTalkIfNeeded()
                    perform(action)
                }
            }
        }

        for action in nowActive.subtracting(previouslyActive) {
            if action == .pushToTalk {
                scheduleModifierPushToTalk()
            } else if pushToTalkWasConsumed {
                continue
            } else if action.firesModifierShortcutOnRelease {
                modifierReleaseCandidates.insert(action)
            } else {
                consumePushToTalkIfNeeded()
                perform(action)
            }
        }

        if pressedModifierKeyCodes.isEmpty {
            pushToTalkWasConsumed = false
            modifierReleaseCandidates = modifierReleaseCandidates.intersection(nowActive)
        }
    }

    private func handleKeyDown(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        modifierReleaseCandidates.removeAll()
        guard let action = Self.keyShortcutAction(
            configuration: configuration,
            keyCode: keyCode,
            flags: flags
        ) else {
            return false
        }

        suppressedKeyCodes.insert(keyCode)
        guard !isRepeat else { return true }
        if action == .pushToTalk {
            activeKeyPushToTalkCode = keyCode
            beginPushToTalk()
        } else {
            consumePushToTalkIfNeeded()
            perform(action)
        }
        return true
    }

    private func handleKeyUp(keyCode: CGKeyCode) -> Bool {
        let shouldSuppress = suppressedKeyCodes.remove(keyCode) != nil
        if activeKeyPushToTalkCode == keyCode {
            activeKeyPushToTalkCode = nil
            endPushToTalk(cancelled: false)
        }
        return shouldSuppress
    }

    static func modifierShortcutMatches(
        configuration: HotkeyConfiguration,
        action: HotkeyAction,
        flags: CGEventFlags,
        pressedModifierKeyCodes: Set<CGKeyCode>
    ) -> Bool {
        guard case let .modifierChord(requirements) = configuration[action].trigger,
              HotkeyShortcut.flagsMatch(flags, expected: configuration[action].requiredFlags)
        else { return false }

        return requirements.allSatisfy { requirement in
            switch requirement.side {
            case .any:
                return flags.contains(requirement.modifier.eventFlag)
            case .left, .right:
                return !requirement.physicalKeyCodes.isDisjoint(with: pressedModifierKeyCodes)
            }
        }
    }

    static func keyShortcutAction(
        configuration: HotkeyConfiguration,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> HotkeyAction? {
        HotkeyAction.allCases.first { action in
            guard case let .key(code, _) = configuration[action].trigger else { return false }
            return code == UInt16(keyCode)
                && HotkeyShortcut.flagsMatch(flags, expected: configuration[action].requiredFlags)
        }
    }

    private func scheduleModifierPushToTalk() {
        guard !pushToTalkWasConsumed else { return }
        pendingPushToTalk?.cancel()
        let expectedShortcut = configuration[.pushToTalk]
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.pushToTalkWasConsumed,
                  self.activeModifierActions.contains(.pushToTalk),
                  self.configuration[.pushToTalk] == expectedShortcut
            else { return }
            self.beginPushToTalk()
        }
        pendingPushToTalk = work
        // Modifier chords arrive as separate flag events. This brief grace
        // period prevents a shorter chord from activating on the way to a
        // longer configured shortcut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func finishModifierPushToTalk(cancelled: Bool) {
        pendingPushToTalk?.cancel()
        pendingPushToTalk = nil
        guard pushToTalkIsActive else { return }
        endPushToTalk(cancelled: cancelled || pushToTalkWasConsumed)
    }

    private func beginPushToTalk() {
        pendingPushToTalk?.cancel()
        pendingPushToTalk = nil
        guard !pushToTalkIsActive else { return }
        pushToTalkIsActive = true
        onEvent?(.pushToTalkBegan)
    }

    private func endPushToTalk(cancelled: Bool) {
        guard pushToTalkIsActive else { return }
        pushToTalkIsActive = false
        onEvent?(cancelled ? .pushToTalkCancelled : .pushToTalkEnded)
    }

    private func consumePushToTalkIfNeeded() {
        pushToTalkWasConsumed = true
        pendingPushToTalk?.cancel()
        pendingPushToTalk = nil
        if pushToTalkIsActive {
            endPushToTalk(cancelled: true)
        }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .pushToTalk:
            break
        case .toggleDictation:
            onEvent?(.toggle)
        case .toggleMode:
            onEvent?(.toggleMode)
        case .cycleProfile:
            onEvent?(.cycleProfile)
        case .pasteLast:
            onEvent?(.pasteLast)
        }
    }

    private func resetShortcutState(cancelActivePushToTalk: Bool) {
        pendingPushToTalk?.cancel()
        pendingPushToTalk = nil
        if cancelActivePushToTalk, pushToTalkIsActive {
            onEvent?(.pushToTalkCancelled)
        }
        pushToTalkIsActive = false
        activeKeyPushToTalkCode = nil
        pressedModifierKeyCodes.removeAll()
        activeModifierActions.removeAll()
        modifierReleaseCandidates.removeAll()
        suppressedKeyCodes.removeAll()
        pushToTalkWasConsumed = false
    }
}

private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}
