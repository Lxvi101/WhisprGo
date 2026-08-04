import AppKit

@MainActor
final class ModeBadgeOverlay {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var pendingHide: DispatchWorkItem?

    func show(_ text: String) {
        pendingHide?.cancel()
        ensurePanel()
        guard let panel, let label else { return }

        label.stringValue = text
        label.sizeToFit()
        let width = max(126, min(240, label.frame.width + 58))
        panel.setContentSize(NSSize(width: width, height: 38))
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: work)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 150, height: 38))
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 19
        material.layer?.masksToBounds = true

        let dots = NSStackView()
        dots.orientation = .horizontal
        dots.spacing = 3
        dots.alignment = .centerY
        for diameter in [3.0, 6.0, 3.0] {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.labelColor.cgColor
            dot.layer?.cornerRadius = diameter / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: diameter),
                dot.heightAnchor.constraint(equalToConstant: diameter),
            ])
            dots.addArrangedSubview(dot)
        }

        let label = NSTextField(labelWithString: "Fast Mode")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [dots, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: material.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: material.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: material.trailingAnchor, constant: -14),
        ])

        let panel = NSPanel(
            contentRect: material.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        panel.contentView = material
        self.panel = panel
        self.label = label
    }

    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 30
        ))
    }
}
