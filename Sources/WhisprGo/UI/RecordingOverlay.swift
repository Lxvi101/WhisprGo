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
    private var hideGeneration = 0

    init(levelMeter: AudioLevelMeter) {
        self.levelMeter = levelMeter
    }

    func show(_ state: State) {
        pendingHide?.cancel()
        hideGeneration &+= 1
        ensurePanel()
        guard let panel, let waveformView else { return }

        let wasVisible = panel.isVisible
        let screen = wasVisible ? currentScreen(of: panel) : position(panel)
        waveformView.setState(state)
        if !wasVisible {
            panel.orderFrontRegardless()
        }
        waveformView.present(fromHidden: !wasVisible)

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
            self?.dismiss()
        }
        pendingHide = work
        if delay <= 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func dismiss() {
        guard let panel, panel.isVisible, let waveformView else { return }
        hideGeneration &+= 1
        let generation = hideGeneration
        let duration = waveformView.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.waveformView?.setState(.hidden)
            self.panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let content = WaveformOverlayView(frame: NSRect(x: 0, y: 0, width: 150, height: 56))
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
        // The surface layer draws its own soft shadow inside the padded panel.
        panel.hasShadow = false
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

    private func currentScreen(of panel: NSPanel) -> NSScreen? {
        panel.screen ?? NSScreen.main
    }

    @discardableResult
    private func position(_ panel: NSPanel) -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 22
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
    private static let surfaceSize = CGSize(width: 104, height: 40)

    private struct MeterDot {
        let layer: CALayer
        let envelope: CGFloat
        let threshold: CGFloat
    }

    /// Everything visible lives on one centered surface so presentation can
    /// scale it around its middle while the panel itself stays still.
    private let surface = CALayer()
    private let dotsContainer = CALayer()
    private var dots: [MeterDot] = []
    private let spinner = CAShapeLayer()
    private let errorMark = CATextLayer()
    private var lastRenderedLevel: Float = -1
    private var state: RecordingOverlay.State = .hidden

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func setState(_ newState: RecordingOverlay.State) {
        let previous = state
        state = newState

        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion || previous == .hidden ? 0 : 0.22)
        dotsContainer.opacity = newState == .recording ? 1 : 0
        spinner.opacity = newState == .transcribing ? 1 : 0
        errorMark.opacity = newState == .error ? 1 : 0
        CATransaction.commit()

        if newState == .transcribing {
            startSpinner()
        } else {
            spinner.removeAnimation(forKey: "spin")
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// A dark pill in dark mode, a white pill in light mode.
    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill = isDark ? NSColor(white: 0.08, alpha: 0.96) : NSColor(white: 1, alpha: 0.97)
        let ink = isDark ? NSColor.white : NSColor.black

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.backgroundColor = fill.cgColor
        surface.borderColor = ink.withAlphaComponent(isDark ? 0.1 : 0.08).cgColor
        surface.shadowOpacity = isDark ? 0.45 : 0.18
        for dot in dots {
            dot.layer.backgroundColor = ink.withAlphaComponent(0.92).cgColor
        }
        spinner.strokeColor = ink.cgColor
        errorMark.foregroundColor = ink.cgColor
        CATransaction.commit()
    }

    /// Springs the surface in from wherever it currently is on screen, so a
    /// show that interrupts a dismissal reverses smoothly instead of popping.
    func present(fromHidden: Bool) {
        let fromScale = fromHidden ? 0.82 : currentScale()
        let fromOpacity = fromHidden ? 0 : currentOpacity()
        surface.removeAnimation(forKey: "dismiss")
        surface.removeAnimation(forKey: "dismissOpacity")
        setModel(scale: 1, opacity: 1)
        guard !reduceMotion else {
            fade(from: fromOpacity, to: 1, duration: 0.16, key: "presentOpacity")
            return
        }

        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = fromScale
        spring.toValue = 1
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 26
        spring.duration = spring.settlingDuration
        surface.add(spring, forKey: "present")
        fade(from: fromOpacity, to: 1, duration: 0.14, key: "presentOpacity")
    }

    /// Returns the time the dismissal needs before the panel can be ordered out.
    func dismiss() -> TimeInterval {
        let fromScale = currentScale()
        let fromOpacity = currentOpacity()
        let duration: TimeInterval = reduceMotion ? 0.14 : 0.2
        surface.removeAnimation(forKey: "present")
        surface.removeAnimation(forKey: "presentOpacity")
        setModel(scale: reduceMotion ? 1 : 0.9, opacity: 0)
        if !reduceMotion {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = fromScale
            scale.toValue = 0.9
            scale.duration = duration
            scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
            surface.add(scale, forKey: "dismiss")
        }
        fade(from: fromOpacity, to: 0, duration: duration, key: "dismissOpacity")
        return duration
    }

    func update(level: Float) {
        guard abs(level - lastRenderedLevel) > 0.002 else { return }
        lastRenderedLevel = level
        let amplitude = CGFloat(max(0.06, min(1, level)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots {
            let energy = amplitude * dot.envelope
            let visibility = max(0.1, min(1, (energy * 3.2 - dot.threshold) * 1.55))
            dot.layer.opacity = Float(visibility)
            let scale = 0.76 + visibility * 0.24
            dot.layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
        CATransaction.commit()
    }

    private func setModel(scale: CGFloat, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.transform = CATransform3DMakeScale(scale, scale, 1)
        surface.opacity = opacity
        CATransaction.commit()
    }

    private func currentScale() -> CGFloat {
        let layer = surface.presentation() ?? surface
        return (layer.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
    }

    private func currentOpacity() -> Float {
        (surface.presentation() ?? surface).opacity
    }

    private func fade(from: Float, to: Float, duration: TimeInterval, key: String) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: to > from ? .easeOut : .easeIn)
        surface.add(fade, forKey: key)
    }

    private func configureLayers() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.backgroundColor = NSColor.clear.cgColor
        root.masksToBounds = false

        let size = Self.surfaceSize
        surface.bounds = CGRect(origin: .zero, size: size)
        surface.position = CGPoint(x: bounds.midX, y: bounds.midY)
        surface.cornerRadius = size.height / 2
        surface.cornerCurve = .continuous
        surface.borderWidth = 1
        surface.shadowColor = NSColor.black.cgColor
        surface.shadowRadius = 9
        surface.shadowOffset = CGSize(width: 0, height: 3)
        surface.shadowPath = CGPath(
            roundedRect: surface.bounds,
            cornerWidth: size.height / 2,
            cornerHeight: size.height / 2,
            transform: nil
        )
        root.addSublayer(surface)

        let columnSpacing: CGFloat = 5.8
        let rowSpacing: CGFloat = 4.9
        let totalWidth = CGFloat(Self.envelope.count - 1) * columnSpacing
        let meterCenterX = size.width / 2
        dotsContainer.frame = surface.bounds
        surface.addSublayer(dotsContainer)

        for (columnIndex, envelope) in Self.envelope.enumerated() {
            for row in -2...2 {
                let rowDistance = CGFloat(abs(row))
                let diameter = max(2.1, 2.55 + envelope * 0.65 - rowDistance * 0.12)
                let dotLayer = CALayer()
                dotLayer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                dotLayer.position = CGPoint(
                    x: meterCenterX - totalWidth / 2 + CGFloat(columnIndex) * columnSpacing,
                    y: size.height / 2 + CGFloat(row) * rowSpacing
                )
                dotLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                dotLayer.cornerRadius = diameter / 2
                dotsContainer.addSublayer(dotLayer)
                dots.append(MeterDot(
                    layer: dotLayer,
                    envelope: envelope,
                    threshold: rowDistance * 0.36
                ))
            }
        }

        spinner.frame = CGRect(x: meterCenterX - 9, y: size.height / 2 - 9, width: 18, height: 18)
        spinner.path = CGPath(
            ellipseIn: CGRect(x: 1, y: 1, width: 16, height: 16),
            transform: nil
        )
        spinner.fillColor = nil
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinner.strokeStart = 0.3
        surface.addSublayer(spinner)

        errorMark.frame = CGRect(x: meterCenterX - 10, y: size.height / 2 - 11, width: 20, height: 22)
        errorMark.string = "!"
        errorMark.alignmentMode = .center
        errorMark.font = NSFont.systemFont(ofSize: 17, weight: .bold)
        errorMark.fontSize = 17
        errorMark.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        surface.addSublayer(errorMark)

        applyColors()
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
