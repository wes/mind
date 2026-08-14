import Foundation
import SwiftUI

/// Hand-drawn vector toasters, because that is the correct thing to have
/// flying across your screen while you wait for a meeting.
///
/// Everything is drawn around the origin so the caller only has to translate,
/// rotate and pick a scale (which is the body width in points). The silhouette
/// is doing all the work here — these are often only 40 points across, so the
/// shapes are exaggerated: a fat slot, a big lever, and wings that clear the
/// body entirely at the top of the flap.
enum Toaster {

    static func draw(
        in ctx: inout GraphicsContext,
        scale: Double,
        flap: Double,
        seed: Int,
        palette: Palette,
        intensity: Double
    ) {
        let w = scale
        // Chrome first, palette second: a toaster that borrows too much of the
        // background's own colour dissolves into it.
        let tint = palette.accent(seed, intensity: intensity)
        let light = RGB(0.98, 0.99, 1.00).mix(tint, 0.16)
        let mid = RGB(0.60, 0.65, 0.78).mix(tint, 0.28)
        let dark = RGB(0.19, 0.21, 0.32).mix(tint, 0.14)

        // Flap sweeps the wings from "just above the shoulders" to "straight up".
        let angle = lerp(0.20, -0.85, (flap + 1) / 2)
        let anchor = CGPoint(x: w * 0.14, y: -w * 0.28)

        drawWing(in: &ctx, at: anchor, w: w, angle: angle + 0.34,
                 fill: mid, edge: dark, offset: CGSize(width: -w * 0.1, height: w * 0.02))

        drawBody(in: &ctx, w: w, light: light, mid: mid, dark: dark, intensity: intensity)

        drawWing(in: &ctx, at: anchor, w: w, angle: angle,
                 fill: light, edge: dark, offset: .zero)
    }

    private static func drawBody(
        in ctx: inout GraphicsContext,
        w: Double,
        light: RGB, mid: RGB, dark: RGB,
        intensity: Double
    ) {
        let h = w * 0.62
        let body = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let bodyPath = Path(roundedRect: body, cornerRadius: w * 0.13)
        let stroke = max(0.7, w * 0.03)

        // Feet, drawn first so the body sits on top of them.
        for x in [-w * 0.3, w * 0.26] {
            let foot = Path(roundedRect: CGRect(x: x, y: body.maxY - w * 0.01,
                                                width: w * 0.1, height: w * 0.06),
                            cornerRadius: w * 0.02)
            ctx.fill(foot, with: .color(dark.color(opacity: 0.8)))
        }

        ctx.fill(
            bodyPath,
            with: .linearGradient(
                Gradient(colors: [light.color(), mid.color(), mid.darkened(0.18).color()]),
                startPoint: CGPoint(x: body.minX, y: body.minY),
                endPoint: CGPoint(x: body.maxX, y: body.maxY)
            )
        )

        // Bright top face — the giveaway that you're looking at a toaster and
        // not a radio.
        let topFace = Path(roundedRect: CGRect(x: body.minX + w * 0.05, y: body.minY + w * 0.015,
                                               width: w * 0.9, height: h * 0.34),
                           cornerRadius: w * 0.08)
        ctx.fill(topFace, with: .color(light.lightened(0.35).color(opacity: 0.75)))

        // Toast slot.
        let slot = Path(roundedRect: CGRect(x: -w * 0.28, y: body.minY + h * 0.11,
                                            width: w * 0.46, height: h * 0.13),
                        cornerRadius: h * 0.06)
        ctx.fill(slot, with: .color(dark.darkened(0.25).color(opacity: 0.9)))

        // Vertical specular band down the front.
        let shine = Path(roundedRect: CGRect(x: -w * 0.4, y: -h * 0.12,
                                             width: w * 0.13, height: h * 0.5),
                         cornerRadius: w * 0.05)
        ctx.fill(shine, with: .color(light.lightened(0.5).color(opacity: 0.55)))

        // Lever on the trailing face, plus its browning dial.
        let lever = Path(roundedRect: CGRect(x: w * 0.34, y: -h * 0.16,
                                             width: w * 0.16, height: h * 0.14),
                         cornerRadius: h * 0.07)
        ctx.fill(lever, with: .color(dark.color(opacity: 0.92)))

        let dial = Path(ellipseIn: CGRect(x: w * 0.3, y: h * 0.08, width: w * 0.11, height: w * 0.11))
        ctx.fill(dial, with: .color(dark.darkened(0.1).color(opacity: 0.85)))

        ctx.stroke(bodyPath, with: .color(dark.color(opacity: 0.9)), lineWidth: stroke)

        // Above the alert threshold the toasters themselves start to run hot.
        let heat = smoothstep(0.7, 1.0, intensity)
        if heat > 0.01 {
            ctx.fill(bodyPath, with: .color(RGB(1, 0.72, 0.45).color(opacity: heat * 0.3)))
        }
    }

