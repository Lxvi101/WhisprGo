import AppKit
import QuartzCore

@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case transcribing
        case error
    }

    private let levelMeter: AudioLevelMeter
    private var panel: NSPanel?
    private var waveformView: WaveformOverlayView?
    private var displayLink: CADisplayLink?
    private var pendingHide: DispatchWorkItem?
    private var displayedLevel: Float = 0
    private var previousTimestamp: CFTimeInterval = 0

    init(levelMeter: AudioLevelMeter) {
        self.levelMeter = levelMeter
    }

    func show(_ state: State) {
        pendingHide?.cancel()
        ensurePanel()
        guard let panel, let waveformView else { return }

        let screen = position(panel)
        waveformView.setState(state)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        if state == .recording {
            displayedLevel = 0
            previousTimestamp = 0
            waveformView.update(level: 0)
            startDisplayLink(on: screen)
        } else {
            stopDisplayLink()
        }
    }

    func hide(after delay: TimeInterval = 0.14) {
        pendingHide?.cancel()
        stopDisplayLink()

        let work = DispatchWorkItem { [weak self] in
            self?.waveformView?.setState(.hidden)
            self?.panel?.orderOut(nil)
        }
        pendingHide = work
        if delay <= 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let content = WaveformOverlayView(frame: NSRect(x: 0, y: 0, width: 104, height: 42))
        let panel = NSPanel(
            contentRect: content.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        panel.contentView = content
        self.waveformView = content
        self.panel = panel
    }

    @discardableResult
    private func position(_ panel: NSPanel) -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 30
        ))
        return screen
    }

    private func startDisplayLink(on screen: NSScreen?) {
        stopDisplayLink()
        guard let screen else { return }

        let link = screen.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 60,
            preferred: 60
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = 0
    }

    @objc
    private func displayLinkDidFire(_ link: CADisplayLink) {
        let rawLevel = max(0, min(1, levelMeter.load()))
        let target = max(0.06, min(1, sqrt(rawLevel) * 2.8))

        let elapsed = previousTimestamp == 0
            ? (1.0 / 60.0)
            : min(1.0 / 15.0, max(1.0 / 240.0, link.timestamp - previousTimestamp))
        previousTimestamp = link.timestamp

        // Fast attack keeps speech visually immediate; the gentler release
        // prevents jitter without queueing or retargeting Core Animation jobs.
        let response = target > displayedLevel ? 34.0 : 17.0
        let blend = Float(1 - exp(-response * elapsed))
        displayedLevel += (target - displayedLevel) * blend
        waveformView?.update(level: displayedLevel)
    }
}

@MainActor
private final class WaveformOverlayView: NSView {
    private static let envelope: [CGFloat] = [
        0.35, 0.50, 0.68, 0.84, 0.96, 1.0,
        0.96, 0.84, 0.68, 0.50, 0.35,
    ]

    private let barsContainer = CALayer()
    private let bars: [CALayer]
    private let spinner = CAShapeLayer()
    private let errorMark = CATextLayer()

    override init(frame frameRect: NSRect) {
        bars = Self.envelope.map { _ in CALayer() }
        super.init(frame: frameRect)
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func setState(_ state: RecordingOverlay.State) {
        switch state {
        case .hidden:
            barsContainer.isHidden = true
            spinner.isHidden = true
            errorMark.isHidden = true
            spinner.removeAnimation(forKey: "spin")

        case .recording:
            barsContainer.isHidden = false
            spinner.isHidden = true
            errorMark.isHidden = true
            spinner.removeAnimation(forKey: "spin")

        case .transcribing:
            barsContainer.isHidden = true
            spinner.isHidden = false
            errorMark.isHidden = true
            startSpinner()

        case .error:
            barsContainer.isHidden = true
            spinner.isHidden = true
            errorMark.isHidden = false
            spinner.removeAnimation(forKey: "spin")
        }
    }

    func update(level: Float) {
        let amplitude = CGFloat(max(0.06, min(1, level)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let scale = max(0.16, amplitude * Self.envelope[index])
            bar.setAffineTransform(CGAffineTransform(scaleX: 1, y: scale))
        }
        CATransaction.commit()
    }

    private func configureLayers() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }

        root.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
        root.cornerRadius = bounds.height / 2
        root.cornerCurve = .continuous
        root.masksToBounds = true

        let barWidth: CGFloat = 2.5
        let barHeight: CGFloat = 21
        let spacing: CGFloat = 2.25
        let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
        barsContainer.frame = CGRect(
            x: (bounds.width - totalWidth) / 2,
            y: (bounds.height - barHeight) / 2,
            width: totalWidth,
            height: barHeight
        )
        root.addSublayer(barsContainer)

        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
            bar.position = CGPoint(
                x: barWidth / 2 + CGFloat(index) * (barWidth + spacing),
                y: barHeight / 2
            )
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
            bar.cornerRadius = barWidth / 2
            barsContainer.addSublayer(bar)
        }

        let spinnerFrame = CGRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        spinner.frame = spinnerFrame
        spinner.path = CGPath(
            ellipseIn: CGRect(x: 1, y: 1, width: 16, height: 16),
            transform: nil
        )
        spinner.fillColor = nil
        spinner.strokeColor = NSColor.white.cgColor
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinner.strokeStart = 0.16
        root.addSublayer(spinner)

        errorMark.frame = CGRect(x: bounds.midX - 10, y: bounds.midY - 11, width: 20, height: 22)
        errorMark.string = "!"
        errorMark.alignmentMode = .center
        errorMark.font = NSFont.systemFont(ofSize: 17, weight: .bold)
        errorMark.fontSize = 17
        errorMark.foregroundColor = NSColor.systemYellow.cgColor
        errorMark.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        root.addSublayer(errorMark)

        update(level: 0)
        setState(.hidden)
    }

    private func startSpinner() {
        guard spinner.animation(forKey: "spin") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = 0.72
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        spinner.add(animation, forKey: "spin")
    }
}
