import AppKit
import SwiftUI

struct AppearanceTab: View {
    @Bindable var store: Store
    @State private var previewSeconds = 180

    var body: some View {
        Form {
            Section {
                Picker("Preview state", selection: $previewSeconds) {
                    Text("Starting soon").tag(180)
                    Text("Less than a minute").tag(30)
                    Text("Started").tag(-120)
                }
                Button("Preview Alert") {
                    AlertPanel.showPreview(appearance: store.config.alertAppearance, secondsUntilStart: previewSeconds)
                }
            } header: {
                Text("Preview")
            } footer: {
                Text("Uses a sample meeting. Preview actions close the sample without opening a link, sending a notification or changing your meetings.").formFooter()
            }

            Section {
                Picker("Theme", selection: Binding(
                    get: { store.config.alertAppearance.theme },
                    set: {
                        var appearance = store.config.alertAppearance
                        appearance.apply($0)
                        store.config.alertAppearance = appearance
                    }
                )) {
                    ForEach(AlertAppearance.Preset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                Text(store.config.alertAppearance.theme.summary).font(.callout)
                dimension("Translucency", value: \AlertAppearance.translucency,
                          range: AlertAppearance.translucencyRange, step: 5, unit: "%")
            } header: {
                Text("Theme")
            } footer: {
                Text("Themes set decoration, type and translucency. Your size, buttons, colors and position stay as you set them. 0% is solid; higher values reveal more of the blurred desktop. Text stays opaque. Reduce Transparency and Increase Contrast use a solid background.").formFooter()
            }

            Section {
                Toggle("Use screen edge (over menu bar)", isOn: $store.config.alertAppearance.topEdge)
                position("Horizontal offset", value: \AlertAppearance.offsetX, range: AlertAppearance.offsetXRange)
                position("Distance from top", value: \AlertAppearance.offsetY, range: AlertAppearance.offsetYRange)
                Toggle("Slide in from top", isOn: $store.config.alertAppearance.slideFromTop)
                HStack {
                    Button("Dock to Top") {
                        var appearance = store.config.alertAppearance
                        appearance.topEdge = true
                        appearance.offsetX = 0
                        appearance.offsetY = 0
                        appearance.slideFromTop = true
                        store.config.alertAppearance = appearance
                    }
                    Button("Reset Position") {
                        var appearance = store.config.alertAppearance
                        appearance.topEdge = false
                        appearance.offsetX = 0
                        appearance.offsetY = 12
                        appearance.slideFromTop = false
                        store.config.alertAppearance = appearance
                    }
                }
            } header: {
                Text("Position & Motion")
            } footer: {
                Text("Horizontal offset is measured from the display’s center; negative moves left. Distance is measured down from the menu bar or screen edge. Dock to Top sits flush with the bezel and may cover the menu bar while visible. Content stays below the camera notch. Reduce Motion disables the slide.").formFooter()
            }

            Section {
                HStack {
                    Text("Size presets")
                    Spacer()
                    Button("Compact") { setSize(width: 480, height: 168, scale: 100) }
                    Button("Default") { setSize(width: 640, height: 168, scale: 100) }
                    Button("Large") { setSize(width: 800, height: 224, scale: 125) }
                }
                dimension("Width", value: \AlertAppearance.width, range: AlertAppearance.widthRange, step: 8, unit: "pt")
                dimension("Minimum height", value: \AlertAppearance.height, range: AlertAppearance.heightRange, step: 8, unit: "pt")
                dimension("Text and buttons", value: \AlertAppearance.textScale, range: AlertAppearance.textScaleRange, step: 5, unit: "%")
            } header: {
                Text("Popup Size")
            } footer: {
                Text("Buttons wrap and the popup grows taller when needed. Width fits the display. Changes apply to open alerts and the preview.").formFooter()
            }

            Section {
                Toggle("Join", isOn: $store.config.alertAppearance.showJoin)
                Toggle("Snooze 5 Minutes", isOn: $store.config.alertAppearance.showSnooze)
                Toggle("Dismiss", isOn: $store.config.alertAppearance.showDismiss)
                Toggle("Ignore / Ignore Series", isOn: $store.config.alertAppearance.showIgnore)
            } header: {
                Text("Buttons on the Popup")
            } footer: {
                Text("Hidden buttons remain in More. Keyboard shortcuts and phone notifications are unchanged; More always stays visible.").formFooter()
            }

            Section {
                Toggle("Use custom colors", isOn: $store.config.alertAppearance.customColors)
                if store.config.alertAppearance.customColors {
                    ColorPicker("Background", selection: color(\AlertAppearance.background), supportsOpacity: false)
                    ColorPicker("Starting soon", selection: color(\AlertAppearance.upcoming), supportsOpacity: false)
                    ColorPicker("Less than a minute", selection: color(\AlertAppearance.imminent), supportsOpacity: false)
                    ColorPicker("Started / late", selection: color(\AlertAppearance.started), supportsOpacity: false)
                }
            } header: {
                Text("Colors")
            } footer: {
                Text("Off uses the original colors for your Mac’s appearance. Custom colors adjust text contrast against your chosen background. Use 0% translucency for predictable contrast over any desktop. Urgency is still shown in words and icons.").formFooter()
            }

            Section {
                Button("Reset Appearance to Defaults") { store.config.alertAppearance = AlertAppearance() }
                    .disabled(store.config.alertAppearance == AlertAppearance())
            }
        }
        .formStyle(.grouped)
    }

    private func dimension(_ title: String, value key: WritableKeyPath<AlertAppearance, Int>,
                           range: ClosedRange<Int>, step: Double, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading).accessibilityHidden(true)
            Slider(value: Binding(
                get: { Double(store.config.alertAppearance[keyPath: key]) },
                set: { store.config.alertAppearance[keyPath: key] = Int($0) }
            ), in: Double(range.lowerBound)...Double(range.upperBound), step: step)
                .accessibilityLabel(title)
                .accessibilityValue("\(store.config.alertAppearance[keyPath: key]) \(unit)")
            Text("\(store.config.alertAppearance[keyPath: key]) \(unit)")
                .monospacedDigit().frame(width: 70, alignment: .trailing).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    private func position(_ title: String, value key: WritableKeyPath<AlertAppearance, Int>,
                          range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).accessibilityHidden(true)
            Spacer()
            TextField(title, value: Binding(
                get: { store.config.alertAppearance[keyPath: key] },
                set: { store.config.alertAppearance[keyPath: key] = min(max($0, range.lowerBound), range.upperBound) }
            ), format: .number)
                .labelsHidden().frame(width: 90)
                .accessibilityLabel("\(title), points")
            Text("pt").accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    private func color(_ key: WritableKeyPath<AlertAppearance, String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: store.config.alertAppearance[keyPath: key]) ?? .black) },
            set: { store.config.alertAppearance[keyPath: key] = NSColor($0).hexString }
        )
    }

    private func setSize(width: Int, height: Int, scale: Int) {
        var appearance = store.config.alertAppearance
        appearance.width = width
        appearance.height = height
        appearance.textScale = scale
        store.config.alertAppearance = appearance
    }
}
