import AppKit
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private lazy var state = AppState(prefs: prefs)
    private var panelController: PanelController?
    private var preferencesWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusTask: Task<Void, Never>?
    private var preferenceWatchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-and-panel app: no Dock icon, no window restoration surprises.
        NSApp.setActivationPolicy(.accessory)

        // Troubleshooting hook: watch which EKEventStore flavour sees new events.
        if let watchPath = ProcessInfo.processInfo.environment["MIND_WATCH"] {
            Task { @MainActor in await StoreWatch.run(outputPath: watchPath) }
            return
        }

        // Troubleshooting hook: print what Mind can actually see, then quit.
        if ProcessInfo.processInfo.environment["MIND_DIAGNOSE"] != nil {
            Task { @MainActor in
                await Diagnostics.run(state: state, prefs: prefs)
                NSApp.terminate(nil)
            }
            return
        }

        // Development hook: render the artwork to PNGs and quit.
        if let shotsDirectory = ProcessInfo.processInfo.environment["MIND_SHOTS"] {
            Task { @MainActor in
                await ShotRenderer.run(outputDirectory: shotsDirectory)
                NSApp.terminate(nil)
            }
            return
        }

        // Two copies of an ambient panel is a debugging nightmare: they stack
        // pixel-on-pixel and you have no idea which one you're reading. If one
        // is already up, hand over to it and get out of the way.
        if let existing = otherRunningInstance() {
            Log.calendar.info("another Mind is already running (pid \(existing.processIdentifier, privacy: .public)); exiting")
            existing.activate()
            NSApp.terminate(nil)
            return
        }
        // A bare `swift build` binary has no bundle identifier, so the check
        // above can't see it — and that is precisely the copy most likely to be
        // stacked on top of the installed one during development. A file lock
        // catches every case, however the process was launched.
        guard Self.claimSingleInstanceLock() else {
            Log.calendar.info("another Mind already holds the instance lock; exiting")
            NSApp.terminate(nil)
            return
        }

        buildMainMenu()
        state.start()

        let controller = PanelController(state: state, prefs: prefs)
        panelController = controller
        controller.show()

        wireActions()
        configureStatusItem()
        watchPreferences()
        showPreferencesOnFirstLaunch()
    }

    /// Held for the lifetime of the process; released when it exits, including
    /// on a crash, because the kernel drops the flock with the descriptor.
    private static var instanceLockDescriptor: Int32 = -1

    private static func claimSingleInstanceLock() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        for hook in ["MIND_SHOTS", "MIND_WATCH", "MIND_DIAGNOSE"] where environment[hook] != nil {
            return true
        }
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("com.joedesigns.mind.instance.lock")
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }  // can't lock: don't block the user
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        instanceLockDescriptor = descriptor
        return true
    }

    /// The diagnostic hooks deliberately launch extra copies with `open -n`,
    /// so they opt out of the single-instance rule.
    private func otherRunningInstance() -> NSRunningApplication? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIND_SHOTS"] == nil,
              environment["MIND_WATCH"] == nil,
              environment["MIND_DIAGNOSE"] == nil,
              let identifier = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != me }
    }

    /// The very first time Mind runs, open Preferences: choosing which
    /// calendars to watch is the one setup step that actually matters.
    private func showPreferencesOnFirstLaunch() {
        let key = "hasLaunchedBefore"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { @MainActor [weak self] in
            // Let the calendar permission prompt land first.
            try? await Task.sleep(for: .seconds(2))
            self?.showPreferences()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTask?.cancel()
        preferenceWatchTask?.cancel()
        state.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Wiring

    private func wireActions() {
        AppActions.openPreferences = { [weak self] in self?.showPreferences() }
        AppActions.hidePanel = { [weak self] in self?.panelController?.panel.orderOut(nil) }
        AppActions.refresh = { [weak self] in self?.state.refreshNow(reason: "user asked") }
    }

    /// Preferences are plain observable state; rather than sprinkle callbacks
    /// through the settings UI, we poll the values that affect the window and
    /// the calendar query and apply them when they change.
    private func watchPreferences() {
        preferenceWatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastWindowSignature = self.windowSignature
            var lastQuerySignature = self.querySignature
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                let window = self.windowSignature
                if window != lastWindowSignature {
                    lastWindowSignature = window
                    self.panelController?.applyPreferences()
                }
                let query = self.querySignature
                if query != lastQuerySignature {
                    lastQuerySignature = query
                    self.state.reloadFromPreferences()
                }
                self.updateStatusItemVisibility()
                self.applyHideWhenClear()
            }
        }
    }

    private var windowSignature: String {
        "\(prefs.floatOnTop)-\(prefs.showOnAllSpaces)-\(prefs.clickThrough)-\(prefs.opacity)"
    }

    private var querySignature: String {
        "\(prefs.horizonHours)-\(prefs.includeAllDay)-\(prefs.ignoreDeclined)-"
        + "\(prefs.minimumDurationMinutes)-\(prefs.excludedCalendarIDs.sorted().joined(separator: ","))"
    }

    private func applyHideWhenClear() {
        guard let panel = panelController?.panel else { return }
        guard prefs.hideWhenClear else { return }
        let shouldHide = state.isClear && state.headline == nil
        if shouldHide, panel.isVisible {
            panel.orderOut(nil)
        } else if !shouldHide, !panel.isVisible {
            panel.alphaValue = max(0.15, min(1, prefs.opacity))
            panel.orderFrontRegardless()
        }
    }

    // MARK: Status item

    private func configureStatusItem() {
        updateStatusItemVisibility()
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateStatusItemTitle()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateStatusItemVisibility() {
        if prefs.showMenuBarItem, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: "Mind"
            )
            item.button?.imagePosition = .imageLeading
            item.menu = makeStatusMenu()
            statusItem = item
            updateStatusItemTitle()
        } else if !prefs.showMenuBarItem, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        guard prefs.menuBarShowsCountdown else {
            button.title = ""
            return
        }
        guard state.isDemo || state.calendar.access.isUsable else {
            button.title = " ⚠︎"
            button.toolTip = "Mind can't read your calendar — open Preferences → Calendars"
            return
        }
        let title = Copy.menuBarTitle(urgency: state.urgency, event: state.headline)
        button.title = " " + title
        button.toolTip = state.headline.map { "\($0.title) · \(Copy.range($0, use24Hour: prefs.use24HourClock))" }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide Mind", action: #selector(togglePanel), keyEquivalent: "")
            .target = self

        let sizeItem = NSMenuItem(title: "Panel Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for preset in SizePreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(applySize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "Preferences…", action: #selector(showPreferencesMenu), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Mind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func togglePanel() { panelController?.toggleVisibility() }
    @objc private func refreshNow() { state.refreshNow(reason: "menu bar") }
    @objc private func showPreferencesMenu() { showPreferences() }

    @objc private func applySize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = SizePreset(rawValue: raw) else { return }
        panelController?.applyPreset(preset)
        panelController?.show()
    }

    // MARK: Preferences window

    func showPreferences() {
        if preferencesWindow == nil {
            let view = PreferencesView()
                .environment(state)
                .environment(prefs)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Mind Preferences"
            window.contentView = NSHostingView(rootView: AnyView(view))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("MindPreferences")
            preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar (for keyboard shortcuts while active)

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mind", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferencesMenu), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mind", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Mind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Mind",
            .credits: NSAttributedString(
                string: "An ambient view of what's coming next.\nReads your calendar, never writes to it.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ])
    }
}
