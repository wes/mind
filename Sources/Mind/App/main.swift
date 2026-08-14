import AppKit

// Hand-rolled entry point rather than `@main` on a SwiftUI `App`: Mind's
// primary window is a borderless floating NSPanel, which is far easier to
// configure when AppKit owns the lifecycle.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
