import SwiftUI
import Core
import SceneFormat

// A wallpaper's settings on one display (the "Wallpaper" section of the Home inspector) or in one playlist (the
// playlist editor's inspector), and a display's "Energy" power settings. Everything writes through SettingsModel
// (DisplayConfig.wallpaperOptions, Playlist.wallpaperOptions, DisplayConfig.power), which commits to the service.

@MainActor
struct WallpaperSettingsCard: View {
    @ObservedObject var model: SettingsModel
    /// Whose options these are: the display's or the playlist's.
    let scope: OptionsScope
    let item: VideoItem
    @State private var sheet: WallpaperSheet?
    /// Groups the user folded away, by the group property's key.
    @State private var folded: Set<String> = []
    @State private var naming = false
    @State private var presetName = ""
    @State private var confirmingApplyToAll = false
    @State private var pasteFailed = false

    private var options: WallpaperOptions { model.options(in: scope, for: item.id) }

    private func update(_ change: (inout WallpaperOptions) -> Void) {
        model.updateOptions(in: scope, for: item.id, change)
    }

    private var inPlaylist: Bool {
        if case .playlist = scope { return true }
        return false
    }

    var body: some View {
        InspectorSection(title: "Wallpaper") {
            VStack(alignment: .leading, spacing: 12) {
                if let sheet {
                    propertyList(sheet)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                Divider()
                presetButtons
                if item.isScene {
                    Divider()
                    performance
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: item.id) { sheet = await WallpaperSheet.load(for: item) }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.savePreset(named: name, for: item, in: scope) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inPlaylist
                 ? "Saves this wallpaper’s settings in this playlist under a name. A preset with the same name is replaced."
                 : "Saves this wallpaper’s settings on this display under a name. A preset with the same name is replaced.")
        }
        .confirmationDialog("Apply these settings to all wallpapers?", isPresented: $confirmingApplyToAll) {
            Button("Apply to All Wallpapers") { model.applyBuiltInsToAll(from: item, in: scope) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inPlaylist
                 ? "Every other wallpaper in this playlist gets this wallpaper’s sound, speed, alignment and colour settings. Each keeps its own properties."
                 : "Every other wallpaper on this display gets this wallpaper’s sound, speed, alignment and colour settings. Each keeps its own properties.")
        }
        .alert("No Wallpaper Settings on the Clipboard", isPresented: $pasteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Copy a wallpaper’s settings with Share JSON first.")
        }
    }

    // MARK: Presets

    /// Wallpaper Engine's "your presets": load, save, apply to all wallpapers, share as JSON, reset.
    private var presetButtons: some View {
        let saved = model.presets(for: item)
        return InspectorSection(title: "Presets") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    // A Menu keeps its natural width whatever its frame; Save takes the rest of the row.
                    Menu {
                        ForEach(saved) { preset in
                            Button(preset.name) { update { $0 = preset.options } }
                        }
                        if !saved.isEmpty { Divider() }
                        Button("Paste from Clipboard", action: pasteJSON)
                        if !saved.isEmpty {
                            Menu("Delete") {
                                ForEach(saved) { preset in
                                    Button(preset.name, role: .destructive) { model.deletePreset(preset, of: item) }
                                }
                            }
                        }
                    } label: {
                        Label("Load", systemImage: "folder")
                    }
                    Button {
                        presetName = ""
                        naming = true
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                }
                Button { confirmingApplyToAll = true } label: {
                    Label("Apply to All Wallpapers", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity)
                }
                .help(inPlaylist
                      ? "Gives every other wallpaper in this playlist this wallpaper’s sound, speed, alignment and colour settings."
                      : "Gives every other wallpaper on this display this wallpaper’s sound, speed, alignment and colour settings.")
                HStack(spacing: 8) {
                    Button(action: copyJSON) {
                        Label("Share JSON", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .help("Copies this wallpaper’s settings to the clipboard as JSON.")
                    Button(action: reset) {
                        Label("Reset", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                    .disabled(isDefault)
                    .help("Put every setting of this wallpaper back to its default.")
                }
            }
            .controlSize(.small)
        }
    }

    private func copyJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(options), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func pasteJSON() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let pasted = try? JSONDecoder().decode(WallpaperOptions.self, from: Data(text.utf8)) else {
            pasteFailed = true
            return
        }
        update { $0 = pasted }
    }

    // MARK: Properties

    /// The properties in order; a group property heads the ones after it, up to the next group.
    @ViewBuilder private func propertyList(_ sheet: WallpaperSheet) -> some View {
        let values = currentValues(sheet)
        let sections = groups(sheet.properties)
        ForEach(sections.indices, id: \.self) { index in
            let section = sections[index]
            if let group = section.group {
                if visible(group, sheet, values) {
                    DisclosureGroup(isExpanded: Binding(get: { !folded.contains(group.key) },
                                                        set: { open in
                                                            if open { folded.remove(group.key) } else { folded.insert(group.key) }
                                                        })) {
                        rows(section.items, sheet, values).padding(.top, 6)
                    } label: {
                        Text(verbatim: PropertyText.display(group.text, project: sheet.project))
                            .font(.callout.weight(.semibold))
                    }
                }
            } else {
                rows(section.items, sheet, values)
            }
        }
    }

    private func rows(_ items: [WallpaperProperty], _ sheet: WallpaperSheet, _ values: [String: PropertyValue]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items.filter { visible($0, sheet, values) }) { property in
                row(property, sheet)
                if property.key == "volume" {
                    WMSwitchRow(isOn: Binding(get: { options.muted }, set: { on in update { $0.muted = on } }),
                                accessibilityLabel: Text("Mute")) { Label("Mute", systemImage: "speaker.slash") }
                        .help(inPlaylist ? "Silences this wallpaper in this playlist." : "Silences this wallpaper on this display.")
                    appSoundWarning
                }
                if property.key == "alignmentz", options.alignment.canLeaveBars {
                    WMSwitchRow(isOn: Binding(get: { options.blurBars }, set: { on in update { $0.blurBars = on } }),
                                accessibilityLabel: Text("Blur empty space")) {
                        Label("Blur empty space", systemImage: "drop.halffull")
                    }
                    .help("Fills the space the alignment leaves with a blurred copy of the wallpaper.")
                }
            }
        }
    }

