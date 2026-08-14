import AppKit
import SwiftUI

/// A borderless, always-available panel that hosts the ambient view.
///
/// Borderless (rather than a titled window) so the corners can be fully round
/// and the whole surface can be drag-to-move; resizing is handled by our own
/// grip in the bottom-right corner, which also lets us clamp to a sane range.
final class AmbientPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    static private(set) var current: PanelController?

    let panel: AmbientPanel
    private let prefs: Preferences
    private let state: AppState

    static let minSize = CGSize(width: 168, height: 84)
    static let maxSize = CGSize(width: 900, height: 900)

    init(state: AppState, prefs: Preferences) {
        self.state = state
        self.prefs = prefs

        let initial = NSRect(x: 0, y: 0, width: 320, height: 190)
        panel = AmbientPanel(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.setFrameAutosaveName("MindAmbientPanel")

        let root = AmbientView()
            .environment(state)
            .environment(prefs)

        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = initial
        panel.contentView = hosting

        applyPreferences()
        if panel.frame.width < Self.minSize.width || panel.frame.height < Self.minSize.height {
            panel.setContentSize(initial.size)
        }
        positionIfUnplaced()
        PanelController.current = self
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func toggleVisibility() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Mirrors the window-related preferences onto the live panel.
    func applyPreferences() {
        panel.level = prefs.floatOnTop ? .floating : .normal
        panel.collectionBehavior = prefs.showOnAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = prefs.clickThrough
        panel.alphaValue = max(0.15, min(1, prefs.opacity))
    }

    /// While the corner grip is in use, drag-to-move has to stand down or the
    /// window would try to move and resize at the same time.
    func beginResize() { panel.isMovableByWindowBackground = false }
    func endResize() { panel.isMovableByWindowBackground = true }

    /// Called by the drag grip in the corner. Keeps the top-left pinned so the
    /// panel grows the way the pointer expects.
    func resize(to size: CGSize) {
        let clamped = CGSize(
            width: min(max(size.width, Self.minSize.width), Self.maxSize.width),
            height: min(max(size.height, Self.minSize.height), Self.maxSize.height)
        )
        var frame = panel.frame
        let top = frame.maxY
        frame.size = clamped
        frame.origin.y = top - clamped.height
        panel.setFrame(frame, display: true)
    }

    var currentSize: CGSize { panel.frame.size }

    func applyPreset(_ preset: SizePreset) {
        resize(to: preset.size)
    }

    /// First launch: tuck into the top-right corner of the main screen.
    private func positionIfUnplaced() {
        guard UserDefaults.standard.object(forKey: "NSWindow Frame MindAmbientPanel") == nil else { return }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}

enum SizePreset: String, CaseIterable, Identifiable {
    case micro, small, medium, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .micro: return "Micro"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var size: CGSize {
        switch self {
        case .micro: return CGSize(width: 200, height: 92)
        case .small: return CGSize(width: 280, height: 150)
        case .medium: return CGSize(width: 360, height: 260)
        case .large: return CGSize(width: 460, height: 420)
        }
    }
}
