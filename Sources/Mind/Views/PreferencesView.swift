import AppKit
import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var state
    @Environment(Preferences.self) private var prefs

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            CalendarsTab().tabItem { Label("Calendars", systemImage: "calendar") }
            TimingTab().tabItem { Label("Timing", systemImage: "hourglass") }
            AppearanceTab().tabItem { Label("Appearance", systemImage: "paintpalette") }
            MotionTab().tabItem { Label("Motion", systemImage: "sparkles") }
        }
        .frame(width: 620, height: 540)
        .environment(state)
        .environment(prefs)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(Preferences.self) private var prefs
    @State private var loginError: String?

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Panel") {
                Toggle("Float above other windows", isOn: $prefs.floatOnTop)
                Toggle("Show on every Space", isOn: $prefs.showOnAllSpaces)
                Toggle("Click through (ignore the mouse)", isOn: $prefs.clickThrough)
                Toggle("Hide when nothing is scheduled", isOn: $prefs.hideWhenClear)
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $prefs.opacity, in: 0.2...1.0) {
                        Text("Opacity")
                    } minimumValueLabel: {
                        Text("20%").font(.caption2)
                    } maximumValueLabel: {
                        Text("100%").font(.caption2)
                    }
                    Text("\(Int(prefs.opacity * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Size") {
                HStack {
                    ForEach(SizePreset.allCases) { preset in
                        Button(preset.title) {
                            PanelController.current?.applyPreset(preset)
                            PanelController.current?.show()
                        }
                    }
                }
                Text("You can also drag the grip in the panel's bottom-right corner, or right-click the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle("Show menu bar item", isOn: $prefs.showMenuBarItem)
                Toggle("Show countdown in menu bar", isOn: $prefs.menuBarShowsCountdown)
                    .disabled(!prefs.showMenuBarItem)
            }

            Section("Startup") {
                Toggle("Open Mind at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { setLoginItem($0) }
                ))
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            // Unsigned/ad-hoc builds and apps outside /Applications often fail here.
            loginError = "Couldn't update login item: \(error.localizedDescription)"
        }
    }
}

// MARK: - Calendars

