#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Run from any directory; every asset is rasterized directly from these vectors.
let script = URL(fileURLWithPath: #filePath).standardizedFileURL
let macOS = script.deletingLastPathComponent().deletingLastPathComponent()
let output = macOS.appendingPathComponent("Bluemock/Bluemock/Assets.xcassets/AppIcon.appiconset")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

func bitmap(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// A fourth-order superellipse gives continuous curvature into the straight sides.
// The bounding square is 824 points; its softened corners approximate a 185 pt radius.
func bodyPath() -> CGPath {
    let path = CGMutablePath()
    for index in 0...720 {
        let angle = CGFloat(index) * .pi * 2 / 720
        let cosine = cos(angle)
        let sine = sin(angle)
        let point = CGPoint(x: 512 + 412 * copysign(sqrt(abs(cosine)), cosine),
                            y: 512 + 412 * copysign(sqrt(abs(sine)), sine))
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> CGImage {
    let context = bitmap(width: pixels, height: pixels)
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    let body = bodyPath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24,
                      color: color(0, 0, 0, 0.30))
    context.addPath(body)
    context.setFillColor(color(30 / 255, 58 / 255, 138 / 255))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [color(30 / 255, 58 / 255, 138 / 255),
                                       color(14 / 255, 165 / 255, 233 / 255)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924),
                               end: CGPoint(x: 924, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let sheen = CGGradient(colorsSpace: colorSpace,
                           colors: [color(1, 1, 1, 0.12), color(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924),
                               end: CGPoint(x: 512, y: 640), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    let small = pixels <= 32
    context.setStrokeColor(color(1, 1, 1))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(small ? 72 : 56)
    let rune = CGMutablePath()
    rune.move(to: CGPoint(x: 310, y: 625))
    rune.addLine(to: CGPoint(x: 555, y: 417))
    rune.addLine(to: CGPoint(x: 420, y: 322))
    rune.addLine(to: CGPoint(x: 420, y: 702))
    rune.addLine(to: CGPoint(x: 555, y: 607))
    rune.addLine(to: CGPoint(x: 310, y: 399))
    context.addPath(rune)
    context.strokePath()

    for radius: CGFloat in small ? [140] : [140, 245] {
        let outer = radius == 245
        context.setLineWidth(outer ? 28 : (small ? 56 : 36))
        // Round caps add one stroke width to each dash: painted dash/gap = 44/30.
        context.setLineDash(phase: 0, lengths: outer ? [16, 58] : [])
        context.addArc(center: CGPoint(x: 530, y: 512), radius: radius,
                       startAngle: -.pi * 0.23, endAngle: .pi * 0.23, clockwise: false)
        context.strokePath()
    }
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let png = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "BluemockIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try png.write(to: url, options: .atomic)
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try writePNG(render(pixels: size * scale), to: output.appendingPathComponent(filename))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)",
                        "scale": "\(scale)x", "filename": filename])
    }
}
let manifest: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try (json + Data([0x0A])).write(to: output.appendingPathComponent("Contents.json"), options: .atomic)

// Each row includes the actual 1024 px master and 1:1 small-size samples.
let preview = bitmap(width: 1536, height: 2240)
for (row, dark) in [false, true].enumerated() {
    let bottom = CGFloat(1 - row) * 1120
    preview.setFillColor(dark ? color(30 / 255, 30 / 255, 30 / 255) : color(0.90, 0.90, 0.90))
    preview.fill(CGRect(x: 0, y: bottom, width: 1536, height: 1120))
    preview.draw(render(pixels: 1024), in: CGRect(x: 24, y: bottom + 48, width: 1024, height: 1024))
    var left: CGFloat = 1092
    for size in [16, 32, 64, 128] {
        preview.draw(render(pixels: size), in: CGRect(x: left, y: bottom + 496,
                                                     width: CGFloat(size), height: CGFloat(size)))
        left += CGFloat(size) + 24
    }
}
let previewURL = URL(fileURLWithPath: "/tmp/bluemock-icon-preview.png")
try writePNG(preview.makeImage()!, to: previewURL)
print("Generated 10 AppIcon PNGs and Contents.json at \(output.path)")
print("Preview: \(previewURL.path)")
