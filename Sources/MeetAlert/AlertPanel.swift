import AppKit
import SwiftUI

/// A borderless nonactivating NSPanel can never become key by default, which silently kills the
/// Return-key shortcut on its Dismiss button. Overriding canBecomeKey fixes that WITHOUT calling
/// makeKey/makeKeyAndOrderFront ourselves — no focus stealing, no activating the app. Return only
/// starts working once the user has already clicked into the panel.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Per-panel presentational state the view observes. `escalated` is flipped by Store's escalation
/// loop (see `AlertPanel.escalated(key:)`); `isKey` drives the keyboard-hint row.
@MainActor @Observable final class PanelState {
    var escalated = false
}

/// Floating, non-activating panel that stays up until the user acts on it.
/// Multiple panels stack vertically; dismissing one closes the gap for the ones below it.
@MainActor
enum AlertPanel {
    private static var active: [(key: String, panel: NSPanel, state: PanelState, appearance: AlertAppearance)] = []
    private static let gap: CGFloat = 10
    private static let margin: CGFloat = 12

    static func show(_ m: Store.Meeting, alertKey: String, appearance: AlertAppearance = AlertAppearance(),
                      preview: Bool = false,
                      onAck: @escaping () -> Void,
                      onSnooze: @escaping (Int) -> Void,
                      onSnoozeStart: @escaping () -> Void,
                      onIgnore: @escaping () -> Void) {
        if let existing = active.first(where: { $0.key == alertKey }) {
            existing.panel.orderFrontRegardless()  // already showing (e.g. re-tick) — don't stack a duplicate
            return
        }
        // No screen at all (e.g. woke from sleep with displays not yet re-attached) — the alertKey
        // is already marked fired, so dropping the panel here would lose the alert for good. Retry
        // instead of un-marking anything; it self-heals once a display shows up.
        guard let screen = screenUnderMouse() else {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                show(m, alertKey: alertKey, appearance: appearance, preview: preview, onAck: onAck, onSnooze: onSnooze, onSnoozeStart: onSnoozeStart, onIgnore: onIgnore)
            }
            return
        }
        let panel = makePanel()
        let state = PanelState()
        func closeThen(_ action: @escaping () -> Void) {
            dismiss(panel)
            action()
        }

        let onJoin: (() -> Void)? = m.joinURL.map { url in { closeThen {
            if !preview { NSWorkspace.shared.open(url) }
            onAck()
        } } }

        panel.contentView = NSHostingView(rootView: AlertContent(
            meeting: m,
            state: state,
            onJoin: onJoin,
            onSnooze1: { closeThen { onSnooze(1) } },
            onSnooze5: { closeThen { onSnooze(5) } },
            onSnoozeStart: { closeThen(onSnoozeStart) },
            onIgnore: { closeThen(onIgnore) },
            onDismiss: { closeThen(onAck) },
            appearance: appearance
        ))
        fit(panel, appearance: appearance, screen: screen)
        active.append((alertKey, panel, state, appearance))
        let final = frame(forIndex: active.count - 1, screen: screen)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.setFrame(AlertPlacement.entranceFrame(final: final, screen: screen.frame,
                                                   slideFromTop: appearance.slideFromTop, reduceMotion: reduce), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.12 : appearance.slideFromTop ? 0.4 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }

        guard !preview else { return }  // sample data only: no sound or meeting announcement

        // The panel never takes VoiceOver focus (non-activating, app never active): speak it (A11Y-6).
        let when = m.start <= Date() ? "started" : "starts at \(m.start.formatted(date: .omitted, time: .shortened))"
        AccessibilityNotification.Announcement("Meeting alert: \(m.title), \(when)").post()

