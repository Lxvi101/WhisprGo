import AppKit
import QuartzCore

/// A one-shot launch mark built from short-lived Core Animation layers. The
/// active curve is sampled once at launch and then runs entirely on the
/// compositor; no display link or per-frame Swift work remains alive.
@MainActor
final class StartupAnimationController {
    static let shared = StartupAnimationController()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    func show() {
        dismissWorkItem?.cancel()

        let workspace = NSWorkspace.shared
        let reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        let content = StartupLogoView(
            frame: NSRect(x: 0, y: 0, width: 306, height: 244),
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
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
        // A borderless transparent panel receives a rectangular WindowServer
        // shadow. The material supplies its own depth; keeping this off avoids
        // a square white plane behind the rounded surface.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
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
        content.beginAnimation(reduceMotion: reduceMotion)
        panel.orderFrontRegardless()

        let visibleDuration = reduceMotion ? 0.82 : StartupMarkMotion.duration + 0.18
        let dismiss = DispatchWorkItem { [weak self, weak content] in
            guard let self else { return }
            content?.finishAnimation(reduceMotion: reduceMotion)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                self?.panel?.orderOut(nil)
                self?.panel = nil
            }
        }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: dismiss)
    }
}

@MainActor
private final class StartupLogoView: NSVisualEffectView {
    private static let designSize = StartupMarkGeometry.designSize
    private static let wordmarkHeight: CGFloat = 171.61
    private static let logoWidth: CGFloat = 270
    private static let materialMask = NSImage(
        size: NSSize(width: 306, height: 244),
        flipped: false
    ) { bounds in
        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: 28,
            yRadius: 28
        ).fill()
        return true
    }

    private static let wordmarkImage: CGImage? = {
        guard let source = BrandAssets.loadFullLogo() else { return nil }
        let logicalSize = NSSize(
            width: logoWidth,
            height: wordmarkHeight * logoWidth / designSize.width
        )
        let pixelSize = NSSize(
            width: (logicalSize.width * 2).rounded(.up),
            height: (logicalSize.height * 2).rounded(.up)
        )
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        bitmap.size = pixelSize

        // Drawing the whole lockup anchored at the bottom leaves only the
        // wordmark inside this bitmap; the mark above it is built from layers.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(
                x: 0,
                y: 0,
                width: pixelSize.width,
                height: designSize.height * pixelSize.width / designSize.width
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }()

    private let reduceTransparency: Bool
    private let markContainer = CALayer()
    private let voiceLayer = CAShapeLayer()
    private let caretLayer = CAShapeLayer()
    private var dropletLayers: [CAShapeLayer] = []
    private let wordmarkLayer = CALayer()
    private let wordmarkMask = CALayer()
    private var designScale: CGFloat = 1
    private var logoOrigin: CGPoint = .zero

    init(frame frameRect: NSRect, reduceTransparency: Bool) {
        self.reduceTransparency = reduceTransparency
        super.init(frame: frameRect)
        configureMaterial()
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginAnimation(reduceMotion: Bool) {
        guard let root = layer else { return }
        let markLayers: [CALayer] = [voiceLayer, caretLayer]
        ([root, wordmarkLayer] + markLayers + dropletLayers).forEach { $0.removeAllAnimations() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = 1
        root.transform = CATransform3DIdentity
        wordmarkLayer.opacity = 1
        wordmarkLayer.transform = CATransform3DIdentity
        markLayers.forEach {
            $0.opacity = 1
            $0.transform = CATransform3DIdentity
        }
        // Droplets only exist in flight; at rest they have been absorbed.
        dropletLayers.forEach { $0.opacity = 0 }
        CATransaction.commit()

        let startTime = CACurrentMediaTime() + 0.02
        animateMaterialAppearance(root, beginTime: startTime, reduceMotion: reduceMotion)
        guard !reduceMotion else { return }
        animateMark(beginTime: startTime)
        animateWordmark(beginTime: startTime + StartupMarkMotion.wordmarkDelay)
    }

    func finishAnimation(reduceMotion: Bool) {
        guard let root = layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = root.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = reduceMotion ? 0.16 : 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        root.add(fade, forKey: "dismiss")

        guard !reduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.985
        scale.duration = 0.2
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        root.add(scale, forKey: "dismissScale")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAdaptiveColors()
    }

    private func configureMaterial() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        isEmphasized = true
        maskImage = Self.materialMask
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        guard let root = layer else { return }
        root.cornerRadius = 28
        root.cornerCurve = .continuous
        root.borderWidth = 0
        root.masksToBounds = true
        updateAdaptiveColors()
    }

    /// Converts a point in the lockup's design space (y down) to view space.
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: logoOrigin.x + point.x * designScale,
            y: logoOrigin.y + (Self.designSize.height - point.y) * designScale
        )
    }

    private func configureLayers() {
        guard let root = layer else { return }
        let scale = Self.logoWidth / Self.designSize.width
        designScale = scale
        let logoHeight = Self.designSize.height * scale
        logoOrigin = CGPoint(
            x: bounds.midX - Self.logoWidth / 2,
            y: bounds.midY - logoHeight / 2
        )
        let backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        markContainer.frame = bounds
        markContainer.contentsScale = backingScale
        root.addSublayer(markContainer)

        // Droplets sit beneath the voice and the caret, so they bud out from
        // behind one and slip into the other.
        let dropletDiameter = StartupMarkGeometry.dropletRadius * 2 * scale
        dropletLayers = StartupMarkMotion.droplets.map { _ in
            let droplet = CAShapeLayer()
            droplet.bounds = CGRect(x: 0, y: 0, width: dropletDiameter, height: dropletDiameter)
            droplet.position = viewPoint(StartupMarkGeometry.voiceCenter)
            droplet.path = CGPath(ellipseIn: droplet.bounds, transform: nil)
            droplet.contentsScale = backingScale
            droplet.opacity = 0
            markContainer.addSublayer(droplet)
            return droplet
        }

        let voiceDiameter = StartupMarkGeometry.voiceRadius * 2 * scale
        voiceLayer.bounds = CGRect(x: 0, y: 0, width: voiceDiameter, height: voiceDiameter)
        voiceLayer.position = viewPoint(StartupMarkGeometry.voiceCenter)
        voiceLayer.path = CGPath(ellipseIn: voiceLayer.bounds, transform: nil)
        voiceLayer.contentsScale = backingScale
        markContainer.addSublayer(voiceLayer)

        let caretSize = CGSize(
            width: StartupMarkGeometry.caretSize.width * scale,
            height: StartupMarkGeometry.caretSize.height * scale
        )
        caretLayer.bounds = CGRect(origin: .zero, size: caretSize)
        caretLayer.position = viewPoint(StartupMarkGeometry.caretCenter)
        caretLayer.path = CGPath(
            roundedRect: caretLayer.bounds,
            cornerWidth: caretSize.width / 2,
            cornerHeight: caretSize.width / 2,
            transform: nil
        )
        caretLayer.contentsScale = backingScale
        markContainer.addSublayer(caretLayer)

        wordmarkLayer.frame = CGRect(
            x: logoOrigin.x,
            y: logoOrigin.y,
            width: Self.logoWidth,
            height: Self.wordmarkHeight * scale
        )
        wordmarkLayer.contentsScale = backingScale
        wordmarkMask.frame = wordmarkLayer.bounds
        wordmarkMask.contents = Self.wordmarkImage
        wordmarkMask.contentsGravity = .resizeAspect
        wordmarkMask.contentsScale = backingScale
        wordmarkLayer.mask = wordmarkMask
        root.addSublayer(wordmarkLayer)
        updateAdaptiveColors()
    }

    private func updateAdaptiveColors() {
        guard let root = layer else { return }
        let fill = reduceTransparency
            ? NSColor.windowBackgroundColor
            : NSColor.windowBackgroundColor.withAlphaComponent(0.2)
        root.backgroundColor = fill.cgColor

        let markColor = NSColor.labelColor.cgColor
        ([voiceLayer, caretLayer] + dropletLayers).forEach { $0.fillColor = markColor }
        wordmarkLayer.backgroundColor = markColor
    }

    private func animateMaterialAppearance(
        _ root: CALayer,
        beginTime: CFTimeInterval,
        reduceMotion: Bool
    ) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = beginTime
        fade.duration = reduceMotion ? 0.18 : 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        root.add(fade, forKey: "appear")

        guard !reduceMotion else { return }
        let settle = CASpringAnimation(keyPath: "transform.scale")
        settle.fromValue = 0.97
        settle.toValue = 1
        settle.beginTime = beginTime
        settle.mass = 1
        settle.stiffness = 250
        settle.damping = 30
        settle.initialVelocity = 0
        settle.duration = min(0.4, settle.settlingDuration)
        settle.fillMode = .backwards
        root.add(settle, forKey: "materialize")
    }

    private func animateMark(beginTime: CFTimeInterval) {
        let times = StartupMarkMotion.sampleTimes
        let keyTimes = times.map { NSNumber(value: $0 / StartupMarkMotion.duration) }

        func run(_ layer: CALayer, _ samples: [StartupMarkSample], key: String) {
            let transform = CAKeyframeAnimation(keyPath: "transform")
            transform.values = samples.map { sample in
                var value = CATransform3DMakeScale(CGFloat(sample.scaleX), CGFloat(sample.scaleY), 1)
                value.m41 = CGFloat(sample.translateX) * designScale
                value.m42 = -CGFloat(sample.translateY) * designScale
                return NSValue(caTransform3D: value)
            }
            transform.keyTimes = keyTimes
            transform.calculationMode = .linear
            transform.beginTime = beginTime
            transform.duration = StartupMarkMotion.duration
            transform.fillMode = .backwards
            layer.add(transform, forKey: key + ".motion")

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = samples.map { NSNumber(value: $0.opacity) }
            opacity.keyTimes = keyTimes
            opacity.calculationMode = .linear
            opacity.beginTime = beginTime
            opacity.duration = StartupMarkMotion.duration
            opacity.fillMode = .backwards
            layer.add(opacity, forKey: key + ".opacity")
        }

        run(voiceLayer, times.map(StartupMarkMotion.voice(at:)), key: "voice")

        // The caret grows by animating its path height rather than scaling
        // the layer, so its round caps stay round the whole time.
        let caretSamples = times.map(StartupMarkMotion.caret(at:))
        run(caretLayer, caretSamples.map { sample in
            var unscaled = sample
            unscaled.scaleY = 1
            return unscaled
        }, key: "caret")
        let caretBounds = caretLayer.bounds
        let capRadius = caretBounds.width / 2
        let caretPath = CAKeyframeAnimation(keyPath: "path")
        caretPath.values = caretSamples.map { sample in
            let height = max(caretBounds.width, caretBounds.height * CGFloat(sample.scaleY))
            let rect = CGRect(
                x: 0,
                y: caretBounds.midY - height / 2,
                width: caretBounds.width,
                height: height
            )
            return CGPath(roundedRect: rect, cornerWidth: capRadius, cornerHeight: capRadius, transform: nil)
        }
        caretPath.keyTimes = keyTimes
        caretPath.calculationMode = .linear
        caretPath.beginTime = beginTime
        caretPath.duration = StartupMarkMotion.duration
        caretPath.fillMode = .backwards
        caretLayer.add(caretPath, forKey: "caret.path")

        for (index, droplet) in dropletLayers.enumerated() {
            run(droplet, times.map { StartupMarkMotion.droplet(index, at: $0) }, key: "droplet")
        }
    }

    private func animateWordmark(beginTime: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = beginTime
        fade.duration = 0.43
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        wordmarkLayer.add(fade, forKey: "appear")

        var startTransform = CATransform3DIdentity
        startTransform.m42 = -18 * designScale
        let rise = CABasicAnimation(keyPath: "transform")
        rise.fromValue = NSValue(caTransform3D: startTransform)
        rise.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        rise.beginTime = beginTime
        rise.duration = 0.43
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rise.fillMode = .backwards
        wordmarkLayer.add(rise, forKey: "rise")
    }
}

