import SwiftUI

/// A tiny RGB value type so colours can be interpolated cheaply inside the
/// render loop without bouncing through `NSColor` conversions every frame.
struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Convenience for authoring palettes as hex.
    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    func mix(_ other: RGB, _ t: Double) -> RGB {
        let k = clamp01(t)
        return RGB(r + (other.r - r) * k, g + (other.g - g) * k, b + (other.b - b) * k)
    }

    func color(opacity: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Pushes a colour toward white — used for spark cores and highlights.
    func lightened(_ amount: Double) -> RGB { mix(RGB(1, 1, 1), amount) }

    func darkened(_ amount: Double) -> RGB { mix(RGB(0, 0, 0), amount) }
}

/// A palette describes the app's whole emotional range: where it sits when the
/// day is empty, and where it lands when a meeting is seconds away.
struct Palette: Identifiable, Hashable {
    let id: String
    let name: String

    /// Background gradient endpoints at rest.
    var calmTop: RGB
    var calmBottom: RGB
    /// Background gradient endpoints at full intensity.
    var hotTop: RGB
    var hotBottom: RGB
    /// Ink colour for text (kept legible against both ends of the gradient).
    var inkCalm: RGB
    var inkHot: RGB
    /// Particle colours, cycled by seed.
    var accents: [RGB]
    /// Firework colours. These are deliberately more saturated than `accents`:
    /// a pastel spark on a pastel sky is not a firework, it's a smudge.
    var sparks: [RGB]

    static func == (lhs: Palette, rhs: Palette) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func background(_ intensity: Double) -> (top: Color, bottom: Color) {
        let t = intensity * intensity  // hold the calm look longer
        return (calmTop.mix(hotTop, t).color(), calmBottom.mix(hotBottom, t).color())
    }

    func ink(_ intensity: Double) -> Color {
        inkCalm.mix(inkHot, smoothstep(0.35, 0.95, intensity)).color()
    }

    /// A glow in the background's own colour, painted behind text so a toaster
    /// can fly straight through a word without eating it.
    func halo(_ intensity: Double) -> Color {
        let t = intensity * intensity
        let top = calmTop.mix(hotTop, t)
        let bottom = calmBottom.mix(hotBottom, t)
        return top.mix(bottom, 0.5).color(opacity: 0.9)
    }

