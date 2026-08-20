import EventKit
import Foundation
import Observation
import SwiftUI

/// Read-only bridge to the user's calendars.
///
/// Mind never mutates anything: it asks EventKit for events in a window that
/// starts a few minutes in the past and ends at the user's horizon, and that is
/// the entire extent of its relationship with your calendar.
@MainActor
@Observable
final class CalendarService {
    struct CalendarInfo: Identifiable, Hashable {
        let id: String
        let title: String
        let sourceTitle: String
        let color: Color
    }

    enum Access: Equatable {
        case unknown
        case granted
        case denied
        case restricted
        /// Calendar access is structurally impossible for this build — no app
        /// bundle, or no usage description. Asking would be pointless.
        case unavailable(String)

        var isUsable: Bool { self == .granted }
    }

    private(set) var access: Access = .unknown
    private(set) var events: [AgendaEvent] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var lastRefresh: Date?
    /// When we last asked EventKit to go and talk to the remote accounts.
    private(set) var lastRemotePull: Date?
    private(set) var lastError: String?

    /// Recreated on a full sync. A long-lived store can keep serving stale
    /// data even after reset(), and a brand new one appears to be the only
    /// thing that reliably shakes an account loose — which is why "it only
    /// updates when I rebuild" was such an accurate description of the bug.
    private var store = EKEventStore()
    private let prefs: Preferences

    init(prefs: Preferences = .shared) {
        self.prefs = prefs
        self.access = Self.currentAccess()
    }

    // MARK: Authorization

    /// macOS will not grant calendar access to a bare executable: it needs a
    /// bundle identifier to hang the permission on and a usage description to
    /// show in the prompt. Running `.build/.../Mind` directly instead of
    /// `dist/Mind.app` therefore fails silently, which is worse than failing
    /// loudly — hence this check.
    static func environmentProblem() -> String? {
        guard Bundle.main.bundleIdentifier != nil else {
            return "Running as a bare binary instead of an app bundle. macOS only grants calendar access to a bundled, signed app — use ./build.sh --run and launch dist/Mind.app."
        }
        let keys = ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"]
        guard keys.contains(where: { Bundle.main.object(forInfoDictionaryKey: $0) != nil }) else {
            return "This build's Info.plist has no calendar usage description, so macOS will never prompt for access."
        }
        return nil
    }

    private static func currentAccess() -> Access {
        if let problem = environmentProblem() { return .unavailable(problem) }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .writeOnly: return .denied  // we need to read; write-only is useless here
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Prompts for access if we've never asked. Safe to call repeatedly.
    func requestAccessIfNeeded() async {
        access = Self.currentAccess()
        if case .unavailable(let problem) = access {
            Log.calendar.error("calendar access impossible: \(problem, privacy: .public)")
            return
        }
        guard access == .unknown else {
            if access == .granted { refresh() }
            return
        }
        Log.calendar.info("requesting calendar access")
        do {
            let granted = try await store.requestFullAccessToEvents()
            access = granted ? .granted : .denied
            lastError = nil
        } catch {
            access = Self.currentAccess()
            lastError = error.localizedDescription
        }
        if access == .granted { refresh() }
    }

    // MARK: Reading

    /// Ask EventKit to sync the remote accounts.
    ///
    /// This is the difference between "fresh" and "whatever macOS last felt
    /// like fetching". `EKEventStore` reads a *local* database; when you move an
    /// event on your phone or in a web UI, that database doesn't change until
    /// CalendarAgent syncs, which on its own schedule can be many minutes. Every
    /// poll in the world won't see a change that hasn't landed locally yet.
    ///
    /// EventKit rate-limits this internally, and we throttle on top of it so a
    /// tight countdown loop doesn't hammer the accounts.
    func pullRemoteSources(throttle: TimeInterval, force: Bool = false) {
        guard access == .granted else { return }
        let now = Date()
        if !force, let last = lastRemotePull, now.timeIntervalSince(last) < throttle {
            return
        }
        lastRemotePull = now
        Log.calendar.info("asking EventKit to sync the accounts (forced: \(force, privacy: .public))")
        store.refreshSourcesIfNecessary()
    }

    /// Drops EventKit's cached objects so the next fetch re-reads the database.
    /// Called when we've been told something changed underneath us.
    func invalidateCache() {
        store.reset()
    }

    /// Throws the whole store away and starts again.
    func rebuildStore() {
        store = EKEventStore()
    }

    /// A full sync, and the important part: it *waits*.
    ///
    /// `refreshSourcesIfNecessary()` returns immediately and syncs in the
    /// background, so reading straight afterwards gives you exactly the stale
    /// data you were trying to get rid of. This kicks off the sync and then
    /// keeps re-reading — through a fresh store each time — until the agenda
    /// changes or we run out of patience.
    ///
    /// Returns true if anything actually changed.
    @discardableResult
    func fullSync(timeout: TimeInterval = 15) async -> Bool {
        guard access == .granted else { return false }
        let before = events
        Log.calendar.info("full sync: starting")

        rebuildStore()
        lastRemotePull = Date()
        store.refreshSourcesIfNecessary()
        refresh()
        if events != before {
            Log.calendar.info("full sync: changed immediately")
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        var attempts = 0
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(900))
            attempts += 1
            rebuildStore()
            store.refreshSourcesIfNecessary()
            refresh()
            if events != before {
                Log.calendar.info("full sync: changed after \(attempts, privacy: .public) attempts")
                return true
            }
        }
        Log.calendar.info("full sync: no changes after \(attempts, privacy: .public) attempts")
        return false
    }

