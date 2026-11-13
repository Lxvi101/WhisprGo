#!/usr/bin/env swift

import AppKit

// Renders every bitmap brand asset from the Speak → Type mark: a voice (the
// circle) and the text caret it types into. The geometry below matches
// Assets/WhisprGoMark.svg and the mark in Assets/WhisprGo.svg.

private let scriptURL = URL(fileURLWithPath: #filePath)
private let projectURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
private let packagingURL = projectURL.appendingPathComponent("Packaging", isDirectory: true)

/// The mark in glyph units: the caret is 1.06 units tall and the whole glyph
/// is centred on the origin. `small` thickens the caret so it survives at 16 px
/// and in the menu bar.
private struct Mark {
    static let voiceCenterX: CGFloat = -0.2975
    static let voiceRadius: CGFloat = 0.42
    static let caretCenterX: CGFloat = 0.6425
    static let caretHalfHeight: CGFloat = 0.53
    static func caretHalfWidth(small: Bool) -> CGFloat { small ? 0.1 : 0.075 }
    static let halfWidth: CGFloat = 0.7175

    static func voiceRect(scale: CGFloat, center: CGPoint) -> NSRect {
        NSRect(
            x: center.x + (voiceCenterX - voiceRadius) * scale,
            y: center.y - voiceRadius * scale,
            width: voiceRadius * 2 * scale,
            height: voiceRadius * 2 * scale
        )
    }

    static func caretPath(scale: CGFloat, center: CGPoint, small: Bool) -> NSBezierPath {
        let halfWidth = caretHalfWidth(small: small) * scale
        let rect = NSRect(
            x: center.x + caretCenterX * scale - halfWidth,
            y: center.y - caretHalfHeight * scale,
            width: halfWidth * 2,
            height: caretHalfHeight * 2 * scale
        )
        return NSBezierPath(roundedRect: rect, xRadius: halfWidth, yRadius: halfWidth)
    }
}

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
    context.shouldAntialias = true
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return representation
}

private func writePNG(_ representation: NSBitmapImageRep, to url: URL) {
    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(url.lastPathComponent)")
    }
    try! data.write(to: url, options: .atomic)
}

/// A continuous-corner tile (superellipse, n = 5), the macOS icon shape.
private func squircle(in rect: NSRect, exponent: CGFloat = 5, steps: Int = 256) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    for index in 0..<steps {
        let t = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = NSPoint(
            x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent),
            y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        )
        index == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

private let bone = NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1)

/// The app icon on Apple's 1024 grid: an 824 pt ink tile with the glossy mark.
private func drawAppIcon(pixels: Int) {
    let unit = CGFloat(pixels) / 1024
    let small = pixels <= 32
    let tileRect = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let tile = squircle(in: tileRect)

    if pixels >= 64 {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
        shadow.shadowBlurRadius = 24 * unit
        shadow.set()
        NSColor.black.setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGradient(
        starting: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.129, alpha: 1),
        ending: NSColor(srgbRed: 0.020, green: 0.020, blue: 0.024, alpha: 1)
    )!.draw(in: tile, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSColor.white.withAlphaComponent(0.08).setStroke()
    tile.lineWidth = max(1, 3 * unit)
    tile.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Small sizes get a slightly larger, flat mark with a thicker caret.
    let scale = (small ? 272 : 248) * unit
    let center = NSPoint(x: 512 * unit, y: 512 * unit)
    let voice = NSBezierPath(ovalIn: Mark.voiceRect(scale: scale, center: center))
    let caret = Mark.caretPath(scale: scale, center: center, small: small)

    if small {
        bone.setFill()
        voice.fill()
        caret.fill()
        return
    }

    // Gloss: the dot's specular highlight sits upper left, as in the app.
    NSGradient(colorsAndLocations:
        (.white, 0),
        (bone, 0.5),
        (NSColor(srgbRed: 0.706, green: 0.706, blue: 0.729, alpha: 1), 1)
    )!.draw(
        in: voice,
        relativeCenterPosition: NSPoint(x: -0.28, y: 0.4)
    )
    NSGradient(colorsAndLocations:
        (.white, 0),
        (bone, 0.45),
        (NSColor(srgbRed: 0.78, green: 0.78, blue: 0.80, alpha: 1), 1)
    )!.draw(in: caret, angle: 0)
}

let appIcon = bitmap(width: 1024, height: 1024) { drawAppIcon(pixels: 1024) }
writePNG(appIcon, to: packagingURL.appendingPathComponent("AppIcon-1024.png"))

// AppIcon.icns, with every size drawn from the vector mark rather than downsampled.
let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("WhisprGo-\(UUID().uuidString).iconset", isDirectory: true)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = points * factor
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(bitmap(width: pixels, height: pixels) { drawAppIcon(pixels: pixels) },
                 to: iconsetURL.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", packagingURL.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
try? FileManager.default.removeItem(at: iconsetURL)

// BrandMark.png: the template mark used inside the app (Settings, empty states).
// 430.5 x 318 design units, rendered at 2x.
let brandMark = bitmap(width: 861, height: 636) {
    let scale: CGFloat = 600
    let center = NSPoint(x: 430.5, y: 318)
    NSColor.black.setFill()
    NSBezierPath(ovalIn: Mark.voiceRect(scale: scale, center: center)).fill()
    Mark.caretPath(scale: scale, center: center, small: false).fill()
}
writePNG(brandMark, to: packagingURL.appendingPathComponent("BrandMark.png"))

// MenuBarIconTemplate.png: 22 x 15 pt at 4x, with the thick caret so it holds
// up next to SF Symbols in the menu bar.
let menuIcon = bitmap(width: 88, height: 60) {
    let scale: CGFloat = 60 / 1.06
    let center = NSPoint(x: 44, y: 30)
    NSColor.black.setFill()
    NSBezierPath(ovalIn: Mark.voiceRect(scale: scale, center: center)).fill()
    Mark.caretPath(scale: scale, center: center, small: true).fill()
}
writePNG(menuIcon, to: packagingURL.appendingPathComponent("MenuBarIconTemplate.png"))

print("Rendered AppIcon-1024.png, AppIcon.icns, BrandMark.png and MenuBarIconTemplate.png")
