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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.calendar.refresh()
                self?.tick()
            }
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

    private func observeSystemEvents() {
        let center = NotificationCenter.default

        center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.calendar.refresh()
                self?.tick()
            }
        }

        // Laptop lids close. Come back with fresh data rather than a stale count.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.calendar.refresh()
                self?.tick()
            }
        }

        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.calendar.refresh()
                self?.tick()
            }
        }
    }
}
