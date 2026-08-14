import AppKit
import SwiftUI

/// The whole visible app: a gradient, a particle canvas, and just enough text.
struct AmbientView: View {
    @Environment(AppState.self) private var state
    @Environment(Preferences.self) private var prefs

    @State private var scene = SceneModel()
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let layout = AmbientLayout(size: geo.size)
            let palette = prefs.palette
            let intensity = state.urgency.intensity

            ZStack {
                backdrop(palette: palette, intensity: intensity)
                canvas(palette: palette)
                content(layout: layout, palette: palette)
                controls(layout: layout, palette: palette)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                    .strokeBorder(palette.ink(intensity).opacity(0.16), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
            .onHover { isHovering = $0 }
            .contextMenu { PanelContextMenu() }
        }
        .ignoresSafeArea()
    }

    // MARK: Layers

    private func backdrop(palette: Palette, intensity: Double) -> some View {
        let colors = palette.background(intensity)
        // The "breath": a slow swell that quickens as a meeting approaches.
        return TimelineView(.animation(minimumInterval: 1.0 / 20, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let rate = lerp(0.28, 2.2, intensity)
            let breath = (sin(t * rate) + 1) / 2

            LinearGradient(
                colors: [colors.top, colors.bottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                RadialGradient(
                    colors: [
                        palette.accent(1, intensity: intensity).lightened(0.4)
                            .color(opacity: 0.10 + 0.28 * intensity * breath),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 320
                )
            )
        }
    }

    private func canvas(palette: Palette) -> some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: false)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                scene.advance(time: time, size: size, urgency: state.urgency, prefs: prefs)
                scene.draw(context: context, size: size, palette: palette, prefs: prefs, time: time)
            }
        }
        .allowsHitTesting(false)
    }

    /// Throttle the render loop when nothing is happening — an ambient app has
    /// no business burning a core to draw two clouds.
    private var frameInterval: Double? {
        if prefs.reduceMotion { return 1.0 / 24 }
        if state.urgency.intensity < 0.12 { return 1.0 / 30 }
        return nil
    }

    @ViewBuilder
    private func content(layout: AmbientLayout, palette: Palette) -> some View {
        if state.isDemo || state.calendar.access == .granted || state.calendar.access == .unknown {
            AgendaOverlay(layout: layout, palette: palette)
        } else {
            PermissionView(layout: layout, palette: palette)
        }
    }

    @ViewBuilder
    private func controls(layout: AmbientLayout, palette: Palette) -> some View {
        if isHovering && !prefs.clickThrough {
            VStack {
                HStack(spacing: 6) {
                    Spacer()
                    ControlButton(symbol: "gearshape.fill", tint: palette.ink(state.urgency.intensity)) {
                        AppActions.openPreferences()
                    }
                    ControlButton(symbol: "xmark", tint: palette.ink(state.urgency.intensity)) {
                        AppActions.hidePanel()
                    }
                }
                Spacer()
                HStack {
                    Spacer()
                    ResizeGrip(tint: palette.ink(state.urgency.intensity))
                }
            }
            .padding(layout.tier == .micro ? 4 : 7)
            .transition(.opacity)
        }
    }
}

// MARK: - Overlay content

private struct AgendaOverlay: View {
    @Environment(AppState.self) private var state
    @Environment(Preferences.self) private var prefs

    let layout: AmbientLayout
    let palette: Palette

    private var hasAgenda: Bool {
        layout.agendaRows > 0 && prefs.showAgenda && !state.upcoming.isEmpty
    }