        // Rising fanfare for an alert that is already late, the familiar Funk for one still ahead.
        NSSound(named: m.start <= Date() ? "Hero" : "Funk")?.play()
    }

    /// Closes the panel for `key` if one is open — e.g. an ACK or snooze that arrived via the phone
    /// push, which previously stopped escalation but left the desktop panel sitting there forever.
    static func dismiss(key: String) {
        guard let idx = active.firstIndex(where: { $0.key == key }) else { return }
        remove(at: idx)
    }

    /// Escalation reached the phone and the alert is still unacknowledged — say so on the desktop
    /// panel too (pulsing rim, state word, one more sound) instead of leaving it looking untouched.
    static func escalated(key: String) {
        guard let entry = active.first(where: { $0.key == key }), !entry.state.escalated else { return }
        entry.state.escalated = true
        if let screen = screenUnderMouse() {
            fit(entry.panel, appearance: entry.appearance, screen: screen)
            reflow()
        }
        NSSound(named: "Sosumi")?.play()
    }

    private static func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 168),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false  // Swift owns it via `active`; avoid AppKit double-release on close()
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private static func dismiss(_ panel: NSPanel) {
        guard let idx = active.firstIndex(where: { $0.panel == panel }) else { return }
        remove(at: idx)
    }

    private static func remove(at idx: Int) {
        let panel = active[idx].panel
        active.remove(at: idx)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // close, not orderOut: a hidden panel keeps its TimelineView/pulse rendering forever (CPU leak)
            panel.contentView = nil
            panel.close()
            Task { @MainActor in reflow() }
        })
    }

    // ponytail: reflow repositions ALL currently-open panels onto whichever screen has the mouse
    // right now — correct for the common case (one alert at a time), but if several panels are
    // stacked across different screens and the mouse has since moved, a dismiss can jump the
    // survivors to the new screen. Upgrade to a per-panel screen if that turns out to matter.
    private static func reflow() {
        guard let screen = screenUnderMouse() else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (i, entry) in active.enumerated() {
                fit(entry.panel, appearance: entry.appearance, screen: screen)
                entry.panel.animator().setFrame(frame(forIndex: i, screen: screen), display: true)
            }
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Preserve each panel's fitted size when stacking; extra panels overlap at the bottom.
    private static func frame(forIndex index: Int, screen: NSScreen) -> NSRect {
        let size = active[index].panel.frame.size
        let preceding = active.prefix(index).reduce(CGFloat(0)) { $0 + $1.panel.frame.height + gap }
        return AlertPlacement.frame(size: size, screen: screen.frame, visible: screen.visibleFrame,
                                    appearance: active[index].appearance, precedingHeight: preceding)
    }

    private static func fit(_ panel: NSPanel, appearance: AlertAppearance, screen: NSScreen) {
        guard let host = panel.contentView as? NSHostingView<AlertContent> else { return }
        host.rootView.appearance = appearance.normalized
        let area = appearance.topEdge ? screen.frame : screen.visibleFrame
        host.rootView.availableWidth = area.width - 2 * margin
        let first = active.isEmpty || active.first?.panel === panel
        host.rootView.dockedToTop = first && appearance.topEdge && appearance.offsetY == 0
        host.rootView.topInset = first && appearance.topEdge
            ? max(0, screen.safeAreaInsets.top - CGFloat(appearance.normalized.offsetY)) : 0
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
    }

    static func updateAppearance(_ appearance: AlertAppearance) {
        guard let screen = screenUnderMouse() else { return }
        for index in active.indices {
            active[index].appearance = appearance
            fit(active[index].panel, appearance: appearance, screen: screen)
        }
        reflow()
    }

    /// The preview exercises the real panel, but cannot send a push, open a link, or alter a meeting.
    static func showPreview(appearance: AlertAppearance, secondsUntilStart: Int = 180) {
        let key = "appearance-preview"
        dismiss(key: key)
        let start = Date().addingTimeInterval(Double(secondsUntilStart))
        let meeting = Store.Meeting(key: key, title: "Design review — sample meeting", start: start,
                                    end: start.addingTimeInterval(1800), hasPhysicalLocation: false,
                                    joinURL: URL(string: "https://meet.google.com/example"), seriesId: nil,
                                    calendarTitle: "Preview", calendarColor: .systemBlue)
        show(meeting, alertKey: key, appearance: appearance, preview: true,
             onAck: {}, onSnooze: { _ in }, onSnoozeStart: {}, onIgnore: {})
    }

}

