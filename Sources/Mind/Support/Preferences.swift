import Foundation
import Observation

/// Every user-tunable knob in Mind, persisted to `UserDefaults`.
///
/// This is deliberately a single flat object: the app is small, and having one
/// observable source of truth means the panel, the scene and the menu bar item
/// all react to a change the moment the preference window writes it.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let store = UserDefaults.standard

    // MARK: Window behaviour

    var floatOnTop: Bool { didSet { write(floatOnTop, .floatOnTop) } }
    var showOnAllSpaces: Bool { didSet { write(showOnAllSpaces, .showOnAllSpaces) } }
    var clickThrough: Bool { didSet { write(clickThrough, .clickThrough) } }
    var opacity: Double { didSet { write(opacity, .opacity) } }
    var hideWhenClear: Bool { didSet { write(hideWhenClear, .hideWhenClear) } }
    var showMenuBarItem: Bool { didSet { write(showMenuBarItem, .showMenuBarItem) } }
    var menuBarShowsCountdown: Bool { didSet { write(menuBarShowsCountdown, .menuBarShowsCountdown) } }

    // MARK: Timing (all in minutes)

    /// How far ahead we look for events at all.
    var horizonHours: Double { didSet { write(horizonHours, .horizonHours) } }
    /// Above this, the scene is essentially asleep.
    var calmMinutes: Double { didSet { write(calmMinutes, .calmMinutes) } }
    /// The scene wakes up and starts moving.
    var alertMinutes: Double { didSet { write(alertMinutes, .alertMinutes) } }
    /// Fireworks. Get up.
    var criticalMinutes: Double { didSet { write(criticalMinutes, .criticalMinutes) } }

    // MARK: Event filtering

    var includeAllDay: Bool { didSet { write(includeAllDay, .includeAllDay) } }
    var ignoreDeclined: Bool { didSet { write(ignoreDeclined, .ignoreDeclined) } }
    var minimumDurationMinutes: Double { didSet { write(minimumDurationMinutes, .minimumDurationMinutes) } }
    /// Calendar identifiers the user has switched off. Absence means "included".
    var excludedCalendarIDs: Set<String> { didSet { write(Array(excludedCalendarIDs), .excludedCalendarIDs) } }

    // MARK: Appearance

    var paletteID: String { didSet { write(paletteID, .paletteID) } }
    var showAgenda: Bool { didSet { write(showAgenda, .showAgenda) } }
    var use24HourClock: Bool { didSet { write(use24HourClock, .use24HourClock) } }
    var showSeconds: Bool { didSet { write(showSeconds, .showSeconds) } }

    // MARK: Motion

    /// 0 = sparse and still, 1 = a lot going on.
    var density: Double { didSet { write(density, .density) } }
    var toastersEnabled: Bool { didSet { write(toastersEnabled, .toastersEnabled) } }
    var fireworksEnabled: Bool { didSet { write(fireworksEnabled, .fireworksEnabled) } }
    var reduceMotion: Bool { didSet { write(reduceMotion, .reduceMotion) } }
    var shakeEnabled: Bool { didSet { write(shakeEnabled, .shakeEnabled) } }

    private init() {
        store.register(defaults: [
            Key.floatOnTop.rawValue: true,
            Key.showOnAllSpaces.rawValue: true,
            Key.clickThrough.rawValue: false,
            Key.opacity.rawValue: 1.0,
            Key.hideWhenClear.rawValue: false,
            Key.showMenuBarItem.rawValue: true,
            Key.menuBarShowsCountdown.rawValue: true,
            Key.horizonHours.rawValue: 10.0,
            Key.calmMinutes.rawValue: 60.0,
            Key.alertMinutes.rawValue: 15.0,
            Key.criticalMinutes.rawValue: 2.0,
            Key.includeAllDay.rawValue: false,
            Key.ignoreDeclined.rawValue: true,
            Key.minimumDurationMinutes.rawValue: 0.0,
            Key.excludedCalendarIDs.rawValue: [String](),
            Key.paletteID.rawValue: Palette.cotton.id,
            Key.showAgenda.rawValue: true,
            Key.use24HourClock.rawValue: false,
            Key.showSeconds.rawValue: true,
            Key.density.rawValue: 0.55,
            Key.toastersEnabled.rawValue: true,
            Key.fireworksEnabled.rawValue: true,
            Key.reduceMotion.rawValue: false,
            Key.shakeEnabled.rawValue: true,
        ])

        floatOnTop = store.bool(forKey: Key.floatOnTop.rawValue)
        showOnAllSpaces = store.bool(forKey: Key.showOnAllSpaces.rawValue)
        clickThrough = store.bool(forKey: Key.clickThrough.rawValue)
        opacity = store.double(forKey: Key.opacity.rawValue)
        hideWhenClear = store.bool(forKey: Key.hideWhenClear.rawValue)
        showMenuBarItem = store.bool(forKey: Key.showMenuBarItem.rawValue)
        menuBarShowsCountdown = store.bool(forKey: Key.menuBarShowsCountdown.rawValue)
        horizonHours = store.double(forKey: Key.horizonHours.rawValue)
        calmMinutes = store.double(forKey: Key.calmMinutes.rawValue)
        alertMinutes = store.double(forKey: Key.alertMinutes.rawValue)
        criticalMinutes = store.double(forKey: Key.criticalMinutes.rawValue)
        includeAllDay = store.bool(forKey: Key.includeAllDay.rawValue)
        ignoreDeclined = store.bool(forKey: Key.ignoreDeclined.rawValue)
        minimumDurationMinutes = store.double(forKey: Key.minimumDurationMinutes.rawValue)
        excludedCalendarIDs = Set(store.stringArray(forKey: Key.excludedCalendarIDs.rawValue) ?? [])
        paletteID = store.string(forKey: Key.paletteID.rawValue) ?? Palette.cotton.id
        showAgenda = store.bool(forKey: Key.showAgenda.rawValue)
        use24HourClock = store.bool(forKey: Key.use24HourClock.rawValue)
        showSeconds = store.bool(forKey: Key.showSeconds.rawValue)
        density = store.double(forKey: Key.density.rawValue)
        toastersEnabled = store.bool(forKey: Key.toastersEnabled.rawValue)
        fireworksEnabled = store.bool(forKey: Key.fireworksEnabled.rawValue)
        reduceMotion = store.bool(forKey: Key.reduceMotion.rawValue)
        shakeEnabled = store.bool(forKey: Key.shakeEnabled.rawValue)
    }

    var palette: Palette { Palette.palette(id: paletteID) }

    func isCalendarEnabled(_ identifier: String) -> Bool {
        !excludedCalendarIDs.contains(identifier)
    }

    func setCalendar(_ identifier: String, enabled: Bool) {
        if enabled {
            excludedCalendarIDs.remove(identifier)
        } else {
            excludedCalendarIDs.insert(identifier)
        }
    }

    /// Thresholds are only meaningful if they stay ordered; the preference UI
    /// nudges its neighbours through here rather than validating in the view.
    func setThresholds(calm: Double? = nil, alert: Double? = nil, critical: Double? = nil) {
        if let calm { calmMinutes = max(calm, alertMinutes + 1) }
        if let alert { alertMinutes = min(max(alert, criticalMinutes + 1), calmMinutes - 1) }
        if let critical { criticalMinutes = min(max(critical, 0.5), alertMinutes - 1) }
    }

    func resetToDefaults() {
        for key in Key.allCases { store.removeObject(forKey: key.rawValue) }
        floatOnTop = true
        showOnAllSpaces = true
        clickThrough = false
        opacity = 1.0
        hideWhenClear = false
        showMenuBarItem = true
        menuBarShowsCountdown = true
        horizonHours = 10
        calmMinutes = 60
        alertMinutes = 15
        criticalMinutes = 2
        includeAllDay = false
        ignoreDeclined = true
        minimumDurationMinutes = 0
        excludedCalendarIDs = []
        paletteID = Palette.cotton.id
        showAgenda = true
        use24HourClock = false
        showSeconds = true
        density = 0.55
        toastersEnabled = true
        fireworksEnabled = true
        reduceMotion = false
        shakeEnabled = true
    }

    private func write(_ value: Any, _ key: Key) {
        store.set(value, forKey: key.rawValue)
    }

    private enum Key: String, CaseIterable {
        case floatOnTop, showOnAllSpaces, clickThrough, opacity, hideWhenClear
        case showMenuBarItem, menuBarShowsCountdown
        case horizonHours, calmMinutes, alertMinutes, criticalMinutes
        case includeAllDay, ignoreDeclined, minimumDurationMinutes, excludedCalendarIDs
        case paletteID, showAgenda, use24HourClock, showSeconds
        case density, toastersEnabled, fireworksEnabled, reduceMotion, shakeEnabled
    }
}