    var body: some View {
        let intensity = state.urgency.intensity
        let ink = palette.ink(intensity)
        let event = state.headline

        VStack(alignment: .leading, spacing: layout.stackSpacing) {
            header(ink: ink, event: event)

            if let event {
                Text(event.title)
                    .font(.system(size: layout.titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                    .lineLimit(layout.tier == .micro ? 1 : 2)
                    .minimumScaleFactor(0.7)
                    .legible(halo: palette.halo(intensity))

                countdown(event: event, ink: ink)

                if layout.showsDetail, let detail = detailLine(for: event) {
                    Text(detail)
                        .font(.system(size: layout.captionSize, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.75))
                        .lineLimit(1)
                        .legible(halo: palette.halo(intensity))
                }
            } else {
                Text(Copy.restfulHeadline(for: state.now))
                    .font(.system(size: layout.titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.85))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .legible(halo: palette.halo(intensity))
                if layout.showsDetail {
                    Text("Nothing in the next \(Int(prefs.horizonHours)) hours")
                        .font(.system(size: layout.captionSize, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.6))
                        .lineLimit(1)
                }
            }

            if layout.showsFuse && state.urgency.phase >= .approaching {
                FuseBar(intensity: intensity, palette: palette)
                    .frame(height: layout.fuseHeight)
                    .padding(.top, 1)
            }

            if hasAgenda {
                UpcomingList(
                    events: Array(state.upcoming.prefix(layout.agendaRows)),
                    layout: layout,
                    ink: ink,
                    now: state.now,
                    use24Hour: prefs.use24HourClock
                )
                .padding(.top, 2)
            }

            if hasAgenda { Spacer(minLength: 0) }
        }
        .padding(.horizontal, layout.padding)
        .padding(.vertical, layout.padding * 0.85)
        // One genuinely useful click: if the event has a video link, join it.
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = state.headline?.videoURL { AppActions.open(url) }
        }
        // With an agenda the block hangs from the top; without one it centres,
        // so a short panel never looks like it has a hole in the bottom half.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hasAgenda ? .topLeading : .leading)
    }

    @ViewBuilder
    private func header(ink: Color, event: AgendaEvent?) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(event?.calendarColor ?? ink.opacity(0.4))
                .frame(width: layout.dotSize, height: layout.dotSize)
                .shadow(color: (event?.calendarColor ?? .clear).opacity(0.6), radius: 3)
            Text(phaseLabel)
                .font(.system(size: layout.labelSize, weight: .bold, design: .rounded))
                .tracking(layout.tier == .micro ? 0.4 : 1.1)
                .foregroundStyle(ink.opacity(0.72))
                .legible(halo: palette.halo(state.urgency.intensity))
            Spacer(minLength: 0)
            if layout.showsDetail, let event, !event.isAllDay {
                Text(Copy.clock(event.start, use24Hour: prefs.use24HourClock))
                    .font(.system(size: layout.labelSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.68))
                    .monospacedDigit()
                    .legible(halo: palette.halo(state.urgency.intensity))
            }
        }
    }

    @ViewBuilder
    private func countdown(event: AgendaEvent, ink: Color) -> some View {
        let urgency = state.urgency
        let text: String = {
            switch urgency.phase {
            case .starting: return "NOW"
            case .inProgress:
                let remaining = urgency.secondsUntilEnd ?? 0
                return Copy.countdown(remaining, showSeconds: false) + " left"
            default:
                return Copy.countdown(urgency.secondsUntilStart ?? 0, showSeconds: prefs.showSeconds)
            }
        }()

        Text(text)
            .font(.system(size: layout.countdownSize, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .legible(halo: palette.halo(state.urgency.intensity), strength: 2)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.35), value: text)
    }

    private var phaseLabel: String {
        switch state.urgency.phase {
        case .clear: return "CLEAR"
        case .distant: return "NEXT"
        case .approaching: return "NEXT"
        case .imminent: return "SOON"
        case .critical: return "ALMOST"
        case .starting: return "STARTING"
        case .inProgress: return "IN PROGRESS"
        }
    }

    private func detailLine(for event: AgendaEvent) -> String? {
        var parts: [String] = [Copy.range(event, use24Hour: prefs.use24HourClock)]
        if let day = Copy.relativeDay(event.start, now: state.now) { parts.insert(day, at: 0) }
        if event.hasVideoLink {
            parts.append("Video")
        } else if let location = event.location, !location.isEmpty {
            parts.append(Copy.shortTitle(location, limit: 22))
        }
        return parts.joined(separator: " · ")
    }
}