    private func groups(_ properties: [WallpaperProperty]) -> [(group: WallpaperProperty?, items: [WallpaperProperty])] {
        var out: [(group: WallpaperProperty?, items: [WallpaperProperty])] = [(nil, [])]
        for property in properties {
            if property.kind == .group {
                out.append((property, []))
            } else {
                out[out.count - 1].items.append(property)
            }
        }
        return out.filter { $0.group != nil || !$0.items.isEmpty }
    }

    /// Every property's current value, as conditions read them.
    private func currentValues(_ sheet: WallpaperSheet) -> [String: PropertyValue] {
        var values: [String: PropertyValue] = [:]
        for property in sheet.properties {
            values[property.key] = options.builtInValue(property.key)
                ?? options.properties[property.key]?.conditionValue ?? property.defaultValue
        }
        return values
    }

    private func visible(_ property: WallpaperProperty, _ sheet: WallpaperSheet,
                         _ values: [String: PropertyValue]) -> Bool {
        guard let condition = property.condition else { return true }
        return condition.evaluate(values, functions: [WallpaperProperty.positionVisibility: {
            .bool(positionMatters(sheet))
        }])
    }

    /// Wallpaper Engine's rule for the position slider: the wallpaper's aspect ratio differs from the display's. A
    /// playlist's wallpaper is measured against the display selected on Home.
    private func positionMatters(_ sheet: WallpaperSheet) -> Bool {
        let display: String?
        switch scope {
        case .display(let id): display = id
        case .playlist: display = model.selectedDisplayID
        }
        guard let content = sheet.contentSize, content.height > 0,
              let screen = model.screens.first(where: { $0.id == display }), screen.frame.height > 0 else { return true }
        return abs(content.width / content.height - screen.frame.width / screen.frame.height) > 0.001
    }

