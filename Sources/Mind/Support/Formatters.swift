import Foundation

/// All of Mind's copy lives here so the tone stays consistent between the
/// panel, the menu bar and the agenda list.
enum Copy {
    static func clock(_ date: Date, use24Hour: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(use24Hour ? "Hmm" : "hmma")
        return formatter.string(from: date)
    }

    static func range(_ event: AgendaEvent, use24Hour: Bool) -> String {
        if event.isAllDay { return "All day" }
        return "\(clock(event.start, use24Hour: use24Hour)) – \(clock(event.end, use24Hour: use24Hour))"
    }

    /// Short relative countdown: "2h 15m", "47m", "90s", "now".
    static func countdown(_ seconds: TimeInterval, showSeconds: Bool) -> String {
        let s = max(0, seconds)
        if s < 1 { return "now" }
        if s < 60 {
            return showSeconds ? "\(Int(s.rounded()))s" : "<1m"
        }
        let minutes = Int((s / 60).rounded(.down))
        if minutes < 60 {
            if minutes < 5 && showSeconds {
                let rem = Int(s) % 60
                return rem == 0 ? "\(minutes)m" : "\(minutes)m \(rem)s"
            }
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let rem = minutes % 60
        if hours < 24 { return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m" }
        let days = hours / 24
        return "\(days)d"
    }

    /// A short mood word shown when the calendar is quiet.
    static func restfulHeadline(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 0..<5: return "Nothing but night"
        case 5..<12: return "Clear morning"
        case 12..<17: return "Clear afternoon"
        case 17..<21: return "Clear evening"
        default: return "Clear ahead"
        }
    }

    static func menuBarTitle(urgency: Urgency, event: AgendaEvent?) -> String {
        guard let event else { return "◌" }
        switch urgency.phase {
        case .inProgress, .starting:
            return "● \(shortTitle(event.title))"
        case .clear:
            return "◌"
        default:
            let t = countdown(urgency.secondsUntilStart ?? 0, showSeconds: false)
            let glyph = urgency.phase >= .critical ? "◉" : (urgency.phase >= .imminent ? "◍" : "◔")
            return "\(glyph) \(t)"
        }
    }

    static func shortTitle(_ title: String, limit: Int = 18) -> String {
        title.count <= limit ? title : String(title.prefix(limit - 1)) + "…"
    }

    static func relativeDay(_ date: Date, now: Date = Date()) -> String? {
        let cal = Foundation.Calendar.current
        if cal.isDateInToday(date) { return nil }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }
}
