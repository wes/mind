import AppKit

/// A tiny indirection so deeply nested views can ask for app-level things
/// without being handed a reference to the delegate.
@MainActor
enum AppActions {
    static var openPreferences: () -> Void = {}
    static var hidePanel: () -> Void = {}
    static var refresh: () -> Void = {}

    static func openCalendarPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