    /// When the whole app is muted or nearly silent, a wallpaper's own volume does not tell the whole story.
    @ViewBuilder private var appSoundWarning: some View {
        if model.muted || model.masterVolume < 0.05 {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if model.muted {
                            Text("All wallpapers are muted in Settings.")
                        } else {
                            Text("The master volume in Settings is very low (\(model.masterVolume, format: .percent.precision(.fractionLength(0)))).")
                        }
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") { SettingsNavigator.shared.open(.general) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private func row(_ property: WallpaperProperty, _ sheet: WallpaperSheet) -> some View {
        let text = PropertyText.display(property.text, project: sheet.project)
        let label = Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            if let icon = Self.icons[property.key] { Image(systemName: icon) }
        }
        switch property.kind {
        case .bool:
            WMSwitchRow(isOn: Binding(get: { if case .bool(let b)? = value(property) { return b }; return false },
                                      set: { set(property, .bool($0)) }),
                        accessibilityLabel: Text(verbatim: text)) { label }
        case .slider(let lo, let hi, let step, let digits):
            let binding = Binding<Double>(
                get: { if case .number(let n)? = value(property) { return min(max(n, lo), hi) }; return lo },
                set: { set(property, .number(step > 0 ? ($0 / step).rounded() * step : $0)) })
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    label
                    Spacer(minLength: 8)
                    Text(binding.wrappedValue, format: .number.precision(.fractionLength(digits)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: binding, in: lo...hi)
                    .controlSize(.small)
                    .accessibilityLabel(Text(verbatim: text))
            }
        case .color:
            HStack {
                label
                Spacer(minLength: 8)
                ColorPicker(selection: colorBinding(property), supportsOpacity: false) { EmptyView() }
                    .labelsHidden()
                    .accessibilityLabel(Text(verbatim: text))
            }
        case .combo(let choices):
            menuRow(label: label, text: text, selection: Binding<Int>(
                get: { choices.firstIndex { option in value(property).map { option.value == $0 } ?? false } ?? 0 },
                set: { set(property, choices[$0].value) }),
                choices: choices.map { PropertyText.display($0.label, project: sheet.project) })
        case .lutFilter:
            let names = LUTFilter.names
            menuRow(label: label, text: text, selection: Binding<Int>(
                get: { options.filter.flatMap { names.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 },
                set: { index in set(property, .string(index == 0 ? "" : names[index - 1])) }),
                choices: [String(localized: "None")] + names.enumerated().map { i, name in
                    "\(i + 1) " + PropertyText.display("ui_browse_lut_filter_" + name, project: sheet.project)
                })
        case .textInput:
            VStack(alignment: .leading, spacing: 4) {
                label
                TextField(text: Binding(
                    get: { if case .string(let s)? = value(property) { return s }; return "" },
                    set: { set(property, .string($0)) })) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(verbatim: text))
            }
        case .label:
            Text(verbatim: PropertyText.display(property.text, project: sheet.project))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .group, .file:
            EmptyView()
        }
    }