/// How close the meeting is — drives hue, icon, state word and the numeral's unit together, so
/// urgency is never carried by colour alone.
private enum Urgency {
    case upcoming, imminent, started

    var signal: Color {
        switch self {
        case .upcoming: Theme.calm
        case .imminent: Theme.imminent
        case .started: Theme.started
        }
    }

    var symbol: String {
        switch self {
        case .upcoming: "clock"
        case .imminent: "clock.badge.exclamationmark"
        case .started: "exclamationmark.circle.fill"
        }
    }

    var word: String { self == .started ? "Started" : "Starting in" }
}

struct AlertContent: View {
    let meeting: Store.Meeting
    let state: PanelState
    let onJoin: (() -> Void)?
    let onSnooze1: () -> Void
    let onSnooze5: () -> Void
    let onSnoozeStart: () -> Void
    let onIgnore: () -> Void
    let onDismiss: () -> Void
    var appearance = AlertAppearance()
    var availableWidth: CGFloat? = nil
    var dockedToTop = false
    var topInset: CGFloat = 0

    private var options: AlertAppearance { appearance.normalized }
    private var scale: CGFloat { options.scale }
    private var panelWidth: CGFloat { min(CGFloat(options.width), availableWidth ?? .infinity) }
    private var usesPalette: Bool { options.customColors || options.theme == .retro }
    private var customBackground: NSColor {
        if options.customColors { return NSColor(hex: options.background) ?? .white }
        return options.theme == .retro ? NSColor(srgbRed: 0.9, green: 0.9, blue: 0.88, alpha: 1) : .white
    }
    private var foreground: Color { usesPalette ? Color(nsColor: customBackground.contrastingText) : .primary }
    private var secondary: Color { usesPalette ? foreground : .secondary }
    private var typeDesign: Font.Design { options.theme.squareCorners ? .monospaced : .default }
    private var titleWeight: Font.Weight { options.theme == .blocky ? .black : .semibold }

    private func signal(_ urgency: Urgency) -> Color {
        guard usesPalette else { return urgency.signal }
        let hex = urgency == .upcoming ? options.upcoming : urgency == .imminent ? options.imminent : options.started
        return Color(nsColor: (NSColor(hex: hex) ?? .black).readable(on: customBackground))
    }

