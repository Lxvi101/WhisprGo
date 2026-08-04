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
    private var gestureState = HotkeyGestureState()
    private var modeShortcutState = ModeShortcutState()
    private var pendingPushToTalk: DispatchWorkItem?
    private var pushToTalkIsActive = false

    func start(onEvent: @escaping (Event) -> Void) throws {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            throw HotkeyError.accessibilityPermissionRequired
        }
        self.onEvent = onEvent

        let eventMask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.keyDown.rawValue)
        )
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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
        pendingPushToTalk?.cancel()
        pendingPushToTalk = nil
        pushToTalkIsActive = false
        onEvent = nil
        gestureState = HotkeyGestureState()
        modeShortcutState = ModeShortcutState()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            modeShortcutState = ModeShortcutState()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        if let modeAction = modeShortcutState.consume(
            type: type,
            keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags
        ) {
            switch modeAction {
            case .toggleMode:
                onEvent?(.toggleMode)
            case .cycleProfile:
                onEvent?(.cycleProfile)
            }
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if Self.isPasteLastShortcut(
            type: type,
            keyCode: keyCode,
            flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        ) {
            onEvent?(.pasteLast)
        }

        guard type == .flagsChanged else { return }
        let actions = gestureState.consume(
            flags: event.flags,
            pushToTalkIsActive: pushToTalkIsActive
        )
        for action in actions {
            perform(action)
        }
    }

    static func isPasteLastShortcut(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool = false
    ) -> Bool {
        type == .keyDown
            && keyCode == 9
            && !isRepeat
            && flags.contains(.maskControl)
            && flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskSecondaryFn)
    }

    private func perform(_ action: HotkeyGestureState.Action) {
        switch action {
        case .schedulePushToTalk:
            pendingPushToTalk?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.gestureState.canBeginPushToTalk else { return }
                self.pushToTalkIsActive = true
                self.onEvent?(.pushToTalkBegan)
            }
            pendingPushToTalk = work
            // A modifier chord arrives as two flag events. This tiny grace
            // window prevents fn + shift from briefly starting the microphone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)

        case .cancelPendingPushToTalk:
            pendingPushToTalk?.cancel()
            pendingPushToTalk = nil

        case .endPushToTalk:
            pushToTalkIsActive = false
            onEvent?(.pushToTalkEnded)

        case .cancelActivePushToTalk:
            pushToTalkIsActive = false
            onEvent?(.pushToTalkCancelled)

        case .toggle:
            onEvent?(.toggle)
        }
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
    monitor.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
