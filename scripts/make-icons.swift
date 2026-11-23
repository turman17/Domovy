#!/usr/bin/env swift
// Renders the Domovy "Footprint" mark into the asset catalog:
//   App/Assets.xcassets/AppIcon.appiconset/icon_<size>.png (16…1024, @1x/@2x)
//   App/Assets.xcassets/MenuBarGlyph.imageset/MenuBarGlyph.pdf (18 pt template, vector)
// Source of truth: Figma file fehhskCZ5fAWbmRlnTTZEW, Icon page (node 11:2).
// Usage: swift scripts/make-icons.swift   (from the repository root)
import AppKit
import CoreGraphics
import Foundation

let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("App/Assets.xcassets")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// SVG `M start A r r 0 0 1 end` on a circle around `center`: small arc, sweep flag 1.
/// Drawn in a y-down (SVG) user space, where increasing angles run clockwise on screen.
func arc(_ ctx: CGContext, center: CGPoint, radius: CGFloat, from start: CGPoint, to end: CGPoint) {
    let a0 = atan2(start.y - center.y, start.x - center.x)
    let a1 = atan2(end.y - center.y, end.x - center.x)
    ctx.move(to: start)
    ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
}

// MARK: App icon (1024 grid)

struct Segment { let start: CGPoint; let end: CGPoint; let hex: UInt32 }
let segments = [
    Segment(start: CGPoint(x: 567.6, y: 288.8), end: CGPoint(x: 665.9, y: 682.9), hex: 0x7C86F5),
    Segment(start: CGPoint(x: 567.6, y: 735.2), end: CGPoint(x: 376.8, y: 698.1), hex: 0xB6BCFF),
    Segment(start: CGPoint(x: 305.3, y: 612.8), end: CGPoint(x: 286.2, y: 468.1), hex: 0x4A52C8),
    Segment(start: CGPoint(x: 333.3, y: 367.3), end: CGPoint(x: 456.4, y: 288.8), hex: 0x6B6F80),
]

func drawIcon(_ ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    // y-down user space in 1024 units, like the SVG.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x30323D), color(0x14151A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    // 4 px inner stroke: a centred 8 px stroke clipped to the tile.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(8)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.setLineWidth(80)
    ctx.setLineCap(.round)
    let center = CGPoint(x: 512, y: 512)
    for segment in segments {
        arc(ctx, center: center, radius: 230, from: segment.start, to: segment.end)
        ctx.setStrokeColor(color(segment.hex))
        ctx.strokePath()
    }
    ctx.setFillColor(color(0xF2F3FF))
    ctx.fillEllipse(in: CGRect(x: 512 - 46, y: 512 - 46, width: 92, height: 92))
}

func writePNG(pixels: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    drawIcon(ctx, pixels: pixels)
    guard let image = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try writePNG(pixels: pixels, to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)", "filename": name])
    }
}
let iconContents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: iconContents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))

// MARK: Menu bar template glyph (18 pt, black, vector)

let glyphSet = assets.appendingPathComponent("MenuBarGlyph.imageset")
try FileManager.default.createDirectory(at: glyphSet, withIntermediateDirectories: true)
var box = CGRect(x: 0, y: 0, width: 18, height: 18)
guard let pdf = CGContext(glyphSet.appendingPathComponent("MenuBarGlyph.pdf") as CFURL, mediaBox: &box, nil) else {
    throw CocoaError(.fileWriteUnknown)
}
pdf.beginPDFPage(nil)
pdf.translateBy(x: 0, y: 18)
pdf.scaleBy(x: 1, y: -1)
pdf.setStrokeColor(color(0x000000))
pdf.setFillColor(color(0x000000))
pdf.setLineWidth(2.2)
pdf.setLineCap(.round)
let glyphArcs: [(CGPoint, CGPoint)] = [
    (CGPoint(x: 10.45, y: 3.18), CGPoint(x: 13.01, y: 13.46)),
    (CGPoint(x: 10.45, y: 14.82), CGPoint(x: 5.47, y: 13.85)),
    (CGPoint(x: 3.61, y: 11.63), CGPoint(x: 3.11, y: 7.86)),
    (CGPoint(x: 4.34, y: 5.22), CGPoint(x: 7.55, y: 3.18)),
]
for (start, end) in glyphArcs {
    arc(pdf, center: CGPoint(x: 9, y: 9), radius: 6, from: start, to: end)
    pdf.strokePath()
}
pdf.fillEllipse(in: CGRect(x: 9 - 1.4, y: 9 - 1.4, width: 2.8, height: 2.8))
pdf.endPDFPage()
pdf.closePDF()

let glyphContents: [String: Any] = [
    "images": [["idiom": "universal", "filename": "MenuBarGlyph.pdf"]],
    "info": ["author": "xcode", "version": 1],
    "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"],
]
try JSONSerialization.data(withJSONObject: glyphContents, options: [.prettyPrinted, .sortedKeys])
    .write(to: glyphSet.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) app icon PNGs and MenuBarGlyph.pdf")