/// Rows of what's after the headline item.
private struct UpcomingList: View {
    let events: [AgendaEvent]
    let layout: AmbientLayout
    let ink: Color
    let now: Date
    let use24Hour: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: layout.rowSpacing) {
            ForEach(events) { event in
                HStack(spacing: 6) {
                    Capsule()
                        .fill(event.calendarColor)
                        .frame(width: 2.5, height: layout.rowSize * 1.15)
                    Text(Copy.clock(event.start, use24Hour: use24Hour))
                        .font(.system(size: layout.rowSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ink.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: layout.rowSize * (use24Hour ? 3.0 : 4.6), alignment: .leading)
                    Text(event.title)
                        .font(.system(size: layout.rowSize, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.55))
        )
    }
}

/// A slow-burning fuse: fills as the meeting closes in.
private struct FuseBar: View {
    let intensity: Double
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.ink(intensity).opacity(0.14))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                palette.accent(3, intensity: intensity).color(),
                                palette.accent(0, intensity: intensity).lightened(0.2).color(),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, geo.size.width * clamp01(intensity)))
                    .animation(.easeOut(duration: 0.8), value: intensity)
            }
        }
    }
}

private struct PermissionView: View {
    @Environment(AppState.self) private var state
    let layout: AmbientLayout
    let palette: Palette

    var body: some View {
        let ink = palette.ink(0.2)
        VStack(alignment: .leading, spacing: 6) {
            Text("Calendar access needed")
                .font(.system(size: layout.titleSize * 0.85, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if layout.showsDetail {
                Text("Mind only ever reads your calendar.")
                    .font(.system(size: layout.captionSize, weight: .medium, design: .rounded))
                    .foregroundStyle(ink.opacity(0.7))
                    .lineLimit(2)
            }
            Button("Open Privacy Settings") {
                AppActions.openCalendarPrivacySettings()
            }
            .buttonStyle(.borderless)
            .font(.system(size: layout.captionSize, weight: .semibold, design: .rounded))
            .foregroundStyle(ink)
        }
        .padding(layout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Chrome

private struct ControlButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(.ultraThinMaterial.opacity(hovering ? 0.9 : 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Drag to resize. Borderless panels don't get system resize edges, so we do
/// it ourselves — which also lets the panel stay pinned by its top-left.
private struct ResizeGrip: View {
    let tint: Color
    @State private var startSize: CGSize?
    @State private var pushedCursor = false

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(tint.opacity(0.55))
            .frame(width: 16, height: 16)
            .background(Circle().fill(.ultraThinMaterial.opacity(0.5)))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard let controller = PanelController.current else { return }
                        let base = startSize ?? controller.currentSize
                        if startSize == nil {
                            startSize = base
                            controller.beginResize()
                        }
                        controller.resize(to: CGSize(
                            width: base.width + value.translation.width,
                            height: base.height + value.translation.height
                        ))
                    }
                    .onEnded { _ in
                        startSize = nil
                        PanelController.current?.endResize()
                    }
            )
            .onHover { inside in
                // Push/pop have to be balanced or the cursor sticks.
                if inside, !pushedCursor {
                    pushedCursor = true
                    NSCursor.crosshair.push()
                } else if !inside, pushedCursor {
                    pushedCursor = false
                    NSCursor.pop()
                }
            }
    }
}

private struct PanelContextMenu: View {
    var body: some View {
        ForEach(SizePreset.allCases) { preset in
            Button(preset.title) { PanelController.current?.applyPreset(preset) }
        }
        Divider()
        Button("Preferences…") { AppActions.openPreferences() }
        Button("Hide Mind") { AppActions.hidePanel() }
        Divider()
        Button("Quit Mind") { NSApp.terminate(nil) }
    }
}

/// Text sitting on top of a moving scene needs a halo, not a drop shadow:
/// a soft disc of the background colour that keeps letterforms readable when a
/// toaster passes behind them.
private extension View {
    func legible(halo: Color, strength: Int = 1) -> some View {
        var view = AnyView(self)
        for _ in 0..<max(1, strength) {
            view = AnyView(view.shadow(color: halo, radius: 4))
        }
        return view.shadow(color: halo.opacity(0.5), radius: 9)
    }
}
