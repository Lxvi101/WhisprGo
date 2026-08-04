import AppKit
import QuartzCore

/// A one-shot, compositor-only launch mark. It does not create a SwiftUI
/// render loop, start a timer, or delay model preparation.
@MainActor
final class StartupAnimationController {
    static let shared = StartupAnimationController()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    func show() {
        dismissWorkItem?.cancel()

        let content = StartupLogoView(
            frame: NSRect(x: 0, y: 0, width: 284, height: 112)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                self?.panel?.orderOut(nil)
                self?.panel = nil
            }
        }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.18, execute: dismiss)
    }
}

@MainActor
private final class StartupLogoView: NSView {
    private let mark = CALayer()
    private let bars: [CALayer]
    private let swoosh = CAShapeLayer()
    private let wordmark = CATextLayer()

    override init(frame frameRect: NSRect) {
        bars = (0..<7).map { _ in CALayer() }
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
        let now = CACurrentMediaTime()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduceMotion ? 0.18 : 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(fade, forKey: "appear")

        guard !reduceMotion else { return }

        let settle = CASpringAnimation(keyPath: "transform.scale")
        settle.fromValue = 0.88
        settle.toValue = 1
        settle.mass = 1
        settle.stiffness = 240
        settle.damping = 30
        settle.initialVelocity = 0
        settle.duration = min(0.5, settle.settlingDuration)
        root.add(settle, forKey: "settle")

        for (index, bar) in bars.enumerated() {
            let bloom = CASpringAnimation(keyPath: "transform.scale.y")
            bloom.fromValue = 0.08
            bloom.toValue = 1
            bloom.mass = 1
            bloom.stiffness = 290
            bloom.damping = 27
            bloom.initialVelocity = 0
            bloom.beginTime = now + 0.05 + Double(abs(index - 3)) * 0.025
            bloom.duration = min(0.44, bloom.settlingDuration)
            bloom.fillMode = .backwards
            bar.add(bloom, forKey: "bloom")
        }

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = now + 0.24
        draw.duration = 0.34
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        swoosh.add(draw, forKey: "draw")

        let reveal = CAAnimationGroup()
        let wordFade = CABasicAnimation(keyPath: "opacity")
        wordFade.fromValue = 0
        wordFade.toValue = 1
        let wordMove = CABasicAnimation(keyPath: "transform.translation.x")
        wordMove.fromValue = -7
        wordMove.toValue = 0
        reveal.animations = [wordFade, wordMove]
        reveal.beginTime = now + 0.2
        reveal.duration = 0.28
        reveal.fillMode = .backwards
        reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wordmark.add(reveal, forKey: "reveal")
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
        scale.toValue = 0.97
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

        root.backgroundColor = NSColor(
            calibratedRed: 0.035,
            green: 0.045,
            blue: 0.075,
            alpha: 0.97
        ).cgColor
        root.cornerRadius = 28
        root.cornerCurve = .continuous
        root.borderWidth = 1
        root.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        root.masksToBounds = true

        mark.frame = CGRect(x: 22, y: 18, width: 78, height: 76)
        root.addSublayer(mark)

        let heights: [CGFloat] = [22, 38, 58, 40, 50, 34, 22]
        let colors = [
            NSColor(calibratedRed: 0.71, green: 0.91, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.58, green: 0.86, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.44, green: 0.80, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.38, green: 0.72, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.43, green: 0.61, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.48, green: 0.48, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.58, green: 0.36, blue: 1, alpha: 1),
        ]
        let barWidth: CGFloat = 5
        let spacing: CGFloat = 5.5
        for (index, bar) in bars.enumerated() {
            let height = heights[index]
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: height)
            bar.position = CGPoint(
                x: 6 + barWidth / 2 + CGFloat(index) * (barWidth + spacing),
                y: 33
            )
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.backgroundColor = colors[index].cgColor
            bar.cornerRadius = barWidth / 2
            mark.addSublayer(bar)
        }

        let swooshPath = CGMutablePath()
        swooshPath.move(to: CGPoint(x: 8, y: 66))
        swooshPath.addCurve(
            to: CGPoint(x: 66, y: 56),
            control1: CGPoint(x: 27, y: 76),
            control2: CGPoint(x: 52, y: 72)
        )
        swooshPath.addLine(to: CGPoint(x: 61, y: 51))
        swooshPath.move(to: CGPoint(x: 66, y: 56))
        swooshPath.addLine(to: CGPoint(x: 59, y: 58))
        swoosh.path = swooshPath
        swoosh.fillColor = nil
        swoosh.strokeColor = NSColor(
            calibratedRed: 0.48,
            green: 0.43,
            blue: 1,
            alpha: 1
        ).cgColor
        swoosh.lineWidth = 4
        swoosh.lineCap = .round
        swoosh.lineJoin = .round
        mark.addSublayer(swoosh)

        let text = NSMutableAttributedString(
            string: "WhisprGo",
            attributes: [
                .font: NSFont.systemFont(ofSize: 29, weight: .semibold),
                .foregroundColor: NSColor.white,
                .kern: -1.05,
            ]
        )
        text.addAttribute(
            .foregroundColor,
            value: NSColor(calibratedRed: 0.57, green: 0.43, blue: 1, alpha: 1),
            range: NSRange(location: 6, length: 2)
        )
        wordmark.string = text
        wordmark.frame = CGRect(x: 108, y: 38, width: 158, height: 42)
        wordmark.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        wordmark.alignmentMode = .left
        root.addSublayer(wordmark)

        CATransaction.commit()
    }
}
