import SwiftUI
import Core

// Per-scene settings ("Scene settings" section of the library detail) and the global "Scenes" power settings.
// Everything writes through SettingsModel (sceneOptions / power), which commits to the service.

/// One user property read from a scene's project.json (general.properties).
struct SceneProperty: Identifiable {
    enum Kind { case bool, slider(min: Double, max: Double, step: Double), color, text, combo([(label: String, value: ScenePropertyValue)]) }
    let key: String
    let label: String
    let kind: Kind
    let order: Int
    var id: String { key }

    /// Supported: bool, slider, color, text/textinput, combo. Anything else is skipped.
    static func load(from projectJSON: URL) -> [SceneProperty] {
        guard let data = try? Data(contentsOf: projectJSON),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let props = (root["general"] as? [String: Any])?["properties"] as? [String: Any] else { return [] }
        return props.compactMap { key, raw -> SceneProperty? in
            guard let p = raw as? [String: Any], let type = (p["type"] as? String)?.lowercased() else { return nil }
            let label = (p["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            let order = (p["order"] as? NSNumber)?.intValue ?? 0
            func make(_ kind: Kind) -> SceneProperty { SceneProperty(key: key, label: label, kind: kind, order: order) }
            switch type {
            case "bool": return make(.bool)
            case "color": return make(.color)
            case "text", "textinput": return make(.text)
            case "slider":
                let lo = (p["min"] as? NSNumber)?.doubleValue ?? 0, hi = (p["max"] as? NSNumber)?.doubleValue ?? 1
                guard hi > lo else { return nil }
                return make(.slider(min: lo, max: hi, step: (p["step"] as? NSNumber)?.doubleValue ?? 0))
            case "combo":
                let options = (p["options"] as? [[String: Any]] ?? []).compactMap { o -> (String, ScenePropertyValue)? in
                    guard let label = o["label"] as? String else { return nil }
                    if let n = o["value"] as? NSNumber { return (label, .number(n.doubleValue)) }
                    return (label, .string(o["value"] as? String ?? label))
                }
                return options.isEmpty ? nil : make(.combo(options))
            default: return nil
            }
        }
        .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
    }

    /// The property's default (project.json "value"), used until the user changes it.
    static func defaults(from projectJSON: URL, key: String) -> Any? {
        guard let data = try? Data(contentsOf: projectJSON),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let props = (root["general"] as? [String: Any])?["properties"] as? [String: Any] else { return nil }
        return (props[key] as? [String: Any])?["value"]
    }
}

@MainActor
fileprivate final class ScenePropertyCache {
    static var cache: [UUID: [SceneProperty]] = [:]
    static var defaults: [UUID: [String: ScenePropertyValue]] = [:]
}

@MainActor
struct SceneSettingsCard: View {
    @ObservedObject var model: SettingsModel
    let item: VideoItem
    @State private var properties: [SceneProperty] = []

    private var options: SceneOptions { model.sceneOptions(for: item.id) }
    private func binding<T>(_ path: WritableKeyPath<SceneOptions, T>) -> Binding<T> {
        Binding(get: { model.sceneOptions(for: item.id)[keyPath: path] },
                set: { v in model.updateSceneOptions(item.id) { $0[keyPath: path] = v } })
    }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scene settings").font(.headline)
            HStack {
                Text("Frame rate"); Spacer()
                Picker("Frame rate", selection: binding(\.fps)) {
                    Text("Use global").tag(Int?.none)
                    ForEach([20, 24, 30, 45, 60], id: \.self) { Text("\($0) fps").tag(Int?.some($0)) }
                }.labelsHidden().fixedSize()
            }
            .help("Frame rate for this scene. “Use global” follows Scene frame rate below.")
            sliderRow("Resolution", binding(\.renderScale), 0.25...1)
                .help("Share of the display’s pixels the scene is drawn at. Lower is lighter on the GPU.")
            sliderRow("Zoom", binding(\.zoom), 0.5...2)
            HStack {
                Text("Fit"); Spacer()
                Picker("Fit", selection: binding(\.fitMode)) {
                    ForEach(SceneFitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
            }
            sliderRow("Volume", binding(\.volume), 0...1)
            Toggle("Scene responds to music", isOn: binding(\.audioResponse))
            Toggle("Antialiasing (coming soon)", isOn: .constant(false)).disabled(true)
            if !properties.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Properties").font(.headline)
                ForEach(properties) { propertyRow($0) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
        .task(id: item.id) { await loadProperties() }
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(percent(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    private func loadProperties() async {
        if let cached = ScenePropertyCache.cache[item.id] { properties = cached; return }
        let url = item.url.deletingLastPathComponent().appendingPathComponent("project.json")
        let loaded = await Task.detached { SceneProperty.load(from: url) }.value
        ScenePropertyCache.cache[item.id] = loaded
        properties = loaded
    }

    // MARK: Property rows

    private func current(_ p: SceneProperty) -> ScenePropertyValue? { options.properties[p.key] }
    private func set(_ p: SceneProperty, _ v: ScenePropertyValue) {
        model.updateSceneOptions(item.id) { $0.properties[p.key] = v }
    }
    private func projectDefault(_ p: SceneProperty) -> Any? {
        SceneProperty.defaults(from: item.url.deletingLastPathComponent().appendingPathComponent("project.json"), key: p.key)
    }

    @ViewBuilder private func propertyRow(_ p: SceneProperty) -> some View {
        let def = projectDefault(p)
        switch p.kind {
        case .bool:
            Toggle(p.label, isOn: Binding(
                get: { if case .bool(let b)? = current(p) { return b }; return (def as? NSNumber)?.boolValue ?? false },
                set: { set(p, .bool($0)) }))
        case .slider(let lo, let hi, _):
            HStack {
                Text(p.label)
                Slider(value: Binding(
                    get: { if case .number(let n)? = current(p) { return n }; return (def as? NSNumber)?.doubleValue ?? lo },
                    set: { set(p, .number($0)) }), in: lo...hi)
            }
        case .color:
            ColorPicker(p.label, selection: Binding(
                get: {
                    if case .color(let r, let g, let b)? = current(p) { return Color(red: r, green: g, blue: b) }
                    let c = ((def as? String) ?? "1 1 1").split(separator: " ").compactMap { Double($0) }
                    return c.count >= 3 ? Color(red: c[0], green: c[1], blue: c[2]) : .white
                },
                set: { c in
                    let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
                    set(p, .color(red: n.redComponent, green: n.greenComponent, blue: n.blueComponent))
                }), supportsOpacity: false)
        case .text:
            HStack {
                Text(p.label)
                TextField("", text: Binding(
                    get: { if case .string(let s)? = current(p) { return s }; return (def as? String) ?? "" },
                    set: { set(p, .string($0)) })).textFieldStyle(.roundedBorder)
            }
        case .combo(let choices):
            HStack {
                Text(p.label); Spacer()
                Picker(p.label, selection: Binding<Int>(
                    get: {
                        if let v = current(p), let i = choices.firstIndex(where: { $0.value == v }) { return i }
                        if let n = def as? NSNumber, let i = choices.firstIndex(where: { $0.value == .number(n.doubleValue) }) { return i }
                        if let s = def as? String, let i = choices.firstIndex(where: { $0.value == .string(s) }) { return i }
                        return 0
                    },
                    set: { set(p, choices[$0].value) })) {
                    ForEach(choices.indices, id: \.self) { Text(choices[$0].label).tag($0) }
                }.labelsHidden().fixedSize()
            }
        }
    }
}

/// Global "Scenes" rows (frame-rate cap, battery rule, render optimisations); lives inside the settings card.
@MainActor
struct ScenePowerRows: View {
    @ObservedObject var model: SettingsModel

    private func binding<T>(_ path: WritableKeyPath<PowerOptions, T>) -> Binding<T> {
        Binding(get: { model.power[keyPath: path] }, set: { model.power[keyPath: path] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scenes").font(.headline)
            HStack {
                Text("Frame rate cap"); Spacer()
                Picker("Frame rate cap", selection: binding(\.frameRateCap)) {
                    Text("None").tag(Int?.none)
                    ForEach([30, 45, 60, 120], id: \.self) { Text("\($0) fps").tag(Int?.some($0)) }
                }.labelsHidden().fixedSize()
            }
            .help("No scene is drawn faster than this, whatever its own setting.")
            HStack {
                Text("On battery"); Spacer()
                Picker("On battery", selection: binding(\.batteryMode)) {
                    ForEach(BatteryMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
            }
            if model.power.batteryMode == .reducedQuality {
                HStack {
                    Text("Battery resolution")
                    Slider(value: binding(\.batteryRenderScale), in: 0.25...1)
                    Text("\(Int((model.power.batteryRenderScale * 100).rounded()))%").monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Battery frame rate"); Spacer()
                    Picker("Battery frame rate", selection: binding(\.batteryFPS)) {
                        ForEach([15, 20, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            Toggle("Skip repeated frames", isOn: binding(\.skipRepeatedFrames))
            Toggle("Update only when the scene changes", isOn: binding(\.renderOnlyOnChange))
                .help("Stops idle scenes completely until something in them moves.")
            Text("Stops idle scenes completely.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
