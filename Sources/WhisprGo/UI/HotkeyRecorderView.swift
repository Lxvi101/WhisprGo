import AppKit
import SwiftUI

struct HotkeyCapsView: View {
    let shortcut: HotkeyShortcut
    var compact = false
    var inverted = false

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            ForEach(Array(shortcut.displayComponents.enumerated()), id: \.offset) { _, component in
                MinimalKeyCap(component, inverted: inverted, compact: compact)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.displayComponents.joined(separator: " plus "))
    }
}

struct HotkeyRecorderRow: View {
    let action: HotkeyAction
    let shortcut: HotkeyShortcut
    let isRecording: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    let onCapture: (HotkeyShortcut) -> Void

    var body: some View {
        HStack(spacing: 18) {
            Text(action.title)
                .help(action.detail)

            Spacer(minLength: 12)

            Button(action: onStart) {
                Group {
                    if isRecording {
                        Text("Press keys…")
                            .font(.system(size: 11))
                            .foregroundStyle(Signal.textSecondary)
                    } else {
                        HotkeyCapsView(shortcut: shortcut, compact: true)
                    }
                }
                .transition(.blurReplace)
                .frame(minWidth: 96, minHeight: 24)
                .padding(.horizontal, 6)
                .background(
                    Signal.surface,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isRecording ? Color.primary.opacity(0.6) : Signal.hairline,
                            lineWidth: 1
                        )
                }
                .animation(Signal.quick, value: isRecording)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change \(action.title) shortcut")
            .background {
                HotkeyCaptureView(
                    isActive: isRecording,
                    action: action,
                    onCapture: onCapture,
                    onCancel: onCancel
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
        }
    }
}

private struct HotkeyCaptureView: NSViewRepresentable {
    let isActive: Bool
    let action: HotkeyAction
    let onCapture: (HotkeyShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyCaptureNSView {
        let view = HotkeyCaptureNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: HotkeyCaptureNSView, context: Context) {
        configure(view)
        guard isActive else {
            if view.window?.firstResponder === view {
                view.window?.makeFirstResponder(nil)
            }
            return
        }
        DispatchQueue.main.async { [weak view] in
            guard let view, view.isActive else { return }
            view.window?.makeFirstResponder(view)
        }
    }

    private func configure(_ view: HotkeyCaptureNSView) {
        let wasActive = view.isActive
        view.isActive = isActive
        view.action = action
        view.onCapture = onCapture
        view.onCancel = onCancel
        if isActive, !wasActive {
            view.resetCapture()
        }
    }
}

private final class HotkeyCaptureNSView: NSView {
    var isActive = false
    var action = HotkeyAction.toggleDictation
    var onCapture: ((HotkeyShortcut) -> Void)?
    var onCancel: (() -> Void)?

    private var pressedModifierKeyCodes: Set<CGKeyCode> = []
    private var capturedRequirements: Set<HotkeyModifierRequirement> = []

    override var acceptsFirstResponder: Bool { true }

    func resetCapture() {
        pressedModifierKeyCodes.removeAll()
        capturedRequirements.removeAll()
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        let modifiers = HotkeyModifier.allCases.filter { modifier in
            event.modifierFlags.contains(modifier.appKitFlag)
        }
        let shortcut = HotkeyShortcut.key(event.keyCode, modifiers: modifiers)
        resetCapture()
        onCapture?(shortcut)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActive else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isActive,
              let requirement = HotkeyModifierRequirement.physicalModifier(
                for: CGKeyCode(event.keyCode)
              )
        else {
            super.flagsChanged(with: event)
            return
        }

        let keyCode = CGKeyCode(event.keyCode)
        if pressedModifierKeyCodes.contains(keyCode) {
            pressedModifierKeyCodes.remove(keyCode)
        } else if event.modifierFlags.contains(requirement.modifier.appKitFlag) {
            pressedModifierKeyCodes.insert(keyCode)
        }

        let current = Set(pressedModifierKeyCodes.compactMap {
            HotkeyModifierRequirement.physicalModifier(for: $0)
        })
        if current.count >= capturedRequirements.count {
            capturedRequirements = current
        }

        if pressedModifierKeyCodes.isEmpty, !capturedRequirements.isEmpty {
            let shortcut = HotkeyShortcut.modifierChord(Array(capturedRequirements))
            resetCapture()
            onCapture?(shortcut)
        }
    }
}

private extension HotkeyModifier {
    var appKitFlag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        case .function: .function
        }
    }
}
