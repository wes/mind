import AppKit
import EventKit
import Foundation
import Observation
import SwiftUI

/// The heartbeat of the app: ticks the clock, keeps the agenda fresh, and
/// derives the single `Urgency` value that everything else reads.
@MainActor
@Observable
final class AppState {
    let prefs: Preferences
    let calendar: CalendarService

    private(set) var now: Date = Date()
    private(set) var urgency: Urgency = .clear

    private var clockTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    /// Set `MIND_DEMO=<minutes>` to run against a fabricated agenda whose first
    /// event starts that many minutes out. Handy for seeing the whole intensity
    /// range — and for screenshots — without rearranging your actual day.
    private let demoEvents: [AgendaEvent]?

    init(prefs: Preferences = .shared, demoMinutes: Double? = nil) {
        self.prefs = prefs
        self.calendar = CalendarService(prefs: prefs)
        let minutes = demoMinutes ?? ProcessInfo.processInfo.environment["MIND_DEMO"].flatMap(Double.init)
        self.demoEvents = minutes.map { Self.makeDemoEvents(minutesOut: $0) }
    }

    private static func makeDemoEvents(minutesOut minutes: Double) -> [AgendaEvent] {
        let now = Date()
        let titles = ["Design review", "1:1 with Sam", "Roadmap sync", "Coffee with Alex"]
        return titles.enumerated().map { index, title in
            let start = now.addingTimeInterval(minutes * 60 + Double(index) * 45 * 60)
            return AgendaEvent(
                id: "demo-\(index)",
                title: title,
                start: start,
                end: start.addingTimeInterval(30 * 60),
                isAllDay: false,
                location: index == 0 ? "Zoom" : nil,
                calendarTitle: "Demo",
                calendarColor: [.pink, .blue, .green, .orange][index % 4],
                hasVideoLink: index == 0,
                videoURL: nil
            )
        }
    }

    /// True when running against the fabricated demo agenda.
    var isDemo: Bool { demoEvents != nil }

    /// Whatever the rest of the app should treat as "the calendar".
    private var activeEvents: [AgendaEvent] { demoEvents ?? calendar.events }

    // MARK: Derived agenda

    /// The meeting you are currently sitting in, if any.
    var currentEvent: AgendaEvent? {
        activeEvents.first { $0.isInProgress(at: now) && !$0.isAllDay }
    }

    /// The next thing that hasn't started yet.
    var nextEvent: AgendaEvent? {
        activeEvents.first { $0.start > now }
    }

    /// Everything after the headline item, trimmed to the horizon.
    var upcoming: [AgendaEvent] {
        let horizonEnd = now.addingTimeInterval(prefs.horizonHours * 3600)
        let headline = currentEvent ?? nextEvent
        return activeEvents.filter { event in
            guard event.start <= horizonEnd else { return false }
            guard event.end > now else { return false }
            return event.id != headline?.id
        }
    }

    var headline: AgendaEvent? { currentEvent ?? nextEvent }

    /// True when there is genuinely nothing worth animating about.
    var isClear: Bool {
        urgency.phase == .clear
    }

    // MARK: Lifecycle

    func start() {
        // Demo mode never touches EventKit, so it never triggers a permission
        // prompt — you can show the app off on a machine that's never seen it.
        if !isDemo {
            Task { await calendar.requestAccessIfNeeded() }
        }
        observeSystemEvents()

        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        refreshTask = Task { @MainActor [weak self] in
            // Pull the accounts once at launch so we never start from a stale
            // database, then settle into the adaptive cadence.
            self?.calendar.pullRemoteSources(throttle: 0, force: true)
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.cadence.poll))
                guard !Task.isCancelled else { return }
                self.calendar.pullRemoteSources(throttle: self.cadence.remote)
                self.calendar.refresh()
                self.tick()
                self.logHeartbeat()
            }
        }
    }

    /// A quiet calendar and a dead refresh loop look identical from the
    /// outside, so the loop says so every time it runs.
    private func logHeartbeat() {
        let age = calendar.lastRemotePull.map { Int(Date().timeIntervalSince($0)) } ?? -1
        let phase = String(describing: urgency.phase)
        let count = calendar.events.count
        Log.calendar.info("poll: \(count, privacy: .public) events, phase \(phase, privacy: .public), account sync \(age, privacy: .public)s ago")
    }

    /// How hard to work at staying current, based on how close the next thing
    /// is. Sitting idle at 5-second remote pulls all day would be rude to both
    /// the battery and the calendar servers; being lazy in the last five minutes
    /// before a meeting is exactly when it matters most.
    ///
    /// `poll` re-reads the local database. `remote` is the floor between asking
    /// EventKit to sync the accounts, which is the expensive one.
    private var cadence: (poll: TimeInterval, remote: TimeInterval) {
        switch urgency.phase {
        case .critical, .starting: return (5, 15)
        case .imminent: return (8, 20)
        case .approaching: return (12, 30)
        case .inProgress: return (20, 45)
        case .distant, .clear: return (20, 45)
        }
    }

    func stop() {
        clockTask?.cancel()
        refreshTask?.cancel()
    }

    func tick() {
        now = Date()
        urgency = Urgency.evaluate(next: nextEvent, current: currentEvent, now: now, prefs: prefs)
    }

    /// Preferences that change what we fetch (calendars, horizon, filters)
    /// need a re-read, not just a re-evaluation.
    func reloadFromPreferences() {
        calendar.refresh()
        tick()
    }

    /// Everything the user can do that should produce an instant answer:
    /// "Refresh Now", waking the machine, coming back to the app. Skips every
    /// throttle and goes all the way out to the accounts.
    func refreshNow(reason: String) {
        Log.calendar.info("forced refresh: \(reason, privacy: .public)")
        calendar.invalidateCache()
        calendar.pullRemoteSources(throttle: 0, force: true)
        calendar.refresh()
        tick()
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default

        // The database changed underneath us — usually a sync landing. Drop
        // EventKit's cached objects before re-reading or we may be handed the
        // same stale events back.
        center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.calendar.info("EKEventStoreChanged")
                self?.calendar.invalidateCache()
                self?.calendar.refresh()
                self?.tick()
            }
        }

        // Laptop lids close, sessions get switched, clocks jump, days roll over.
        // Each one can leave us showing something that isn't true any more.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshNow(reason: name.rawValue)
                }
            }
        }

        for name in [NSApplication.didBecomeActiveNotification,
                     .NSSystemClockDidChange,
                     .NSCalendarDayChanged] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshNow(reason: name.rawValue)
                }
            }
        }
    }
}