/// The Speak → Type mark in the design space of Assets/WhisprGo.svg (y down).
enum StartupMarkGeometry {
    static let designSize = CGSize(width: 950.16, height: 597.07)
    static let voiceCenter = CGPoint(x: 384.25, y: 159)
    static let voiceRadius: CGFloat = 126
    static let caretCenter = CGPoint(x: 666.25, y: 159)
    static let caretSize = CGSize(width: 45, height: 318)
    static let dropletRadius: CGFloat = 30
}

/// One frame of a layer's motion, relative to its resting layout. Translations
/// are in design units (y down).
struct StartupMarkSample: Equatable {
    var opacity: Double
    var translateX: Double
    var translateY: Double
    var scaleX: Double
    var scaleY: Double

    static let resting = StartupMarkSample(opacity: 1, translateX: 0, translateY: 0, scaleX: 1, scaleY: 1)
}

/// The launch sequence: the voice blooms, the caret grows, three words bud off
/// the voice and fly into the caret (which kicks forward as each lands and then
/// blinks once), and the wordmark rises in underneath.
enum StartupMarkMotion {
    struct Droplet {
        let launch: Double
        let targetOffsetY: Double
        let arc: Double
    }

    static let duration: CFTimeInterval = 2.0
    static let wordmarkDelay: CFTimeInterval = 0.95
    static let flight = 0.46
    static let droplets = [
        Droplet(launch: 0.5, targetOffsetY: -62, arc: -70),
        Droplet(launch: 0.62, targetOffsetY: 48, arc: 60),
        Droplet(launch: 0.74, targetOffsetY: -8, arc: -40),
    ]