    func refresh() {
        access = Self.currentAccess()
        guard access == .granted else {
            events = []
            calendars = []
            return
        }

        // Reset before every read, not just when we're told something changed.
        //
        // A long-lived EKEventStore hands back a cached snapshot, and the
        // change notification is not reliable enough to be the only thing that
        // clears it: if it doesn't arrive, the store happily serves the same
        // stale events forever, which looks exactly like "the app only notices
        // new events when you restart it". reset() just drops cached objects,
        // so the cost is re-reading a local database we were reading anyway.
        store.reset()

        let eventCalendars = store.calendars(for: .event)
        calendars = eventCalendars
            .map {
                CalendarInfo(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source?.title ?? "",
                    color: Self.color(for: $0)
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }

        let included = eventCalendars.filter { prefs.isCalendarEnabled($0.calendarIdentifier) }
        guard !included.isEmpty else {
            events = []
            lastRefresh = Date()
            return
        }

        let now = Date()
        // Reach slightly into the past so an in-progress meeting is still found.
        let start = now.addingTimeInterval(-6 * 3600)
        let end = now.addingTimeInterval(max(prefs.horizonHours, 1) * 3600 + 3600)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: included)

        let raw: [EKEvent] = store.events(matching: predicate)
        let kept: [EKEvent] = raw.filter { keep($0, now: now) }
        var fetched: [AgendaEvent] = kept.map { Self.makeAgendaEvent($0) }
        fetched.sort { lhs, rhs in
            lhs.start == rhs.start ? lhs.title < rhs.title : lhs.start < rhs.start
        }

        // Only log when something actually moved, so the stream stays readable
        // while still proving the loop is alive.
        if fetched != events {
            Log.calendar.info("agenda changed: \(fetched.count, privacy: .public) events in horizon")
            for event in fetched.prefix(5) {
                Log.calendar.debug("  \(event.start, privacy: .public) \(event.title, privacy: .private)")
            }
        }
        events = fetched
        lastRefresh = now
    }