private struct CalendarsTab: View {
    @Environment(AppState.self) private var state
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Form {
            Section {
                switch state.calendar.access {
                case .granted:
                    Label("Mind can read your calendars", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                case .unknown:
                    Label("Waiting for permission", systemImage: "clock")
                case .denied, .restricted:
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Calendar access is off", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Open Privacy Settings") { AppActions.openCalendarPrivacySettings() }
                    }
                }
                Text("Mind reads events only. It never creates, edits, or deletes anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Watch these calendars") {
                if state.calendar.calendars.isEmpty {
                    Text("No calendars found.").foregroundStyle(.secondary)
                }
                ForEach(state.calendar.calendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { prefs.isCalendarEnabled(calendar.id) },
                        set: { prefs.setCalendar(calendar.id, enabled: $0) }
                    )) {
                        HStack(spacing: 8) {
                            Circle().fill(calendar.color).frame(width: 9, height: 9)
                            Text(calendar.title)
                            if !calendar.sourceTitle.isEmpty {
                                Text(calendar.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Refresh Now") { AppActions.refresh() }
                if let last = state.calendar.lastRefresh {
                    Text("Last read \(Copy.clock(last, use24Hour: prefs.use24HourClock))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Timing

private struct TimingTab: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("How far ahead to look") {
                Slider(value: $prefs.horizonHours, in: 1...24, step: 1)
                Text("Showing anything in the next \(Int(prefs.horizonHours)) hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("When the scene reacts") {
                threshold(
                    title: "Wake up",
                    value: Binding(get: { prefs.calmMinutes }, set: { prefs.setThresholds(calm: $0) }),
                    range: 15...240,
                    caption: "Clouds part and toasters start crossing the sky."
                )
                threshold(
                    title: "Get busy",
                    value: Binding(get: { prefs.alertMinutes }, set: { prefs.setThresholds(alert: $0) }),
                    range: 2...90,
                    caption: "The flock thickens, embers rise, colours warm up."
                )
                threshold(
                    title: "Panic",
                    value: Binding(get: { prefs.criticalMinutes }, set: { prefs.setThresholds(critical: $0) }),
                    range: 0.5...30,
                    caption: "Fireworks, shockwaves, and a shake you can't miss."
                )
            }

            Section("Which events count") {
                Toggle("Include all-day events", isOn: $prefs.includeAllDay)
                Toggle("Skip events I've declined", isOn: $prefs.ignoreDeclined)
                VStack(alignment: .leading) {
                    Slider(value: $prefs.minimumDurationMinutes, in: 0...60, step: 5)
                    Text(prefs.minimumDurationMinutes < 1
                         ? "Counting events of any length."
                         : "Ignoring anything shorter than \(Int(prefs.minimumDurationMinutes)) minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Reset all settings") { prefs.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func threshold(title: String, value: Binding<Double>, range: ClosedRange<Double>, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) min before")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 1)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Palette") {
                ForEach(Palette.all) { palette in
                    Button {
                        prefs.paletteID = palette.id
                    } label: {
                        HStack(spacing: 10) {
                            PaletteSwatch(palette: palette)
                            Text(palette.name)
                            Spacer()
                            if prefs.paletteID == palette.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Text") {
                Toggle("Show upcoming schedule when there's room", isOn: $prefs.showAgenda)
                Toggle("24-hour clock", isOn: $prefs.use24HourClock)
                Toggle("Count down seconds in the final minutes", isOn: $prefs.showSeconds)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PaletteSwatch: View {
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            palette.calmTop.color()
            palette.calmBottom.color()
            palette.hotTop.color()
            palette.hotBottom.color()
        }
        .frame(width: 74, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.primary.opacity(0.12))
        )
    }
}

// MARK: - Motion

private struct MotionTab: View {
    @Environment(Preferences.self) private var prefs
    @State private var previewIntensity: Double = 0.25

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Preview") {
                ScenePreview(intensity: previewIntensity, palette: prefs.palette)
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $previewIntensity, in: 0...1)
                    Text(previewCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Scene") {
                Toggle("Flying toasters", isOn: $prefs.toastersEnabled)
                Toggle("Fireworks near the deadline", isOn: $prefs.fireworksEnabled)
                Toggle("Shake at the last moment", isOn: $prefs.shakeEnabled)
                Toggle("Reduce motion", isOn: $prefs.reduceMotion)
            }

            Section("Density") {
                Slider(value: $prefs.density, in: 0...1)
                Text("How much is in the sky at any moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var previewCaption: String {
        switch previewIntensity {
        case ..<0.2: return "Nothing coming up — barely moving."
        case ..<0.55: return "Something on the horizon."
        case ..<0.88: return "Getting close."
        default: return "Meeting is basically now."
        }
    }
}

/// A miniature of the real scene, driven by a slider instead of a calendar.
private struct ScenePreview: View {
    let intensity: Double
    let palette: Palette

    @State private var scene = SceneModel()
    @Environment(Preferences.self) private var prefs

    var body: some View {
        let urgency = Urgency(phase: phase, intensity: intensity, secondsUntilStart: nil, secondsUntilEnd: nil)
        ZStack {
            let colors = palette.background(intensity)
            LinearGradient(colors: [colors.top, colors.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            TimelineView(.animation) { timeline in
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    scene.advance(time: time, size: size, urgency: urgency, prefs: prefs)
                    scene.draw(context: context, size: size, palette: palette, prefs: prefs, time: time)
                }
            }
        }
    }

    private var phase: Phase {
        switch intensity {
        case ..<0.05: return .clear
        case ..<0.22: return .distant
        case ..<0.55: return .approaching
        case ..<0.88: return .imminent
        case ..<0.99: return .critical
        default: return .starting
        }
    }
}
