import EventKit
import Foundation

/// Prints exactly what Mind can see — permission state, which calendars it's
/// watching, and the events it found in the horizon — then quits. First thing
/// to run when the panel says "clear" and you don't think it should.
///
///     open -n --env MIND_DIAGNOSE=/tmp/mind.txt dist/Mind.app && cat /tmp/mind.txt
///
/// Launch it through `open`, not from the shell: macOS attributes calendar
/// access to the *responsible* process, so a terminal-launched Mind inherits
/// the terminal's calendar permission rather than its own.
@MainActor
enum Diagnostics {
    static func run(state: AppState, prefs: Preferences) async {
        var lines: [String] = []
        func print(_ text: String) {
            lines.append(text)
            Swift.print(text)
        }

        await state.calendar.requestAccessIfNeeded()
        // Force a real account sync first — reading the local database without
        // this is exactly the failure mode these diagnostics exist to catch.
        state.calendar.pullRemoteSources(throttle: 0, force: true)
        try? await Task.sleep(for: .seconds(3))
        state.calendar.invalidateCache()
        state.calendar.refresh()
        state.tick()

        print("Mind diagnostics")
        print("  authorization: \(EKEventStore.authorizationStatus(for: .event).rawValue) → \(state.calendar.access)")
        if let error = state.calendar.lastError {
            print("  last error: \(error)")
        }
        print("  horizon: \(Int(prefs.horizonHours))h, all-day: \(prefs.includeAllDay), skip declined: \(prefs.ignoreDeclined)")

        print("  calendars (\(state.calendar.calendars.count)):")
        for calendar in state.calendar.calendars {
            let mark = prefs.isCalendarEnabled(calendar.id) ? "on " : "off"
            print("    [\(mark)] \(calendar.title) — \(calendar.sourceTitle)")
        }

        let events = state.calendar.events
        print("  events in horizon (\(events.count)):")
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        for event in events.prefix(20) {
            print("    \(formatter.string(from: event.start))  \(event.title)  [\(event.calendarTitle)]")
        }

        let urgency = state.urgency
        print("  headline: \(state.headline?.title ?? "none")")
        print("  phase: \(urgency.phase), intensity: \(String(format: "%.2f", urgency.intensity))")

        // Written to a file as well, because an app launched by `open` has no
        // terminal to print to.
        let destination = ProcessInfo.processInfo.environment["MIND_DIAGNOSE"] ?? ""
        if destination.hasPrefix("/") {
            try? lines.joined(separator: "\n").write(toFile: destination, atomically: true, encoding: .utf8)
        }
    }
}