    /// 60 samples per second across the whole sequence.
    static let sampleTimes: [Double] = {
        let count = Int(duration * 60) + 1
        return (0..<count).map { Double($0) / Double(count - 1) * duration }
    }()

    static func voice(at time: Double) -> StartupMarkSample {
        guard time < duration else { return .resting }
        let bloom = 0.18 + 0.82 * spring(time, response: 0.5, damping: 0.7)
        // The voice gives a little of itself as the words leave it.
        let give = 1 - 0.07 * sin(.pi * clamp((time - 0.48) / 0.6))
        let scale = bloom * give
        return StartupMarkSample(
            opacity: smootherstep(time / 0.16),
            translateX: 0,
            translateY: 0,
            scaleX: scale,
            scaleY: scale
        )
    }

    static func caret(at time: Double) -> StartupMarkSample {
        guard time < duration else { return .resting }
        let start = 0.22
        let grow = 0.04 + 0.96 * spring(time - start, response: 0.42, damping: 0.8)
        let kick = droplets.reduce(0) { total, droplet in
            let since = time - (droplet.launch + flight)
            guard since > 0 else { return total }
            return total + 9 * (since / 0.06) * exp(1 - since / 0.06)
        }
        let blinkOff = smootherstep((time - 1.42) / 0.04) * (1 - smootherstep((time - 1.72) / 0.04))
        return StartupMarkSample(
            opacity: smootherstep((time - start) / 0.08) * (1 - blinkOff),
            translateX: kick,
            translateY: 0,
            scaleX: 1,
            scaleY: grow
        )
    }

