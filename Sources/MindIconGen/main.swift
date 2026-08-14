import AppKit
import CoreGraphics
import Foundation

// Generates Mind's app icon as a .iconset directory of PNGs.
// Usage: MindIconGen <output.iconset directory>

func drawIcon(size s: CGFloat, in ctx: CGContext) {
    ctx.saveGState()
    let space = CGColorSpaceCreateDeviceRGB()

    // Rounded-square plate with the app's calm gradient.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil))
    ctx.clip()

    let plate = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.93, green: 0.87, blue: 1.00, alpha: 1),
            CGColor(red: 0.85, green: 0.96, blue: 0.97, alpha: 1),
            CGColor(red: 1.00, green: 0.79, blue: 0.80, alpha: 1),
        ] as CFArray,
        locations: [0, 0.5, 1]
    )!
    ctx.drawLinearGradient(plate, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    let glow = CGGradient(
        colorsSpace: space,
        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.5), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: s * 0.5, y: s * 0.46), startRadius: 0,
        endCenter: CGPoint(x: s * 0.5, y: s * 0.46), endRadius: s * 0.36,
        options: []
    )

    drawSparkles(size: s, in: ctx)

    // The toaster itself, tilted like it's banking into a turn.
    ctx.saveGState()
    ctx.translateBy(x: s * 0.5, y: s * 0.44)
    ctx.rotate(by: 0.1)
    drawToaster(w: s * 0.46, in: ctx)
    ctx.restoreGState()

    ctx.restoreGState()
}

/// Same construction as the in-app toaster: body, bright top face, slot, lever,
/// feet, and a pair of wings that clear the body.
private func drawToaster(w: CGFloat, in ctx: CGContext) {
    let h = w * 0.62
    let body = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

    let chrome = CGColor(red: 0.99, green: 0.99, blue: 1.0, alpha: 1)
    let chromeMid = CGColor(red: 0.78, green: 0.82, blue: 0.92, alpha: 1)
    let ink = CGColor(red: 0.26, green: 0.27, blue: 0.40, alpha: 1)

    ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.03), blur: w * 0.09,
                  color: CGColor(red: 0.25, green: 0.18, blue: 0.35, alpha: 0.35))

    // Wings first — one on each side, both swept up and back.
    for (mirror, fill) in [(CGFloat(-1), chromeMid), (CGFloat(1), chrome)] {
        ctx.saveGState()
        ctx.translateBy(x: w * 0.1 * mirror, y: h * 0.42)
        ctx.scaleBy(x: mirror, y: 1)
        ctx.rotate(by: -0.25)
        let wing = CGMutablePath()
        wing.move(to: .zero)
        wing.addQuadCurve(to: CGPoint(x: w * 0.62, y: w * 0.5), control: CGPoint(x: w * 0.1, y: w * 0.46))
        wing.addQuadCurve(to: CGPoint(x: w * 0.42, y: w * 0.2), control: CGPoint(x: w * 0.5, y: w * 0.42))
        wing.addQuadCurve(to: CGPoint(x: w * 0.23, y: w * 0.06), control: CGPoint(x: w * 0.31, y: w * 0.24))
        wing.closeSubpath()
        ctx.addPath(wing)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Feet.
    for x in [-w * 0.3, w * 0.2] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: body.minY - w * 0.05, width: w * 0.1, height: w * 0.07),
                           cornerWidth: w * 0.025, cornerHeight: w * 0.025, transform: nil))
        ctx.setFillColor(ink)
        ctx.fillPath()
    }

    ctx.addPath(CGPath(roundedRect: body, cornerWidth: w * 0.13, cornerHeight: w * 0.13, transform: nil))
    ctx.setFillColor(chrome)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Top face and slot.
    ctx.addPath(CGPath(roundedRect: CGRect(x: body.minX + w * 0.05, y: body.maxY - h * 0.36,
                                           width: w * 0.9, height: h * 0.34),
                       cornerWidth: w * 0.07, cornerHeight: w * 0.07, transform: nil))
    ctx.setFillColor(CGColor(red: 0.90, green: 0.93, blue: 1.0, alpha: 1))
    ctx.fillPath()

    ctx.addPath(CGPath(roundedRect: CGRect(x: -w * 0.28, y: body.maxY - h * 0.26,
                                           width: w * 0.46, height: h * 0.13),
                       cornerWidth: h * 0.06, cornerHeight: h * 0.06, transform: nil))
    ctx.setFillColor(ink)
    ctx.fillPath()

    // Lever and dial.
    ctx.addPath(CGPath(roundedRect: CGRect(x: w * 0.34, y: h * 0.02, width: w * 0.16, height: h * 0.14),
                       cornerWidth: h * 0.07, cornerHeight: h * 0.07, transform: nil))
    ctx.setFillColor(ink)
    ctx.fillPath()

    ctx.addEllipse(in: CGRect(x: w * 0.3, y: -h * 0.3, width: w * 0.11, height: w * 0.11))
    ctx.setFillColor(CGColor(red: 0.58, green: 0.52, blue: 0.68, alpha: 1))
    ctx.fillPath()
}

private func drawSparkles(size s: CGFloat, in ctx: CGContext) {
    let points = [
        (CGPoint(x: s * 0.21, y: s * 0.72), s * 0.055),
        (CGPoint(x: s * 0.79, y: s * 0.74), s * 0.038),
        (CGPoint(x: s * 0.76, y: s * 0.24), s * 0.045),
        (CGPoint(x: s * 0.24, y: s * 0.25), s * 0.03),
    ]
    for (point, r) in points {
        let star = CGMutablePath()
        star.move(to: CGPoint(x: point.x, y: point.y + r))
        star.addQuadCurve(to: CGPoint(x: point.x + r, y: point.y), control: point)
        star.addQuadCurve(to: CGPoint(x: point.x, y: point.y - r), control: point)
        star.addQuadCurve(to: CGPoint(x: point.x - r, y: point.y), control: point)
        star.addQuadCurve(to: CGPoint(x: point.x, y: point.y + r), control: point)
        ctx.addPath(star)
        ctx.setFillColor(CGColor(red: 1, green: 0.66, blue: 0.36, alpha: 0.95))
        ctx.fillPath()
    }
}

func writePNG(pixels: Int, to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw NSError(domain: "MindIconGen", code: 1) }

    ctx.setAllowsAntialiasing(true)
    drawIcon(size: CGFloat(pixels), in: ctx)

    guard let image = ctx.makeImage() else { throw NSError(domain: "MindIconGen", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MindIconGen", code: 3)
    }
    try data.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: MindIconGen <output.iconset>\n".utf8))
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    try writePNG(pixels: variant.pixels, to: outputDirectory.appendingPathComponent(variant.name))
}
print("wrote \(variants.count) icon images to \(outputDirectory.path)")