    private func buttonStyle(_ urgency: Urgency, prominent: Bool = false) -> SignalButtonStyle {
        let signal = options.theme == .retro && !options.customColors ? foreground : signal(urgency)
        return SignalButtonStyle(signal: signal, prominent: prominent, scale: scale, foreground: foreground,
                                 onSignal: usesPalette ? Color(nsColor: NSColor(signal).contrastingText) : Theme.onSignal,
                                 customColors: usesPalette, theme: options.theme)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @State private var pulsing = false

    var body: some View {
        // ponytail: one tick a second regardless of distance — a single panel, negligible cost.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let remaining = meeting.start.timeIntervalSince(ctx.date)
            card(urgency: remaining > 60 ? .upcoming : remaining > 0 ? .imminent : .started, remaining: remaining)
        }
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(urgency: Urgency, remaining: TimeInterval) -> some View {
        let numbers = countdown(remaining)
        return VStack(alignment: .leading, spacing: 0) {
            if options.theme == .retro { retroTitleBar.padding(.bottom, 10 * scale) }
            if panelWidth < 600 && scale > 1.25 {
                // At large text sizes, give the title and metadata the full card width.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        stateRow(urgency)
                        Spacer(minLength: 8)
                        countdownView(numbers, urgency: urgency)
                    }
                    title
                    metaRow
                }
            } else {
                HStack(alignment: .top, spacing: 16 * scale) {
                    VStack(alignment: .leading, spacing: 5) {
                        stateRow(urgency)
                        title
                        metaRow
                    }
                    Spacer(minLength: 0)
                    countdownView(numbers, urgency: urgency)
                }
            }
            Spacer(minLength: 10 * scale)
            actions(urgency)
        }
        .padding(18)
        .foregroundStyle(foreground)
        .padding(.leading, options.theme == .original ? 6 : 0)  // clear the signal rim
        .padding(.top, topInset)
        .frame(width: panelWidth, alignment: .topLeading)
        .frame(minHeight: CGFloat(options.height), alignment: .topLeading)
        .background(background(urgency))
    }

    private var title: some View {
        Text(meeting.title).font(.system(size: 17 * scale, weight: titleWeight, design: typeDesign)).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true).help(meeting.title)
    }

    private func countdownView(_ numbers: (big: String, unit: String), urgency: Urgency) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(numbers.big)
                .font(.system(size: 40 * scale, weight: options.theme == .blocky ? .black : .semibold,
                              design: options.theme.squareCorners ? .monospaced : .rounded).monospacedDigit())
                .foregroundStyle(signal(urgency))
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                .animation(.snappy, value: numbers.big)
            Text(numbers.unit).font(.system(size: 12 * scale, weight: .medium, design: typeDesign)).foregroundStyle(secondary)
        }
        .frame(minWidth: 96 * scale, alignment: .trailing)
    }

    private func stateRow(_ urgency: Urgency) -> some View {
        HStack(spacing: 5) {
            Image(systemName: state.escalated ? "bell.and.waves.left.and.right.fill" : urgency.symbol)
                .font(.system(size: 12 * scale, weight: .semibold))
            Text(state.escalated ? "Not acknowledged — phone alerted" : urgency.word)
                .font(.system(size: 12 * scale, weight: .semibold, design: options.theme.squareCorners ? .monospaced : .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(signal(urgency))
    }

    private var metaRow: some View {
        AlertFlowLayout(spacing: 8 * scale) {
            Text("\(meeting.start.formatted(date: .omitted, time: .shortened))–\(meeting.end.formatted(date: .omitted, time: .shortened))")
            if let color = meeting.calendarColor, !meeting.calendarTitle.isEmpty {
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: color)).frame(width: 8, height: 8)
                    Text(meeting.calendarTitle).font(.system(size: 12 * scale, weight: .medium, design: typeDesign)).lineLimit(1)
                }
            }
            if let url = meeting.joinURL {
                Label(Ntfy.provider(for: url), systemImage: "video.fill")
            } else if meeting.hasPhysicalLocation {
                Label("In person", systemImage: "figure.walk")
            }
        }
        .font(.system(size: 13 * scale, weight: options.theme == .blocky ? .semibold : .regular, design: typeDesign))
        .foregroundStyle(secondary)
    }

    private var retroTitleBar: some View {
        HStack(spacing: 10) {
            retroStripes
            Text("MeetAlert").font(.system(size: 12 * scale, weight: .bold, design: .monospaced))
            retroStripes
        }
        .foregroundStyle(foreground)
        .accessibilityHidden(true)  // decorative chrome; no fake window controls
    }

    private var retroStripes: some View {
        VStack(spacing: 2) {
            ForEach(0..<5) { _ in Rectangle().fill(foreground).frame(height: 1) }
        }
    }

    private func actions(_ urgency: Urgency) -> some View {
        AlertFlowLayout(spacing: 8 * scale) {
            if options.showJoin, let onJoin, let url = meeting.joinURL {
                Button(action: onJoin) {
                    Label("Join \(Ntfy.provider(for: url))", systemImage: "video.fill")
                }
                .buttonStyle(buttonStyle(urgency, prominent: true))
                .keyboardShortcut(.defaultAction)
                .help("Join the meeting (Return)")
            }
            if options.showSnooze {
                Button("Snooze 5 Min", action: onSnooze5)
                    .buttonStyle(buttonStyle(urgency))
                    .keyboardShortcut("5", modifiers: [])
                    .help("Snooze 5 minutes (5 or Esc)")
            }
            if options.showDismiss {
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(buttonStyle(urgency, prominent: onJoin == nil || !options.showJoin))
                    .keyboardShortcut("d", modifiers: .command)
                    .help("Done with this meeting, no more alerts (⌘D)")
            }
            if options.showIgnore {
                Button(meeting.seriesId != nil ? "Ignore Series" : "Ignore", action: onIgnore)
                    .buttonStyle(buttonStyle(urgency))
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .help("Never alert for this again (⌘⇧I)")
            }
            // Hidden buttons move here. No configuration can remove the way to dismiss or snooze.
            Menu("More") {
                if let onJoin {
                    Button("Join Meeting", action: onJoin).keyboardShortcut("j", modifiers: [])
                }
                if !options.showSnooze {
                    Button("Snooze 5 Minutes", action: onSnooze5).keyboardShortcut("5", modifiers: [])
                }
                if !options.showDismiss {
                    Button("Dismiss", action: onDismiss).keyboardShortcut("d", modifiers: .command)
                }
                if !options.showIgnore {
                    Button(meeting.seriesId != nil ? "Ignore Series" : "Ignore", action: onIgnore)
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                }
                Button("Snooze 1 Minute", action: onSnooze1).keyboardShortcut("1", modifiers: [])
                if meeting.start > Date() {
                    Button("Snooze Until Start (\(meeting.start.formatted(date: .omitted, time: .shortened)))",
                           action: onSnoozeStart).keyboardShortcut("t", modifiers: [])
                }
            }
            .menuStyle(.button)
            .buttonStyle(buttonStyle(urgency))
            .fixedSize()
            .help("More meeting actions")
        }
        .background {
            if !options.showJoin, let onJoin {
                Button("", action: onJoin).keyboardShortcut(.defaultAction).opacity(0).frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            // Escape remains a reversible snooze even when its button is in More.
            Button("", action: onSnooze5).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func background(_ urgency: Urgency) -> some View {
        let radius: CGFloat = options.theme.squareCorners ? 0 : Theme.panelRadius
        let shape = UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: dockedToTop ? 0 : radius, bottomLeading: radius,
            bottomTrailing: radius, topTrailing: dockedToTop ? 0 : radius), style: .continuous)
        let signal = signal(urgency)
        let wide = state.escalated || urgency == .started
        let solid = options.translucency == 0 || reduceTransparency || contrast == .increased
        let tint = usesPalette ? Color(nsColor: customBackground)
            : scheme == .dark ? Color(red: 0.05, green: 0.07, blue: 0.13) : .white
        let amount = Double(100 - options.translucency) / 100
        return ZStack(alignment: .leading) {
            if solid {
                shape.fill(usesPalette ? Color(nsColor: customBackground) : Color(nsColor: .windowBackgroundColor))
            } else {
                if !usesPalette && options.translucency == 55 {
                    // Preserve the original theme at its default setting.
                    shape.fill(.regularMaterial)
                    shape.fill(Theme.ink)
                } else {
                    AlertGlassBackground(dark: usesPalette
                        ? customBackground.contrastingText.hexString == "#FFFFFF" : scheme == .dark)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    shape.fill(tint.opacity(amount))
                }
                if scheme == .dark && !usesPalette && !options.theme.squareCorners {
                    shape.fill(RadialGradient(colors: [signal.opacity(0.18), .clear],
                                              center: .topLeading, startRadius: 0, endRadius: 340))
                }
            }
            if options.theme == .original {
                Rectangle()
                    .fill(signal)
                    .frame(width: wide ? 6 : Theme.rimWidth)
                    .opacity(pulsing ? 0.5 : 1)
                    .animation(state.escalated && !reduceMotion
                               ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default,
                               value: pulsing)
            }
        }
        .clipShape(shape)
        .overlay {
            if options.theme == .bold || options.theme == .blocky {
                shape.strokeBorder(signal, lineWidth: wide ? 6 : 4)
                    .opacity(pulsing ? 0.65 : 1)
                    .animation(state.escalated && !reduceMotion
                               ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: pulsing)
            } else if options.theme == .retro {
                shape.strokeBorder(foreground, lineWidth: 2)
                shape.inset(by: 4).strokeBorder(foreground.opacity(0.45), lineWidth: 1)
            } else {
                shape.strokeBorder(contrast == .increased ? AnyShapeStyle(foreground) : AnyShapeStyle(signal.opacity(0.55)),
                                   lineWidth: contrast == .increased ? 2 : Theme.strokeWidth)
            }
        }
        .onChange(of: state.escalated) { _, escalated in
            pulsing = escalated && !reduceMotion
        }
    }

    private func countdown(_ remaining: TimeInterval) -> (big: String, unit: String) {
        if remaining > 60 { return ("\(Int(ceil(remaining / 60)))", "min") }
        if remaining > 0 { return ("\(Int(ceil(remaining)))", "sec") }
        let late = -remaining
        return late < 60 ? ("now", "") : ("+\(Int(late / 60))", "min late")
    }
}

