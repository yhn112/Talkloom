import os

/// Logging entry points for the app.
///
/// This is a menu-bar app with no console, so the unified log is the only way to observe
/// it. Stream it with:
///
///     log stream --predicate 'subsystem == "me.diskin.Transcriber"' --level debug
///
enum AppLog {
    static let subsystem = "me.diskin.Transcriber"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let capture = Logger(subsystem: subsystem, category: "capture")
}
