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
    }

    private(set) var access: Access = .unknown
    private(set) var events: [AgendaEvent] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var lastRefresh: Date?
    private(set) var lastError: String?

    private let store = EKEventStore()
    private let prefs: Preferences

    init(prefs: Preferences = .shared) {
        self.prefs = prefs
        self.access = Self.currentAccess()
    }

    // MARK: Authorization

    private static func currentAccess() -> Access {
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
        guard access == .unknown else {
            if access == .granted { refresh() }
            return
        }
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

    func refresh() {
        access = Self.currentAccess()
        guard access == .granted else {
            events = []
            calendars = []
            return
        }

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

        let raw = store.events(matching: predicate)
        events = raw
            .filter { keep($0, now: now) }
            .map { Self.makeAgendaEvent($0) }
            .sorted { lhs, rhs in
                lhs.start == rhs.start ? lhs.title < rhs.title : lhs.start < rhs.start
            }
        lastRefresh = now
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
