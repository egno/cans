// Renders the Cans app icon to Resources/AppIcon.icns (and a 1024 px preview PNG).
// Usage: swift scripts/make-icon.swift
//
// Layout follows Apple's macOS icon grid: an 824 px rounded square centered on a
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

func drawIcon(_ ctx: CGContext) {
    // Background tile with drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(color(0x161B2E)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    linear(ctx, [color(0x3A4A8C), color(0x1B2142), color(0x0E1122)],
           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Soft top glow.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x8FA2FF, 0.35), color(0x8FA2FF, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 860), endRadius: 520, options: [])
    ctx.restoreGState()

    // Headband: thick arc over the top.
    let center = CGPoint(x: 512, y: 470), radius: CGFloat = 255
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.4))
    ctx.setLineWidth(58); ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xF2F4FF))
    ctx.addArc(center: center, radius: radius, startAngle: .pi, endAngle: 0, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // Ear cups.
    for side in [-1.0, 1.0] as [CGFloat] {
        let cx = center.x + side * radius
        let cup = CGRect(x: cx - 78, y: 236, width: 156, height: 290)
        let cupPath = roundedRect(cup, 70)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: color(0x000000, 0.45))
        ctx.addPath(cupPath); ctx.setFillColor(color(0xFF6A55)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(cupPath); ctx.clip()
        linear(ctx, [color(0xFF8A5C), color(0xF2456B)], from: CGPoint(x: cx, y: cup.maxY), to: CGPoint(x: cx, y: cup.minY))
        // Cushion on the inner side.
        let cushionX = side < 0 ? cup.maxX - 46 : cup.minX
        ctx.addPath(roundedRect(CGRect(x: cushionX, y: cup.minY + 22, width: 46, height: cup.height - 44), 23))
        ctx.setFillColor(color(0x000000, 0.22)); ctx.fillPath()
        ctx.restoreGState()
    }

    // Equalizer bars between the cups.
    let bars: [(x: CGFloat, h: CGFloat)] = [(436, 150), (512, 230), (588, 110)]
    for bar in bars {
        let r = CGRect(x: bar.x - 24, y: 381 - bar.h / 2, width: 48, height: bar.h)
        ctx.addPath(roundedRect(r, 24))
        ctx.setFillColor(color(0xF2F4FF, 0.92)); ctx.fillPath()
    }
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
