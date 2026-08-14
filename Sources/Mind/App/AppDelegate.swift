import AppKit
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
