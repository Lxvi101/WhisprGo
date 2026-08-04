import AppKit
import QuartzCore

/// A one-shot launch mark built from short-lived Core Animation layers. The
/// active curve is sampled once at launch and then runs entirely on the
/// compositor; no display link or per-frame Swift work remains alive.
@MainActor
final class StartupAnimationController {
    static let shared = StartupAnimationController()

    private let motion = StartupMotionPreset.production
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    func show() {
        dismissWorkItem?.cancel()

        let workspace = NSWorkspace.shared
        let reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        let content = StartupLogoView(
            frame: NSRect(x: 0, y: 0, width: 306, height: 244),
            motion: motion,
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

        let visibleDuration = reduceMotion ? 0.82 : motion.duration + 0.18
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
    private static let designSize = CGSize(width: 950.16, height: 740.99)
    private static let waveformHeight: CGFloat = 520
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

    private let motion: StartupMotionPreset
    private let reduceTransparency: Bool
    private let dotsContainer = CALayer()
    private let wordmarkLayer = CALayer()
    private let wordmarkMask = CALayer()
    private var dotLayers: [CAShapeLayer] = []
    private var designScale: CGFloat = 1

    init(frame frameRect: NSRect, motion: StartupMotionPreset, reduceTransparency: Bool) {
        self.motion = motion
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
        root.removeAllAnimations()
        wordmarkLayer.removeAllAnimations()
        dotLayers.forEach { $0.removeAllAnimations() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = 1
        root.transform = CATransform3DIdentity
        wordmarkLayer.opacity = 1
        wordmarkLayer.transform = CATransform3DIdentity
        dotLayers.forEach {
            $0.opacity = 1
            $0.transform = CATransform3DIdentity
        }
        CATransaction.commit()

        let startTime = CACurrentMediaTime() + 0.02
        animateMaterialAppearance(root, beginTime: startTime, reduceMotion: reduceMotion)
        guard !reduceMotion else { return }
        animateDots(beginTime: startTime)
        animateWordmark(beginTime: startTime + motion.wordmarkDelay)
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
        root.borderWidth = 1
        root.masksToBounds = true
        updateAdaptiveColors()
    }

    private func configureLayers() {
        guard let root = layer else { return }
        let scale = Self.logoWidth / Self.designSize.width
        designScale = scale
        let logoHeight = Self.designSize.height * scale
        let logoOrigin = CGPoint(
            x: bounds.midX - Self.logoWidth / 2,
            y: bounds.midY - logoHeight / 2
        )
        let waveformOrigin = CGPoint(
            x: logoOrigin.x,
            y: logoOrigin.y + (Self.designSize.height - Self.waveformHeight) * scale
        )
        let backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        dotsContainer.frame = bounds
        dotsContainer.contentsScale = backingScale
        root.addSublayer(dotsContainer)

        dotLayers = StartupDotGeometry.dots.map { dot in
            let sourcePath = dot.path
            let sourceBounds = sourcePath.boundingBoxOfPath
            let dotLayer = CAShapeLayer()
            dotLayer.frame = CGRect(
                x: waveformOrigin.x + sourceBounds.minX * scale,
                y: waveformOrigin.y + (Self.waveformHeight - sourceBounds.maxY) * scale,
                width: sourceBounds.width * scale,
                height: sourceBounds.height * scale
            )
            var pathTransform = CGAffineTransform(
                a: scale,
                b: 0,
                c: 0,
                d: -scale,
                tx: -sourceBounds.minX * scale,
                ty: sourceBounds.maxY * scale
            )
            dotLayer.path = sourcePath.copy(using: &pathTransform)
            dotLayer.contentsScale = backingScale
            dotLayer.allowsEdgeAntialiasing = true
            dotsContainer.addSublayer(dotLayer)
            return dotLayer
        }

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
        root.borderColor = NSColor.separatorColor.withAlphaComponent(
            reduceTransparency ? 0.42 : 0.26
        ).cgColor

        let markColor = NSColor.labelColor.cgColor
        dotLayers.forEach { $0.fillColor = markColor }
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

    private func animateDots(beginTime: CFTimeInterval) {
        for (index, pair) in zip(StartupDotGeometry.dots.indices, zip(StartupDotGeometry.dots, dotLayers)) {
            let (dot, dotLayer) = pair
            let samples = motion.samples(for: dot, index: index)
            let keyTimes = samples.map { NSNumber(value: $0.offset) }

            let transform = CAKeyframeAnimation(keyPath: "transform")
            transform.values = samples.map { sample in
                var value = CATransform3DMakeScale(
                    CGFloat(sample.scale),
                    CGFloat(sample.scale),
                    1
                )
                value.m41 = CGFloat(sample.translateX) * designScale
                value.m42 = -CGFloat(sample.translateY) * designScale
                return NSValue(caTransform3D: value)
            }
            transform.keyTimes = keyTimes
            transform.calculationMode = .linear
            transform.beginTime = beginTime + motion.delay(for: dot)
            transform.duration = motion.duration
            transform.fillMode = .backwards
            dotLayer.add(transform, forKey: "motion")

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = samples.map { NSNumber(value: $0.opacity) }
            opacity.keyTimes = keyTimes
            opacity.calculationMode = .linear
            opacity.beginTime = transform.beginTime
            opacity.duration = transform.duration
            opacity.fillMode = .backwards
            dotLayer.add(opacity, forKey: "reveal")
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

struct StartupMotionSample: Equatable {
    let offset: Double
    let opacity: Double
    let translateX: Double
    let translateY: Double
    let scale: Double
}

/// Presets 01, 03, and 07 remain available without allocating anything at
/// launch. Preset 06 is the production choice.
enum StartupMotionPreset: CaseIterable {
    case quietGather
    case centerBloom
    case lineWave
    case bloomWave

    static let production: Self = .lineWave

    var duration: CFTimeInterval {
        switch self {
        case .quietGather: 0.68
        case .centerBloom: 0.72
        case .lineWave, .bloomWave: 2.85
        }
    }

    var wordmarkDelay: CFTimeInterval {
        switch self {
        case .quietGather: 0.58
        case .centerBloom: 0.6
        case .lineWave: 1.56
        case .bloomWave: 1.48
        }
    }

    func delay(for dot: StartupDotGeometry.Dot) -> CFTimeInterval {
        switch self {
        case .quietGather:
            0.032 + dot.radialDistance * 0.23
        case .centerBloom:
            0.02 + (1 - dot.radialDistance) * 0.15
        case .lineWave, .bloomWave:
            0.02
        }
    }

    func samples(for dot: StartupDotGeometry.Dot, index: Int) -> [StartupMotionSample] {
        switch self {
        case .quietGather:
            quietGatherSamples(for: dot, index: index)
        case .centerBloom:
            centerBloomSamples(for: dot)
        case .lineWave:
            lineWaveSamples(for: dot)
        case .bloomWave:
            bloomWaveSamples(for: dot)
        }
    }

    private func quietGatherSamples(
        for dot: StartupDotGeometry.Dot,
        index: Int
    ) -> [StartupMotionSample] {
        let pull = 0.27
        let curl = index.isMultiple(of: 2) ? 0.055 : -0.055
        let deltaX = Self.centerX - dot.centerX
        let deltaY = Self.centerY - dot.centerY
        return [
            StartupMotionSample(
                offset: 0,
                opacity: 0,
                translateX: deltaX * pull + deltaY * curl,
                translateY: deltaY * pull - deltaX * curl,
                scale: 0.28
            ),
            .resting,
        ]
    }

    private func centerBloomSamples(for dot: StartupDotGeometry.Dot) -> [StartupMotionSample] {
        [
            StartupMotionSample(
                offset: 0,
                opacity: 0,
                translateX: Self.centerX - dot.centerX,
                translateY: Self.centerY - dot.centerY,
                scale: 0.08
            ),
            .resting,
        ]
    }

    private func lineWaveSamples(for dot: StartupDotGeometry.Dot) -> [StartupMotionSample] {
        let durationSeconds = 2.85
        let sampleCount = 86
        let buildDelay = 0.08 + dot.xRatio * 1.12
        let collapsedY = Self.centerY - dot.centerY

        return (0..<sampleCount).map { index in
            let offset = Double(index) / Double(sampleCount - 1)
            let time = offset * durationSeconds
            let build = Self.smootherstep((time - buildDelay) / 0.48)
            let waveGate = Self.smootherstep((time - buildDelay) / 0.2)
            let endTaper = 1 - Self.smootherstep((time - 2.08) / 0.72)
            let phase = Double.pi * 2 * (time / 0.82 - dot.xRatio * 0.92)
            let waveY = 48 * sin(phase) * waveGate * endTaper
            return StartupMotionSample(
                offset: offset,
                opacity: Self.smootherstep((time - buildDelay) / 0.24),
                translateX: 0,
                translateY: collapsedY * (1 - build) + waveY,
                scale: 0.1 + 0.9 * build
            )
        }
    }

    private func bloomWaveSamples(for dot: StartupDotGeometry.Dot) -> [StartupMotionSample] {
        let durationSeconds = 2.85
        let sampleCount = 86
        let radialDelay = dot.radialDistance * 0.12
        let collapsedX = Self.centerX - dot.centerX
        let collapsedY = Self.centerY - dot.centerY
        let spatialMode = sin(((dot.centerX - 9.68) / 930.59) * Double.pi * 3)

        return (0..<sampleCount).map { index in
            let offset = Double(index) / Double(sampleCount - 1)
            let time = offset * durationSeconds
            let bloom = Self.smootherstep((time - radialDelay) / 1.24)
            let waveGate = Self.smootherstep((time - radialDelay) / 0.22)
            let endTaper = 1 - Self.smootherstep((time - 2.02) / 0.78)
            let oscillator = exp(-0.5 * time) * sin((Double.pi * 2 * time) / 0.94)
            let waveY = 70 * spatialMode * waveGate * endTaper * oscillator * sqrt(bloom)
            let reveal = Self.smootherstep((time - radialDelay * 0.3) / 0.34)
            return StartupMotionSample(
                offset: offset,
                opacity: reveal * (0.16 + 0.84 * bloom),
                translateX: collapsedX * (1 - bloom),
                translateY: collapsedY * (1 - bloom) + waveY,
                scale: 0.06 + 0.94 * bloom
            )
        }
    }

    private static let centerX = 475.08
    private static let centerY = 241.0

    private static func smootherstep(_ value: Double) -> Double {
        let time = max(0, min(1, value))
        return time * time * time * (time * (time * 6 - 15) + 10)
    }
}

private extension StartupMotionSample {
    static let resting = StartupMotionSample(
        offset: 1,
        opacity: 1,
        translateX: 0,
        translateY: 0,
        scale: 1
    )
}

enum StartupDotGeometry {
    enum Dot {
        case ellipse(CGFloat, CGFloat, CGFloat, CGFloat)
        case lowerCenterIrregular
        case leftIrregular

        var path: CGPath {
            switch self {
            case let .ellipse(x, y, radiusX, radiusY):
                CGPath(ellipseIn: CGRect(
                    x: x - radiusX,
                    y: y - radiusY,
                    width: radiusX * 2,
                    height: radiusY * 2
                ), transform: nil)
            case .lowerCenterIrregular:
                Self.makeLowerCenterPath()
            case .leftIrregular:
                Self.makeLeftPath()
            }
        }

        var centerX: Double { Double(path.boundingBoxOfPath.midX) }
        var centerY: Double { Double(path.boundingBoxOfPath.midY) }
        var xRatio: Double { max(0, min(1, centerX / 950.16)) }
        var radialDistance: Double {
            let distance = hypot(centerX - 475.08, centerY - 241)
            return max(0, min(1, distance / 500))
        }

        private static func makeLowerCenterPath() -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 305.55, y: 347.51))
            path.addCurve(
                to: CGPoint(x: 326.10, y: 354.96),
                control1: CGPoint(x: 313.94, y: 344.07),
                control2: CGPoint(x: 323.33, y: 347.86)
            )
            path.addCurve(
                to: CGPoint(x: 317.98, y: 375.49),
                control1: CGPoint(x: 329.15, y: 362.79),
                control2: CGPoint(x: 326.00, y: 372.50)
            )
            path.addCurve(
                to: CGPoint(x: 298.18, y: 369.06),
                control1: CGPoint(x: 311.04, y: 378.08),
                control2: CGPoint(x: 301.76, y: 375.69)
            )
            path.addCurve(
                to: CGPoint(x: 305.55, y: 347.50),
                control1: CGPoint(x: 294.15, y: 361.58),
                control2: CGPoint(x: 296.17, y: 351.34)
            )
            path.closeSubpath()
            return path
        }

        private static func makeLeftPath() -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 112.51, y: 335.85))
            path.addCurve(
                to: CGPoint(x: 103.66, y: 323.12),
                control1: CGPoint(x: 107.73, y: 334.35),
                control2: CGPoint(x: 103.52, y: 327.46)
            )
            path.addCurve(
                to: CGPoint(x: 113.07, y: 308.52),
                control1: CGPoint(x: 103.85, y: 317.02),
                control2: CGPoint(x: 106.85, y: 310.68)
            )
            path.addCurve(
                to: CGPoint(x: 129.03, y: 313.48),
                control1: CGPoint(x: 118.86, y: 306.51),
                control2: CGPoint(x: 126.28, y: 308.86)
            )
            path.addCurve(
                to: CGPoint(x: 129.89, y: 329.73),
                control1: CGPoint(x: 131.78, y: 318.10),
                control2: CGPoint(x: 132.40, y: 325.44)
            )
            path.addCurve(
                to: CGPoint(x: 112.52, y: 335.85),
                control1: CGPoint(x: 126.71, y: 335.17),
                control2: CGPoint(x: 119.53, y: 338.05)
            )
            path.closeSubpath()
            return path
        }
    }

    static let dots: [Dot] = [
        .ellipse(441.91, 182.92, 18.07, 18.05),
        .ellipse(441.99, 239.62, 17.97, 17.95),
        .ellipse(508.02, 241.58, 17.89, 17.87),
        .ellipse(312.25, 303.29, 17.77, 17.75),
        .ellipse(573.83, 300.89, 17.71, 17.69),
        .ellipse(507.89, 298.68, 17.66, 17.64),
        .ellipse(641.20, 359.52, 17.56, 17.54),
        .ellipse(377.19, 243.81, 17.58, 17.56),
        .ellipse(641.12, 305.49, 17.37, 17.35),
        .ellipse(247.23, 305.28, 17.33, 17.31),
        .ellipse(376.87, 185.77, 17.33, 17.31),
        .ellipse(508.35, 185.09, 17.33, 17.31),
        .ellipse(573.86, 356.63, 17.23, 17.22),
        .ellipse(181.53, 305.62, 17.21, 17.19),
        .ellipse(442.16, 125.80, 16.71, 16.69),
        .ellipse(708.70, 316.69, 16.44, 16.43),
        .ellipse(708.43, 260.81, 16.13, 16.11),
        .ellipse(312.33, 246.54, 16.10, 16.08),
        .ellipse(181.31, 245.48, 15.85, 15.83),
        .lowerCenterIrregular,
        .ellipse(573.90, 245.12, 15.12, 15.10),
        .ellipse(771.13, 234.20, 14.89, 14.87),
        .ellipse(247.42, 246.58, 14.81, 14.79),
        .ellipse(831.88, 271.78, 14.74, 14.73),
        .ellipse(508.77, 128.33, 14.61, 14.60),
        .ellipse(641.40, 413.91, 14.43, 14.42),
        .ellipse(441.84, 67.85, 14.25, 14.23),
        .leftIrregular,
        .ellipse(181.00, 365.82, 14.17, 14.15),
        .ellipse(770.95, 300.49, 14.14, 14.12),
        .ellipse(508.25, 355.09, 14.01, 13.99),
        .ellipse(376.59, 129.38, 14.08, 14.07),
        .ellipse(247.09, 360.65, 13.84, 13.82),
        .ellipse(887.93, 301.25, 13.68, 13.66),
        .ellipse(63.54, 279.26, 13.57, 13.56),
        .ellipse(574.14, 413.34, 13.63, 13.61),
        .ellipse(831.93, 331.30, 13.23, 13.21),
        .ellipse(181.10, 180.49, 13.00, 12.98),
        .ellipse(708.08, 362.67, 12.58, 12.56),
        .ellipse(117.39, 275.80, 12.54, 12.53),
        .ellipse(116.87, 230.67, 12.41, 12.40),
        .ellipse(708.46, 186.50, 11.79, 11.78),
        .ellipse(247.28, 420.05, 11.80, 11.79),
        .ellipse(376.86, 299.12, 11.18, 11.17),
        .ellipse(574.55, 186.65, 11.20, 11.19),
        .ellipse(641.21, 471.51, 10.93, 10.92),
        .ellipse(573.98, 471.48, 10.88, 10.87),
        .ellipse(641.06, 245.36, 10.85, 10.84),
        .ellipse(441.94, 10.78, 10.79, 10.78),
        .ellipse(376.31, 70.57, 10.59, 10.58),
        .ellipse(508.56, 413.69, 10.48, 10.47),
        .ellipse(508.57, 70.05, 10.47, 10.46),
        .ellipse(312.44, 189.03, 9.85, 9.84),
        .ellipse(940.27, 299.86, 9.89, 9.88),
        .ellipse(9.68, 297.80, 9.68, 9.66),
    ]
}
