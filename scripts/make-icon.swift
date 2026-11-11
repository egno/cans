// Renders the Cans app icon to Resources/AppIcon.icns (and a 1024 px preview PNG).
// Usage: swift scripts/make-icon.swift
//
// Styled after Prog Radio Mini's icon. Layout follows Apple's macOS icon grid: an 824 px rounded square centered on a
// 1024 px canvas, so macOS 26+ shows it as-is instead of inside a gray tile.

import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Palette shared with Prog Radio Mini's icon: black tile, electric-blue glow, white glyph.
let blue = color(0x1E9BFF)
let blueGlow = color(0x0A7CFF)
let white = color(0xF4F7FF)

/// Headphones glyph: headband arc, two cups and three equalizer bars, centred on `c`, `s` = scale (1 = main glyph).
func drawHeadphones(_ ctx: CGContext, center c: CGPoint, scale s: CGFloat, barGlow: CGFloat) {
    let radius = 230 * s
    ctx.saveGState()
    ctx.setLineWidth(54 * s); ctx.setLineCap(.butt)
    ctx.setStrokeColor(white)
    ctx.addArc(center: c, radius: radius, startAngle: .pi, endAngle: 0, clockwise: true)
    ctx.strokePath()
    for side in [-1.0, 1.0] as [CGFloat] {
        let cup = CGRect(x: c.x + side * radius - 62 * s, y: c.y - 200 * s, width: 124 * s, height: 236 * s)
        ctx.addPath(roundedRect(cup, 56 * s)); ctx.setFillColor(white); ctx.fillPath()
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: barGlow, color: blueGlow)
    for (dx, h) in [(-62.0, 130.0), (0.0, 210.0), (62.0, 96.0)] as [(CGFloat, CGFloat)] {
        let r = CGRect(x: c.x + dx * s - 21 * s, y: c.y - 82 * s - h * s / 2, width: 42 * s, height: h * s)
        ctx.addPath(roundedRect(r, 21 * s)); ctx.setFillColor(blue); ctx.fillPath()
    }
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)
    let bandBottom: CGFloat = 768, notchX: CGFloat = 512

    // Outer glow around the tile.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: blueGlow)
    ctx.addPath(tilePath); ctx.setFillColor(color(0x000000)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    ctx.setFillColor(color(0x020406)); ctx.fill(tile)

    // Inner glow along the border.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: color(0x0A7CFF, 0.9))
    ctx.addPath(roundedRect(tile.insetBy(dx: -30, dy: -30), 215))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x000000)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // Menu bar strip with the popover notch.
    let band = CGMutablePath()
    band.move(to: CGPoint(x: tile.minX, y: bandBottom))
    band.addLine(to: CGPoint(x: notchX - 30, y: bandBottom))
    band.addLine(to: CGPoint(x: notchX, y: bandBottom - 28))
    band.addLine(to: CGPoint(x: notchX + 30, y: bandBottom))
    band.addLine(to: CGPoint(x: tile.maxX, y: bandBottom))
    band.addLine(to: CGPoint(x: tile.maxX, y: tile.maxY))
    band.addLine(to: CGPoint(x: tile.minX, y: tile.maxY))
    band.closeSubpath()
    ctx.saveGState()
    ctx.addPath(band); ctx.clip()
    linear(ctx, [color(0x0D2B66), color(0x061633)], from: CGPoint(x: 512, y: tile.maxY), to: CGPoint(x: 512, y: bandBottom - 28))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: blueGlow)
    ctx.setStrokeColor(blue); ctx.setLineWidth(6); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: tile.minX, y: bandBottom))
    ctx.addLine(to: CGPoint(x: notchX - 30, y: bandBottom))
    ctx.addLine(to: CGPoint(x: notchX, y: bandBottom - 28))
    ctx.addLine(to: CGPoint(x: notchX + 30, y: bandBottom))
    ctx.addLine(to: CGPoint(x: tile.maxX, y: bandBottom))
    ctx.strokePath()
    ctx.restoreGState()

    // Status items in the strip: mini Cans glyph, divider, battery.
    drawHeadphones(ctx, center: CGPoint(x: notchX, y: 858), scale: 0.2, barGlow: 8)
    ctx.setFillColor(color(0x8FA3C7, 0.6)); ctx.fill(CGRect(x: 643, y: 820, width: 4, height: 64))
    let battery = CGRect(x: 690, y: 834, width: 88, height: 40)
    ctx.setStrokeColor(white); ctx.setLineWidth(6)
    ctx.addPath(roundedRect(battery, 11)); ctx.strokePath()
    ctx.setFillColor(white)
    ctx.addPath(roundedRect(CGRect(x: battery.minX + 9, y: battery.minY + 9, width: 46, height: 22), 4)); ctx.fillPath()
    ctx.addPath(roundedRect(CGRect(x: battery.maxX + 5, y: battery.midY - 9, width: 8, height: 18), 3)); ctx.fillPath()

    // The main glyph.
    drawHeadphones(ctx, center: CGPoint(x: 512, y: 474), scale: 1, barGlow: 36)
    ctx.restoreGState()

    // Bright border on top.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: blueGlow)
    ctx.addPath(roundedRect(tile.insetBy(dx: 5, dy: 5), 180))
    ctx.setStrokeColor(blue); ctx.setLineWidth(12); ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(tile.insetBy(dx: 5, dy: 5), 180))
    ctx.setStrokeColor(color(0x9AD4FF, 0.7)); ctx.setLineWidth(3); ctx.strokePath()
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / canvas, y: CGFloat(px) / canvas)
    drawIcon(ctx)
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try render(1024).representation(using: .png, properties: [:])!
    .write(to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