    /// How bright the background currently is, which decides whether sparks
    /// should be drawn additively (dark sky) or as solid ink (pale sky).
    func backgroundLuminance(_ intensity: Double) -> Double {
        let t = intensity * intensity
        let c = calmTop.mix(hotTop, t).mix(calmBottom.mix(hotBottom, t), 0.5)
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    func isPaleSky(_ intensity: Double) -> Bool { backgroundLuminance(intensity) > 0.55 }

    func spark(_ seed: Int) -> RGB {
        guard !sparks.isEmpty else { return RGB(1, 1, 1) }
        return sparks[((seed % sparks.count) + sparks.count) % sparks.count]
    }

    func accent(_ seed: Int, intensity: Double = 0) -> RGB {
        guard !accents.isEmpty else { return RGB(1, 1, 1) }
        let base = accents[((seed % accents.count) + accents.count) % accents.count]
        return base.lightened(0.25 * intensity)
    }

    // MARK: Presets

    static let cotton = Palette(
        id: "cotton",
        name: "Cotton",
        calmTop: RGB(hex: 0xF3E9FF),
        calmBottom: RGB(hex: 0xDDF4F6),
        hotTop: RGB(hex: 0xFF9AA8),
        hotBottom: RGB(hex: 0xFFD36E),
        inkCalm: RGB(hex: 0x4A3F63),
        inkHot: RGB(hex: 0x3A1224),
        accents: [
            RGB(hex: 0xFFC2D1), RGB(hex: 0xC8B6FF), RGB(hex: 0xA8E6CF),
            RGB(hex: 0xFFE0AC), RGB(hex: 0xB8E1FF),
        ],
        sparks: [
            RGB(hex: 0xFF3D7F), RGB(hex: 0xFF8A3D), RGB(hex: 0x8B5CF6),
            RGB(hex: 0x22C3A6), RGB(hex: 0xFFC831),
        ]
    )

    static let aurora = Palette(
        id: "aurora",
        name: "Aurora",
        calmTop: RGB(hex: 0xE4F7F0),
        calmBottom: RGB(hex: 0xD6ECFF),
        hotTop: RGB(hex: 0x6FE3C4),
        hotBottom: RGB(hex: 0x4C7BE8),
        inkCalm: RGB(hex: 0x2C4A52),
        inkHot: RGB(hex: 0x06202E),
        accents: [
            RGB(hex: 0x9BF6D6), RGB(hex: 0x8ECAE6), RGB(hex: 0xCDB4F6),
            RGB(hex: 0xFFF3B0), RGB(hex: 0x7FD8BE),
        ],
        sparks: [
            RGB(hex: 0x0EA5E9), RGB(hex: 0x10B981), RGB(hex: 0x7C5CFF),
            RGB(hex: 0xF59E0B), RGB(hex: 0xFF4D8D),
        ]
    )

    static let sunset = Palette(
        id: "sunset",
        name: "Sunset",
        calmTop: RGB(hex: 0xFFF1E6),
        calmBottom: RGB(hex: 0xFFE4EC),
        hotTop: RGB(hex: 0xFF6B4A),
        hotBottom: RGB(hex: 0xB5179E),
        inkCalm: RGB(hex: 0x5B3A48),
        inkHot: RGB(hex: 0x2B0716),
        accents: [
            RGB(hex: 0xFFB4A2), RGB(hex: 0xFFCB77), RGB(hex: 0xF9C0C0),
            RGB(hex: 0xE0AAFF), RGB(hex: 0xFFE8D6),
        ],
        sparks: [
            RGB(hex: 0xE01E5A), RGB(hex: 0xFF6B00), RGB(hex: 0xB5179E),
            RGB(hex: 0xFFC300), RGB(hex: 0x7209B7),
        ]
    )

    static let graphite = Palette(
        id: "graphite",
        name: "Graphite",
        calmTop: RGB(hex: 0x2A2D34),
        calmBottom: RGB(hex: 0x1B1D22),
        hotTop: RGB(hex: 0x6B3A52),
        hotBottom: RGB(hex: 0x2A1620),
        inkCalm: RGB(hex: 0xE8E6F0),
        inkHot: RGB(hex: 0xFFF2F6),
        accents: [
            RGB(hex: 0xB8C0FF), RGB(hex: 0xFFD6A5), RGB(hex: 0xCAFFBF),
            RGB(hex: 0xFFADAD), RGB(hex: 0xFDFFB6),
        ],
        sparks: [
            RGB(hex: 0xB8C0FF), RGB(hex: 0xFFD6A5), RGB(hex: 0xCAFFBF),
            RGB(hex: 0xFFADAD), RGB(hex: 0xFDFFB6),
        ]
    )

    static let mint = Palette(
        id: "mint",
        name: "Mint Cloud",
        calmTop: RGB(hex: 0xF0FFF6),
        calmBottom: RGB(hex: 0xE3F6FF),
        hotTop: RGB(hex: 0xFFB703),
        hotBottom: RGB(hex: 0xFB8500),
        inkCalm: RGB(hex: 0x35564B),
        inkHot: RGB(hex: 0x3A1F00),
        accents: [
            RGB(hex: 0xB7E4C7), RGB(hex: 0xD8F3DC), RGB(hex: 0xFFE5B4),
            RGB(hex: 0xBDE0FE), RGB(hex: 0xFFC8DD),
        ],
        sparks: [
            RGB(hex: 0x0FB5A6), RGB(hex: 0xFF8C1A), RGB(hex: 0xE01E5A),
            RGB(hex: 0x7C3AED), RGB(hex: 0xFFB020),
        ]
    )

    static let all: [Palette] = [cotton, aurora, sunset, mint, graphite]

    static func palette(id: String) -> Palette {
        all.first { $0.id == id } ?? cotton
    }
}
