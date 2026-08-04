#!/usr/bin/env swift

import AppKit

private let scriptURL = URL(fileURLWithPath: #filePath)
private let projectURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
private let sourceURL = projectURL.appendingPathComponent("Assets/WhisprGo.svg")
private let appIconURL = projectURL.appendingPathComponent("Packaging/AppIcon-1024.png")
private let applicationsIconURL = URL(
    fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
)
private let packagingURL = projectURL.appendingPathComponent("Packaging", isDirectory: true)

guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("Could not load \(sourceURL.path)")
}

private let canvasSize = NSSize(width: 660, height: 400)
private let waveformSource = NSRect(
    x: 0,
    y: source.size.height - 520,
    width: source.size.width,
    height: 520
)

private func makeRetinaBitmap(draw: () -> Void) -> NSBitmapImageRep {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width * 2),
        pixelsHigh: Int(canvasSize.height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create the DMG bitmap")
    }

    representation.size = canvasSize
    guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
        fatalError("Could not create the DMG graphics context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return representation
}

private func drawBackground() {
    NSColor(calibratedWhite: 0.975, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    // A very quiet full-size echo of the brand mark gives the window depth
    // without competing with the Finder icons placed over it.
    source.draw(
        in: NSRect(x: 40, y: 45, width: 580, height: 318),
        from: waveformSource,
        operation: .sourceOver,
        fraction: 0.028,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )

    source.draw(
        in: NSRect(x: 279, y: 304, width: 102, height: 56),
        from: waveformSource,
        operation: .sourceOver,
        fraction: 0.94,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )

    drawCentered(
        "WhisprGo",
        in: NSRect(x: 0, y: 268, width: canvasSize.width, height: 28),
        font: .systemFont(ofSize: 21, weight: .medium),
        color: NSColor(calibratedWhite: 0.08, alpha: 1),
        kern: -0.35
    )
    drawCentered(
        "Drag to Applications",
        in: NSRect(x: 0, y: 241, width: canvasSize.width, height: 18),
        font: .systemFont(ofSize: 12, weight: .regular),
        color: NSColor(calibratedWhite: 0.36, alpha: 1),
        kern: 0.1
    )

    drawDottedTransferPath()
}

private func drawDottedTransferPath() {
    let y: CGFloat = 166
    let dots: [(x: CGFloat, radius: CGFloat, alpha: CGFloat)] = [
        (234, 1.45, 0.22), (247, 1.65, 0.28), (260, 1.9, 0.34),
        (273, 2.15, 0.42), (286, 2.45, 0.52), (299, 2.7, 0.62),
        (312, 2.9, 0.72), (325, 3.1, 0.84), (338, 3.1, 0.92),
        (351, 2.9, 0.82), (364, 2.65, 0.72), (377, 2.35, 0.62),
        (390, 2.05, 0.52), (403, 1.8, 0.42), (416, 1.55, 0.32),
    ]

    for dot in dots {
        NSColor(calibratedWhite: 0.08, alpha: dot.alpha).setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: dot.x - dot.radius,
                y: y - dot.radius,
                width: dot.radius * 2,
                height: dot.radius * 2
            )
        ).fill()
    }

    // Three dot pairs form a soft forward chevron instead of introducing a
    // foreign arrow glyph into the waveform language.
    let chevron: [(CGFloat, CGFloat, CGFloat)] = [
        (425, y + 8, 1.35), (431, y + 4, 1.55), (437, y, 1.75),
        (431, y - 4, 1.55), (425, y - 8, 1.35),
    ]
    for (x, dotY, radius) in chevron {
        NSColor(calibratedWhite: 0.08, alpha: 0.72).setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: x - radius,
                y: dotY - radius,
                width: radius * 2,
                height: radius * 2
            )
        ).fill()
    }
}

private func drawCentered(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    kern: CGFloat
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    NSAttributedString(
        string: text,
        attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
            .paragraphStyle: paragraph,
        ]
    ).draw(in: rect)
}

private func writePNG(_ representation: NSBitmapImageRep, named name: String) {
    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(name)")
    }
    try! data.write(to: packagingURL.appendingPathComponent(name), options: .atomic)
}

let background = makeRetinaBitmap {
    drawBackground()
}
writePNG(background, named: "DMGBackground.png")

let preview = makeRetinaBitmap {
    drawBackground()

    let appIcon = NSImage(contentsOf: appIconURL)
    let applicationsIcon = NSImage(contentsOf: applicationsIconURL)
    appIcon?.draw(
        in: NSRect(x: 122, y: 111, width: 96, height: 96),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    applicationsIcon?.draw(
        in: NSRect(x: 442, y: 111, width: 96, height: 96),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    drawCentered(
        "WhisprGo",
        in: NSRect(x: 100, y: 86, width: 140, height: 18),
        font: .systemFont(ofSize: 12, weight: .medium),
        color: NSColor(calibratedWhite: 0.12, alpha: 1),
        kern: 0
    )
    drawCentered(
        "Applications",
        in: NSRect(x: 420, y: 86, width: 140, height: 18),
        font: .systemFont(ofSize: 12, weight: .medium),
        color: NSColor(calibratedWhite: 0.12, alpha: 1),
        kern: 0
    )
}
writePNG(preview, named: "DMGBackgroundPreview.png")

print("Rendered DMGBackground.png and DMGBackgroundPreview.png")
