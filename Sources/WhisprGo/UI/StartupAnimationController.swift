import AppKit
import QuartzCore

/// A one-shot launch mark rendered directly from the canonical SVG. The image
/// is decoded once and the entire animation stays on the compositor.
@MainActor
final class StartupAnimationController {
    static let shared = StartupAnimationController()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    func show() {
        dismissWorkItem?.cancel()

        let content = StartupLogoView(
            frame: NSRect(x: 0, y: 0, width: 306, height: 244)
        )
        let panel = NSPanel(
            contentRect: content.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = content

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY - panel.frame.height / 2
            ))
        }

        self.panel?.orderOut(nil)
        self.panel = panel
        panel.orderFrontRegardless()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        content.beginAnimation(reduceMotion: reduceMotion)

        let dismiss = DispatchWorkItem { [weak self, weak content] in
            guard let self else { return }
            content?.finishAnimation(reduceMotion: reduceMotion)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.panel?.orderOut(nil)
                self?.panel = nil
            }
        }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.04, execute: dismiss)
    }
}

@MainActor
private final class StartupLogoView: NSView {
    private static let logoImage: CGImage? = {
        guard let source = BrandAssets.fullLogo else { return nil }
        var proposedRect = NSRect(x: 0, y: 0, width: 524, height: 409)
        return source.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }()

    private let logoLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func beginAnimation(reduceMotion: Bool) {
        guard let root = layer else { return }
        root.removeAllAnimations()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduceMotion ? 0.18 : 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(fade, forKey: "appear")

        guard !reduceMotion else { return }
        let settle = CASpringAnimation(keyPath: "transform.scale")
        settle.fromValue = 0.95
        settle.toValue = 1
        settle.mass = 1
        settle.stiffness = 255
        settle.damping = 31
        settle.initialVelocity = 0
        settle.duration = min(0.42, settle.settlingDuration)
        root.add(settle, forKey: "settle")
    }

    func finishAnimation(reduceMotion: Bool) {
        guard let root = layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = root.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = reduceMotion ? 0.16 : 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        root.add(fade, forKey: "dismiss")

        guard !reduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.985
        scale.duration = 0.18
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        root.add(scale, forKey: "dismissScale")
    }

    private func configureLayers() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.backgroundColor = NSColor.white.cgColor
        root.cornerRadius = 28
        root.cornerCurve = .continuous
        root.borderWidth = 1
        root.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        root.masksToBounds = true

        logoLayer.frame = bounds.insetBy(dx: 18, dy: 16)
        logoLayer.contents = Self.logoImage
        logoLayer.contentsGravity = .resizeAspect
        logoLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        logoLayer.minificationFilter = .trilinear
        root.addSublayer(logoLayer)
        CATransaction.commit()
    }
}
