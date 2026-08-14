import CoreGraphics
import Foundation

/// Mind is meant to live anywhere from a 200pt sliver to a half-screen panel,
/// so nothing is a fixed point size. Every metric is derived from the current
/// bounds and clamped to a range that still reads well.
struct AmbientLayout {
    enum Tier: Int, Comparable {
        case micro      // a glanceable sliver
        case compact    // title + countdown
        case regular    // + detail line and fuse
        case tall       // + upcoming agenda

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let size: CGSize
    let tier: Tier

    init(size: CGSize) {
        self.size = size
        let w = size.width
        let h = size.height
        if h < 108 || w < 224 {
            tier = .micro
        } else if h < 176 {
            tier = .compact
        } else if h < 268 {
            tier = .regular
        } else {
            tier = .tall
        }
    }

    private var shortSide: Double { min(size.width, size.height) }

    var padding: Double {
        switch tier {
        case .micro: return 9
        case .compact: return 12
        case .regular: return 14
        case .tall: return 16
        }
    }

    var cornerRadius: Double {
        min(20, max(10, shortSide * 0.11))
    }

    var stackSpacing: Double {
        switch tier {
        case .micro: return 1
        case .compact: return 3
        default: return 4
        }
    }

    /// Countdown is the hero; it gets the most room and shrinks last.
    var countdownSize: Double {
        let byHeight = size.height * (tier == .micro ? 0.34 : 0.19)
        let byWidth = size.width * 0.19
        return clampSize(min(byHeight, byWidth), 15, 52)
    }

    var titleSize: Double {
        let byHeight = size.height * (tier == .micro ? 0.16 : 0.105)
        let byWidth = size.width * 0.085
        return clampSize(min(byHeight, byWidth), 11, 23)
    }

    var captionSize: Double {
        clampSize(min(size.height * 0.055, size.width * 0.045), 9, 13)
    }

    var labelSize: Double {
        clampSize(min(size.height * 0.048, size.width * 0.04), 8, 11)
    }

    var rowSize: Double {
        clampSize(min(size.height * 0.045, size.width * 0.04), 9, 12.5)
    }

    var rowSpacing: Double { tier == .tall ? 4 : 3 }

    var dotSize: Double { clampSize(shortSide * 0.032, 5, 8) }

    var fuseHeight: Double { tier == .micro ? 2.5 : 4 }

    var showsDetail: Bool { tier >= .compact }

    var showsFuse: Bool { tier >= .compact }

    /// How many upcoming rows actually fit under the headline block.
    var agendaRows: Int {
        guard tier >= .regular else { return 0 }
        let headlineBlock = padding * 2 + labelSize + titleSize + countdownSize + captionSize + fuseHeight + 34
        let available = size.height - headlineBlock
        let rowHeight = rowSize * 1.6 + rowSpacing
        guard available > rowHeight else { return 0 }
        return min(6, Int(available / rowHeight))
    }

    private func clampSize(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
