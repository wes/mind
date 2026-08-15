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

/// Answers one question: when an event appears in the calendar, which kind of
/// `EKEventStore` sees it?
///
///     open -n --env MIND_WATCH=/tmp/mind-watch.txt /Applications/Mind.app
///     tail -f /tmp/mind-watch.txt
///
/// Then add an event. Three columns, all querying the same window in the same
/// process, every few seconds:
///
///   cached      a long-lived store, never reset — what Mind used to do
///   afterReset  a long-lived store with reset() before each read — the fix
///   freshStore  a brand new store each time — equivalent to relaunching
///
/// Whichever columns move tell you where the staleness lives.
@MainActor
enum StoreWatch {
    static func run(outputPath: String) async {
        let cachedStore = EKEventStore()
        let resetStore = EKEventStore()

        do {
            _ = try await cachedStore.requestFullAccessToEvents()
            _ = try await resetStore.requestFullAccessToEvents()
        } catch {
            append("could not get calendar access: \(error.localizedDescription)", to: outputPath)
            return
        }

        // Prime the long-lived stores so they have something to be stale about.
        _ = count(in: cachedStore)
        append("watching. cached / afterReset / freshStore — add an event now.", to: outputPath)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        while !Task.isCancelled {
            let cached = count(in: cachedStore)

            resetStore.reset()
            let afterReset = count(in: resetStore)

            let freshStore = EKEventStore()
            let fresh = count(in: freshStore)

            let line = "\(formatter.string(from: Date()))  cached=\(cached)  afterReset=\(afterReset)  freshStore=\(fresh)"
            append(line, to: outputPath)

            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Deliberately unfiltered: this is about cache freshness, not about which
    /// events Mind chooses to show.
    private static func count(in store: EKEventStore) -> Int {
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3600),
            end: now.addingTimeInterval(24 * 3600),
            calendars: nil
        )
        return store.events(matching: predicate).count
    }

    private static func append(_ line: String, to path: String) {
        Swift.print(line)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