    /// A menu of `choices` beside the label. The menu never takes more than half the column (truncating a long
    /// choice) and the label wraps, so the panel never grows wider than its column.
    private func menuRow<L: View>(label: L, text: String, selection: Binding<Int>, choices: [String]) -> some View {
        HStack {
            label
            Spacer(minLength: 8)
            Picker(selection: selection) {
                ForEach(choices.indices, id: \.self) { Text(verbatim: choices[$0]).tag($0) }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: text))
            .columnControl()
        }
    }

    /// SF Symbols for Wallpaper Engine's built-in options, after the icons it shows for them.
    private static let icons: [String: String] = [
        "volume": "speaker.wave.2", "rate": "play", "cameraparallax": "cursorarrow.motionlines",
        "alignment": "photo", "alignmentposition": "arrow.left.and.right", "alignmentx": "arrow.left.and.right",
        "alignmenty": "arrow.up.and.down", "alignmentz": "arrow.up.left.and.arrow.down.right",
        "alignmentfliph": "arrow.left.arrow.right", "wcc_v": "camera.filters", "wcc_amt": "slider.horizontal.3",
        "wec_brs": "sun.max", "wec_con": "circle.lefthalf.filled", "wec_sa": "drop", "wec_hue": "paintpalette",
    ]

    // MARK: Values

    /// A property's current value: a built-in option from the options' fields, the scene's own from its stored value
    /// or project.json default.
    private func value(_ property: WallpaperProperty) -> PropertyValue? {
        options.builtInValue(property.key) ?? options.properties[property.key]?.conditionValue ?? property.defaultValue
    }

    private func set(_ property: WallpaperProperty, _ value: PropertyValue) {
        update { o in
            guard !o.setBuiltIn(property.key, value) else { return }
            if let stored = ScenePropertyValue(value, kind: property.kind) { o.properties[property.key] = stored }
        }
    }

    private func colorBinding(_ property: WallpaperProperty) -> Binding<Color> {
        Binding(
            get: {
                guard case .string(let text)? = value(property) else { return .white }
                let c = text.split(separator: " ").compactMap { Double($0) }
                return c.count >= 3 ? Color(.sRGB, red: c[0], green: c[1], blue: c[2]) : .white
            },
            set: { color in
                let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
                update { $0.properties[property.key] = .color(red: c.redComponent, green: c.greenComponent,
                                                               blue: c.blueComponent) }
            })
    }

    // MARK: Scene performance

    private func binding<T>(_ path: WritableKeyPath<WallpaperOptions, T>) -> Binding<T> {
        Binding(get: { options[keyPath: path] }, set: { v in update { $0[keyPath: path] = v } })
    }

    private var performance: some View {
        InspectorSection(title: "Performance") {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Frame rate"); Spacer()
                    Picker("Frame rate", selection: binding(\.fps)) {
                        // A rate from an older file that is not among the choices still shows.
                        ForEach(Set([20, 24, 30, 45, 60, 120, options.fps]).sorted(), id: \.self) {
                            Text("\($0) fps").tag($0)
                        }
                    }.labelsHidden().columnControl()
                }
                .help("Smoothness of this scene. Higher looks smoother but keeps the GPU busier.")
                HStack {
                    Text("Resolution")
                    Slider(value: binding(\.renderScale), in: 0.25...1).controlSize(.small)
                    Text(options.renderScale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                .help("Share of the display’s pixels the scene is drawn at. Lower is lighter on the GPU.")
                WMSwitchRow("Antialiasing", isOn: binding(\.antialiasing))
                    .help("Smooths jagged edges. Costs some GPU time.")
                WMSwitchRow("Scene responds to music", isOn: binding(\.audioResponse))
                    .help("Lets audio visualisers in the scene follow what your Mac plays.")
            }
        }
    }

    // MARK: Reset

    /// True when nothing differs from the defaults (the scene's own properties count as default when they equal
    /// project.json's values).
    private var isDefault: Bool {
        var base = options
        base.properties = [:]
        guard base == .standard else { return false }
        let own = (sheet?.properties ?? []).filter { options.builtInValue($0.key) == nil }
        return own.allSatisfy { p in
            options.properties[p.key].map { $0 == ScenePropertyValue(p.defaultValue, kind: p.kind) } ?? true
        }
    }

    /// Every setting back to its default. Changed properties get their default written explicitly: dropping the key
    /// would leave the old value in the renderer until the scene restarts.
    private func reset() {
        let changed = options.properties
        let own = sheet?.properties ?? []
        update { o in
            o = .standard
            for p in own where changed[p.key] != nil {
                if let d = ScenePropertyValue(p.defaultValue, kind: p.kind) { o.properties[p.key] = d }
            }
        }
    }
}

/// A display's "Energy" rows (battery rule, render optimisations); lives inside its settings card.
@MainActor
struct ScenePowerRows: View {
    @ObservedObject var model: SettingsModel
    let display: String

    private var power: PowerOptions { model.config(for: display).power }

    private func binding<T>(_ path: WritableKeyPath<PowerOptions, T>) -> Binding<T> {
        Binding(get: { power[keyPath: path] },
                set: { value in model.updateDisplay(display) { $0.power[keyPath: path] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("On battery"); Spacer()
                Picker("On battery", selection: binding(\.batteryMode)) {
                    Text("Keep running").tag(BatteryMode.keepRunning)
                    Text("Reduced quality").tag(BatteryMode.reducedQuality)
                    Text("Pause").tag(BatteryMode.pause)
                }.labelsHidden().columnControl()
            }
            if power.batteryMode == .reducedQuality {
                HStack {
                    Text("Battery resolution")
                    Slider(value: binding(\.batteryRenderScale), in: 0.25...1)
                    Text(power.batteryRenderScale, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Battery frame rate"); Spacer()
                    Picker("Battery frame rate", selection: binding(\.batteryFPS)) {
                        ForEach([15, 20, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }.labelsHidden().columnControl()
                }
            }
            WMSwitchRow("Skip repeated frames", isOn: binding(\.skipRepeatedFrames))
            WMSwitchRow("Update only when the scene changes", isOn: binding(\.renderOnlyOnChange))
                .help("Stops idle scenes completely until something in them moves.")
        }
    }
}
