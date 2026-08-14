import Foundation
import SwiftUI

/// A calendar event, flattened out of EventKit so nothing downstream needs to
/// touch `EKEvent` (and so previews/tests can fabricate one).
struct AgendaEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let calendarTitle: String
    let calendarColor: Color
    let hasVideoLink: Bool
    let videoURL: URL?

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func isInProgress(at now: Date) -> Bool { start <= now && end > now }
    func secondsUntilStart(from now: Date) -> TimeInterval { start.timeIntervalSince(now) }
    func secondsUntilEnd(from now: Date) -> TimeInterval { end.timeIntervalSince(now) }
}

/// Where we are in the run-up to the next meeting. The scene and the copy both
/// key off this; `intensity` is the continuous version that drives animation.
enum Phase: Int, Comparable {
    case clear      // nothing on the horizon
    case distant    // something exists, but it's hours out
    case approaching// inside the calm threshold — the scene wakes up
    case imminent   // inside the alert threshold — things get busy
    case critical   // inside the critical threshold — fireworks
    case starting   // start time has passed within the last moments
    case inProgress // you're in it

    static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }

    var isNoisy: Bool { self >= .imminent }
}

struct Urgency {
    var phase: Phase = .clear
    /// 0 = asleep, 1 = full explosion.
    var intensity: Double = 0
    var secondsUntilStart: TimeInterval?
    var secondsUntilEnd: TimeInterval?

    static let clear = Urgency()

    /// Maps "time until the next meeting" onto a smooth 0...1 curve using the
    /// user's thresholds, so re-tuning the thresholds re-shapes the whole app.
    @MainActor
    static func evaluate(
        next: AgendaEvent?,
        current: AgendaEvent?,
        now: Date,
        prefs: Preferences
    ) -> Urgency {
        let horizon = prefs.horizonHours * 3600
        let calm = prefs.calmMinutes * 60
        let alert = prefs.alertMinutes * 60
        let critical = prefs.criticalMinutes * 60

        // A meeting in progress trumps the countdown, but keeps a bright
        // afterglow for its first minute so the "it's happening" moment lands.
        if let current {
            let elapsed = now.timeIntervalSince(current.start)
            let afterglow = 1 - smoothstep(0, 90, elapsed)
            return Urgency(
                phase: elapsed < 30 ? .starting : .inProgress,
                intensity: 0.5 + 0.5 * afterglow,
                secondsUntilStart: nil,
                secondsUntilEnd: current.secondsUntilEnd(from: now)
            )
        }

        guard let next else { return .clear }
        let t = next.secondsUntilStart(from: now)

        guard t < horizon else {
            return Urgency(phase: .clear, intensity: 0, secondsUntilStart: t, secondsUntilEnd: nil)
        }

        let phase: Phase
        let intensity: Double

        if t <= 0 {
            phase = .starting
            intensity = 1
        } else if t < critical {
            phase = .critical
            intensity = lerp(0.88, 1.0, 1 - t / max(critical, 1))
        } else if t < alert {
            phase = .imminent
            intensity = lerp(0.55, 0.88, smoothstep(alert, critical, t))
        } else if t < calm {
            phase = .approaching
            intensity = lerp(0.22, 0.55, smoothstep(calm, alert, t))
        } else {
            phase = .distant
            intensity = lerp(0.04, 0.22, smoothstep(horizon, calm, t))
        }

        return Urgency(phase: phase, intensity: intensity, secondsUntilStart: t, secondsUntilEnd: nil)
    }
}

// MARK: - Small math helpers used across the scene

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * clamp01(t) }

func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

/// Standard smoothstep, tolerant of `from > to` so it can be used to express
/// "as this value falls from A to B, ramp 0 → 1".
func smoothstep(_ from: Double, _ to: Double, _ value: Double) -> Double {
    guard from != to else { return value >= to ? 1 : 0 }
    let t = clamp01((value - from) / (to - from))
    return t * t * (3 - 2 * t)
}
