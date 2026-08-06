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
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(action.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: onStart) {
                Group {
                    if isRecording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.orange)
                                .frame(width: 7, height: 7)
                            Text("Press shortcut…")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    } else {
                        HotkeyCapsView(shortcut: shortcut, compact: true)
                    }
                }
                .frame(minWidth: 112, minHeight: 26)
                .padding(.horizontal, 8)
                .background(
                    isRecording ? Color.orange.opacity(0.08) : Color(nsColor: .controlBackgroundColor)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            isRecording ? Color.orange : Color.primary.opacity(0.14),
                            lineWidth: isRecording ? 1.5 : 1
                        )
                }
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
        .padding(.vertical, 3)
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
