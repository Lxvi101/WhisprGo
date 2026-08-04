#!/usr/bin/env swift

import AppKit

private let scriptURL = URL(fileURLWithPath: #filePath)
private let projectURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
private let sourceURL = projectURL.appendingPathComponent("Assets/WhisprGo.svg")
private let packagingURL = projectURL.appendingPathComponent("Packaging", isDirectory: true)

guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("Could not load \(sourceURL.path)")
}

private let waveformSource = NSRect(
    x: 0,
    y: source.size.height - 520,
    width: source.size.width,
    height: 520
)

private func bitmap(width: Int, height: Int, draw: () -> Void) -> NSBitmapImageRep {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create a \(width)x\(height) bitmap")
    }

    representation.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
        fatalError("Could not create a graphics context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return representation
}

private func writePNG(_ representation: NSBitmapImageRep, named name: String) {
    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(name)")
    }
    try! data.write(to: packagingURL.appendingPathComponent(name), options: .atomic)
}

let appIcon = bitmap(width: 1024, height: 1024) {
    NSColor.white.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928),
        xRadius: 216,
        yRadius: 216
    ).fill()
    source.draw(
        in: NSRect(x: 92, y: 280, width: 840, height: 460),
        from: waveformSource,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
}
writePNG(appIcon, named: "AppIcon-1024.png")

let waveform = bitmap(width: 950, height: 520) {
    source.draw(
        in: NSRect(x: 0, y: 0, width: 950, height: 520),
        from: waveformSource,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
}
writePNG(waveform, named: "WaveformMark.png")

let menuIcon = bitmap(width: 128, height: 64) {
    source.draw(
        in: NSRect(x: 2, y: 1, width: 124, height: 62),
        from: waveformSource,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
}
writePNG(menuIcon, named: "MenuBarIconTemplate.png")

print("Rendered brand assets from \(sourceURL.lastPathComponent)")
