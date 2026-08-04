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

final class HotkeyMonitor {
    enum Event {
        case pushToTalkBegan
        case pushToTalkEnded
        case pushToTalkCancelled
        case toggle
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
    private var pendingPushToTalk: DispatchWorkItem?
    private var pushToTalkIsActive = false

    func start(onEvent: @escaping (Event) -> Void) throws {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            throw HotkeyError.accessibilityPermissionRequired
        }
        self.onEvent = onEvent

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
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
