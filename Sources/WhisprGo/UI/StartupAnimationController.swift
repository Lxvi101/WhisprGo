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
            frame: NSRect(x: 0, y: 0, width: 300, height: 184)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.08, execute: dismiss)
    }
}

@MainActor
private final class StartupLogoView: NSView {
    private struct WaveformColumn {
        let x: CGFloat
        let start: CGFloat
        let count: Int
    }

    private static let waveform: [WaveformColumn] = [
        .init(x: 30, start: 150, count: 1),
        .init(x: 56, start: 140, count: 3),
        .init(x: 82, start: 120, count: 5),
        .init(x: 108, start: 130, count: 4),
        .init(x: 134, start: 90, count: 6),
        .init(x: 160, start: 60, count: 7),
        .init(x: 186, start: 80, count: 6),
        .init(x: 212, start: 120, count: 6),
        .init(x: 238, start: 140, count: 7),
        .init(x: 264, start: 120, count: 6),
        .init(x: 290, start: 80, count: 9),
        .init(x: 316, start: 40, count: 11),
        .init(x: 342, start: 20, count: 13),
        .init(x: 368, start: 40, count: 11),
        .init(x: 394, start: 70, count: 9),
        .init(x: 420, start: 110, count: 8),
        .init(x: 446, start: 150, count: 8),
        .init(x: 472, start: 170, count: 7),
        .init(x: 498, start: 130, count: 9),
        .init(x: 524, start: 90, count: 9),
        .init(x: 550, start: 80, count: 8),
        .init(x: 576, start: 100, count: 7),
        .init(x: 602, start: 120, count: 6),
        .init(x: 628, start: 130, count: 5),
        .init(x: 654, start: 140, count: 3),
        .init(x: 680, start: 150, count: 1),
    ]

    private let mark = CALayer()
    private var columns: [CAShapeLayer] = []
    private let wordmark = CATextLayer()

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
        let now = CACurrentMediaTime()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduceMotion ? 0.18 : 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(fade, forKey: "appear")

        guard !reduceMotion else { return }

        let settle = CASpringAnimation(keyPath: "transform.scale")
        settle.fromValue = 0.96
        settle.toValue = 1
        settle.mass = 1
        settle.stiffness = 260
        settle.damping = 32
        settle.initialVelocity = 0
        settle.duration = min(0.42, settle.settlingDuration)
        root.add(settle, forKey: "settle")

        for (index, column) in columns.enumerated() {
            let delay = 0.025 + Double(index) * 0.011

            let bloom = CASpringAnimation(keyPath: "transform.scale")
            bloom.fromValue = 0.28
            bloom.toValue = 1
            bloom.mass = 1
            bloom.stiffness = 300
            bloom.damping = 28
            bloom.initialVelocity = 0
            bloom.beginTime = now + delay
            bloom.duration = min(0.38, bloom.settlingDuration)
            bloom.fillMode = .backwards
            column.add(bloom, forKey: "bloom")

            let dotFade = CABasicAnimation(keyPath: "opacity")
            dotFade.fromValue = 0
            dotFade.toValue = 1
            dotFade.beginTime = now + delay
            dotFade.duration = 0.12
            dotFade.fillMode = .backwards
            column.add(dotFade, forKey: "fade")
        }

        let wordFade = CABasicAnimation(keyPath: "opacity")
        wordFade.fromValue = 0
        wordFade.toValue = 1
        wordFade.beginTime = now + 0.28
        wordFade.duration = 0.22
        wordFade.fillMode = .backwards
        wordFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wordmark.add(wordFade, forKey: "reveal")
    }

    func finishAnimation(reduceMotion: Bool) {
        guard let root = layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = root.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = reduceMotion ? 0.16 : 0.17
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        root.add(fade, forKey: "dismiss")

        guard !reduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.98
        scale.duration = 0.17
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

        let sourceScale: CGFloat = 0.35
        let dotRadius: CGFloat = 1.75
        let sourceSpacing: CGFloat = 20
        mark.frame = CGRect(x: 24, y: 18, width: 252, height: 105)
        root.addSublayer(mark)

        for specification in Self.waveform {
            let dotSpacing = sourceSpacing * sourceScale
            let height = CGFloat(specification.count - 1) * dotSpacing + dotRadius * 2
            let column = CAShapeLayer()
            column.bounds = CGRect(x: 0, y: 0, width: dotRadius * 2, height: height)
            column.position = CGPoint(
                x: specification.x * sourceScale,
                y: (specification.start
                    + CGFloat(specification.count - 1) * sourceSpacing / 2) * sourceScale
            )
            column.anchorPoint = CGPoint(x: 0.5, y: 0.5)

            let path = CGMutablePath()
            for dotIndex in 0..<specification.count {
                path.addEllipse(in: CGRect(
                    x: 0,
                    y: CGFloat(dotIndex) * dotSpacing,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
            }
            column.path = path
            column.fillColor = NSColor(calibratedWhite: 0.04, alpha: 1).cgColor
            mark.addSublayer(column)
            columns.append(column)
        }

        wordmark.string = NSAttributedString(
            string: "WhisprGo",
            attributes: [
                .font: NSFont.systemFont(ofSize: 39, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.04, alpha: 1),
                .kern: -1.6,
            ]
        )
        wordmark.frame = CGRect(x: 42, y: 130, width: 216, height: 48)
        wordmark.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        wordmark.alignmentMode = .center
        root.addSublayer(wordmark)

        CATransaction.commit()
    }
}