    static func droplet(_ index: Int, at time: Double) -> StartupMarkSample {
        let droplet = droplets[index]
        let progress = (time - droplet.launch) / flight
        guard progress > 0, progress < 1 else {
            return StartupMarkSample(opacity: 0, translateX: 0, translateY: 0, scaleX: 0.5, scaleY: 0.5)
        }
        let eased = progress * progress * (3 - 2 * progress)
        let start = StartupMarkGeometry.voiceCenter
        let end = CGPoint(
            x: StartupMarkGeometry.caretCenter.x,
            y: StartupMarkGeometry.caretCenter.y + droplet.targetOffsetY
        )
        let control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + droplet.arc)
        let inverse = 1 - eased
        let x = inverse * inverse * start.x + 2 * inverse * eased * control.x + eased * eased * end.x
        let y = inverse * inverse * start.y + 2 * inverse * eased * control.y + eased * eased * end.y
        let scale = (0.5 + 0.5 * smootherstep(progress / 0.2)) * (1 - 0.3 * smootherstep((progress - 0.55) / 0.3))
            * (1 - 0.7 * smootherstep((progress - 0.85) / 0.15))
        return StartupMarkSample(
            opacity: 1 - smootherstep((progress - 0.86) / 0.14),
            translateX: x - start.x,
            translateY: y - start.y,
            scaleX: scale,
            scaleY: scale
        )
    }

    /// Step response of a spring released from rest at `time == 0`.
    static func spring(_ time: Double, response: Double, damping: Double) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        guard damping < 1 else { return 1 - exp(-omega * time) * (1 + omega * time) }
        let root = (1 - damping * damping).squareRoot()
        let damped = omega * root
        return 1 - exp(-damping * omega * time)
            * (cos(damped * time) + damping / root * sin(damped * time))
    }

    private static func clamp(_ value: Double) -> Double { max(0, min(1, value)) }

    private static func smootherstep(_ value: Double) -> Double {
        let time = clamp(value)
        return time * time * time * (time * (time * 6 - 15) + 10)
    }
}
