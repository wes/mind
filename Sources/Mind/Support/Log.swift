import OSLog

/// Watch what Mind is doing with:
///
///     log stream --predicate 'subsystem == "com.joedesigns.mind"' --level debug
///
/// Refresh behaviour is the one part of this app that is invisible when it goes
/// wrong, so it says what it did and when.
enum Log {
    static let calendar = Logger(subsystem: "com.joedesigns.mind", category: "calendar")
}