    /// A cartoon wing: smooth leading edge out to the tip, three scallops back.
    private static func drawWing(
        in ctx: inout GraphicsContext,
        at anchor: CGPoint,
        w: Double,
        angle: Double,
        fill: RGB,
        edge: RGB,
        offset: CGSize
    ) {
        var path = Path()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: w * 0.66, y: -w * 0.52),
                          control: CGPoint(x: w * 0.14, y: -w * 0.46))
        path.addQuadCurve(to: CGPoint(x: w * 0.45, y: -w * 0.21),
                          control: CGPoint(x: w * 0.53, y: -w * 0.44))
        path.addQuadCurve(to: CGPoint(x: w * 0.25, y: -w * 0.07),
                          control: CGPoint(x: w * 0.33, y: -w * 0.26))
        path.addQuadCurve(to: .zero,
                          control: CGPoint(x: w * 0.12, y: -w * 0.02))
        path.closeSubpath()

        let transform = CGAffineTransform(
            translationX: anchor.x + offset.width,
            y: anchor.y + offset.height
        ).rotated(by: angle)
        let placed = path.applying(transform)

        ctx.fill(placed, with: .color(fill.color(opacity: 0.98)))
        ctx.stroke(placed, with: .color(edge.color(opacity: 0.8)), lineWidth: max(0.6, w * 0.026))
    }

    /// A slice of toast, mid-flight, gently tumbling.
    static func drawToast(
        in ctx: inout GraphicsContext,
        scale: Double,
        seed: Int,
        palette: Palette,
        intensity: Double
    ) {
        let w = scale
        let h = scale * 0.95
        let crust = RGB(hex: 0xC98A45).mix(palette.accent(seed, intensity: intensity), 0.2)
        let crumb = RGB(hex: 0xF6DFAE).mix(palette.accent(seed, intensity: intensity), 0.14)

        var bread = Path()
        let left = -w / 2, right = w / 2
        let top = -h / 2, bottom = h / 2
        bread.move(to: CGPoint(x: left, y: bottom - h * 0.1))
        bread.addQuadCurve(to: CGPoint(x: left + w * 0.1, y: bottom), control: CGPoint(x: left, y: bottom))
        bread.addLine(to: CGPoint(x: right - w * 0.1, y: bottom))
        bread.addQuadCurve(to: CGPoint(x: right, y: bottom - h * 0.1), control: CGPoint(x: right, y: bottom))
        bread.addLine(to: CGPoint(x: right, y: top + h * 0.3))
        bread.addQuadCurve(to: CGPoint(x: right - w * 0.26, y: top), control: CGPoint(x: right, y: top + h * 0.02))
        bread.addQuadCurve(to: CGPoint(x: left + w * 0.26, y: top), control: CGPoint(x: 0, y: top - h * 0.18))
        bread.addQuadCurve(to: CGPoint(x: left, y: top + h * 0.3), control: CGPoint(x: left, y: top + h * 0.02))
        bread.closeSubpath()

        ctx.fill(bread, with: .color(crust.color()))
        ctx.fill(
            bread.applying(CGAffineTransform(scaleX: 0.76, y: 0.72)),
            with: .linearGradient(
                Gradient(colors: [crumb.lightened(0.25).color(), crumb.darkened(0.1).color()]),
                startPoint: CGPoint(x: 0, y: top),
                endPoint: CGPoint(x: 0, y: bottom)
            )
        )
        ctx.stroke(bread, with: .color(crust.darkened(0.35).color(opacity: 0.55)), lineWidth: max(0.4, w * 0.02))
    }
}