/// One button look for the whole panel: capsule, hover highlight, press shrink. `prominent` fills
/// with the urgency hue (exactly one per panel); the rest are quiet outlines in the same hue.
/// Custom on purpose: this app is never active and the panel is not key until clicked, so system
/// `.borderedProminent` buttons would render in their gray inactive look and lose the signal hue.
private struct SignalButtonStyle: ButtonStyle {
    var signal: Color
    var prominent = false
    var scale: CGFloat = 1
    var foreground: Color = .primary
    var onSignal: Color = Theme.onSignal
    var customColors = false
    var theme: AlertAppearance.Preset = .original

    func makeBody(configuration: Configuration) -> some View {
        SignalButtonBody(cfg: configuration, signal: signal, prominent: prominent, scale: scale, foreground: foreground, onSignal: onSignal, customColors: customColors, theme: theme)
    }

    private struct SignalButtonBody: View {
        let cfg: Configuration
        let signal: Color
        let prominent: Bool
        let scale: CGFloat
        let foreground: Color
        let onSignal: Color
        let customColors: Bool
        let theme: AlertAppearance.Preset
        @State private var hover = false
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: theme.squareCorners ? 0 : 16 * scale)
            cfg.label
                .font(.system(size: 13 * scale, weight: theme == .blocky ? .heavy : .semibold,
                              design: theme.squareCorners ? .monospaced : .default))
                .padding(.horizontal, 14 * scale)
                .frame(height: 32 * scale)
                .foregroundStyle(prominent ? AnyShapeStyle(onSignal) : AnyShapeStyle(foreground))
                .background(
                    shape
                        .fill(prominent ? AnyShapeStyle(signal) : AnyShapeStyle(foreground.opacity(customColors ? 0 : hover ? 0.14 : 0.08)))
                        .overlay(shape.strokeBorder(
                            theme == .retro ? AnyShapeStyle(foreground)
                                : prominent ? AnyShapeStyle(.clear)
                                : contrast == .increased ? AnyShapeStyle(foreground) : AnyShapeStyle(signal.opacity(hover ? 0.7 : 0.35)),
                            lineWidth: theme == .blocky ? 2 : contrast == .increased ? 1.5 : 1))
                        .overlay(alignment: .top) {
                            if theme == .retro {
                                Rectangle().fill((prominent ? onSignal : foreground).opacity(0.3))
                                    .frame(height: 1).padding(3)
                            }
                        }
                        .shadow(color: theme == .retro ? foreground.opacity(0.65) : .clear,
                                radius: 0, x: cfg.isPressed ? 0 : 2, y: cfg.isPressed ? 0 : 2)
                )
                // Keep custom text and fills opaque so hover preserves the calculated contrast.
                .opacity(!customColors && prominent && hover ? 0.92 : 1)
                .scaleEffect(cfg.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
        }
    }
}

/// Native behind-window blur. Only the background is translucent; controls remain fully opaque.
private struct AlertGlassBackground: NSViewRepresentable {
    var dark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}