    /// Every event EventKit hands back for the horizon window — across *all*
    /// calendars, not just the included ones — with the reason Mind did or
    /// didn't keep it.
    ///
    /// The counts in the diagnostics can tell you the agenda is empty; only
    /// this can tell you why, which is the question you actually have when an
    /// event you can plainly see in Calendar.app isn't on screen.
    func auditWindow() -> [String] {
        guard access == .granted else { return ["access is \(access), nothing to audit"] }
        store.reset()

        let now = Date()
        let start = now.addingTimeInterval(-6 * 3600)
        let end = now.addingTimeInterval(max(prefs.horizonHours, 1) * 3600 + 3600)
        let all = store.calendars(for: .event)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: all)

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"

        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let title = event.title ?? "(untitled)"
                let calendar = event.calendar?.title ?? "(no calendar)"
                let when = "\(formatter.string(from: event.startDate))–\(formatter.string(from: event.endDate))"
                return "    \(when)  \(title)  [\(calendar)]  → \(verdict(for: event, now: now))"
            }
    }

    /// Why `refresh()` would or wouldn't show this event. Mirrors the order of
    /// the calendar filter and `keep()`.
    private func verdict(for event: EKEvent, now: Date) -> String {
        if let id = event.calendar?.calendarIdentifier, !prefs.isCalendarEnabled(id) {
            return "DROPPED: calendar switched off"
        }
        if event.status == .canceled { return "DROPPED: cancelled" }
        if event.isAllDay && !prefs.includeAllDay { return "DROPPED: all-day, and all-day events are off" }
        if event.endDate <= now { return "DROPPED: already ended" }
        if prefs.ignoreDeclined, let attendees = event.attendees {
            for attendee in attendees where attendee.isCurrentUser {
                if attendee.participantStatus == .declined { return "DROPPED: you declined it" }
            }
        }
        if !event.isAllDay, prefs.minimumDurationMinutes > 0 {
            let minutes = event.endDate.timeIntervalSince(event.startDate) / 60
            if minutes < prefs.minimumDurationMinutes {
                return "DROPPED: \(Int(minutes))m is under the \(Int(prefs.minimumDurationMinutes))m minimum"
            }
        }
        return "kept"
    }

    /// Event counts per calendar over a wide window, which answers a different
    /// question from `auditWindow()`: not "why was this event dropped" but
    /// "is this account syncing at all".
    ///
    /// A calendar that is present in the list yet returns nothing over a whole
    /// fortnight is almost never an empty calendar — it is an account whose
    /// events haven't landed in the local database, which is invisible from
    /// the horizon window alone.
    func auditAccounts(days: Double = 7) -> [String] {
        guard access == .granted else { return ["access is \(access), nothing to audit"] }
        store.reset()

        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-days * 86_400),
            end: now.addingTimeInterval(days * 86_400),
            calendars: store.calendars(for: .event)
        )

        var counts: [String: Int] = [:]
        for event in store.events(matching: predicate) {
            let key = "\(event.calendar?.source?.title ?? "?") / \(event.calendar?.title ?? "?")"
            counts[key, default: 0] += 1
        }

        return store.calendars(for: .event)
            .map { calendar in
                let key = "\(calendar.source?.title ?? "?") / \(calendar.title)"
                let count = counts[key] ?? 0
                let flag = count == 0 ? "  <- nothing in ±\(Int(days))d" : ""
                return "    \(count) events  \(key)\(flag)"
            }
            .sorted()
    }

    private func keep(_ event: EKEvent, now: Date) -> Bool {
        if event.status == .canceled { return false }
        if event.isAllDay && !prefs.includeAllDay { return false }
        if event.endDate <= now { return false }

        if prefs.ignoreDeclined, let attendees = event.attendees {
            for attendee in attendees where attendee.isCurrentUser {
                if attendee.participantStatus == .declined { return false }
            }
        }

        if !event.isAllDay, prefs.minimumDurationMinutes > 0 {
            let minutes = event.endDate.timeIntervalSince(event.startDate) / 60
            if minutes < prefs.minimumDurationMinutes { return false }
        }
        return true
    }

    private static func makeAgendaEvent(_ event: EKEvent) -> AgendaEvent {
        let link = videoLink(in: event)
        let trimmedTitle = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AgendaEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: trimmedTitle.isEmpty ? "Untitled event" : trimmedTitle,
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            calendarTitle: event.calendar?.title ?? "",
            calendarColor: color(for: event.calendar),
            hasVideoLink: link != nil,
            videoURL: link
        )
    }

    private static func color(for calendar: EKCalendar?) -> Color {
        guard let cg = calendar?.cgColor else { return .accentColor }
        return Color(cgColor: cg)
    }

    /// Best-effort "can I click one button and be in the meeting" detection.
    private static func videoLink(in event: EKEvent) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                     "webex.com", "whereby.com", "chime.aws", "gotomeeting.com", "bluejeans.com"]

        func match(_ text: String?) -> URL? {
            guard let text, !text.isEmpty else { return nil }
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector?.matches(in: text, range: range) ?? []
            for m in matches {
                guard let url = m.url, let host = url.host?.lowercased() else { continue }
                if hosts.contains(where: { host.hasSuffix($0) }) { return url }
            }
            return nil
        }

        if let url = event.url, let host = url.host?.lowercased(),
           hosts.contains(where: { host.hasSuffix($0) }) {
            return url
        }
        return match(event.location) ?? match(event.notes)
    }
}
