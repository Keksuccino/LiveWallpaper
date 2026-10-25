import Foundation

/// A property in a wallpaper's settings, as Wallpaper Engine lists them: one of the wallpaper's own (project.json
/// `general.properties`) or one of Wallpaper Engine's built-in options (`WallpaperProperty.builtIn`). The list is
/// sorted by `order`, so the built-in options (orders 1...16) sit between the scheme colour (0) and the wallpaper's own
/// properties (usually 100 and up).
public struct WallpaperProperty: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bool
        /// `step` 0 means any value; `digits` is how many decimals the value shows.
        case slider(min: Double, max: Double, step: Double, digits: Int)
        case color
        case combo([Option])
        /// Wallpaper Engine's image filters (the built-in `wcc_v`).
        case lutFilter
        case textInput
        /// A line of text or a heading, without a value.
        case label
        /// Starts a group: the properties up to the next group are shown under it.
        case group
        /// A file, folder, scene texture or shortcut chosen in Wallpaper Engine; shown, not edited.
        case file
    }

    public struct Option: Equatable, Sendable {
        /// A localization key or the text itself.
        public let label: String
        public let value: PropertyValue
    }

    public let key: String
    /// The label as the wallpaper gives it: a localization key (`ui_...`) or text, possibly with HTML.
    public let text: String
    public let kind: Kind
    public let order: Int
    public let condition: PropertyCondition?
    /// The value the wallpaper starts with; nil for properties without a value.
    public let defaultValue: PropertyValue?
    public var id: String { key }

    public init(key: String, text: String, kind: Kind, order: Int, condition: PropertyCondition? = nil,
                defaultValue: PropertyValue? = nil) {
        self.key = key
        self.text = text
        self.kind = kind
        self.order = order
        self.condition = condition
        self.defaultValue = defaultValue
    }
}

/// A wallpaper's own properties and the translations it ships for their labels.
public struct ProjectProperties: Equatable, Sendable {
    public var properties: [WallpaperProperty]
    /// `general.localization`: language code (Wallpaper Engine's, e.g. `en-us`, `de-de`, `zh-chs`) to key to text.
    public var localization: [String: [String: String]]

    public init(properties: [WallpaperProperty] = [], localization: [String: [String: String]] = [:]) {
        self.properties = properties
        self.localization = localization
    }

    /// Reads project.json. Properties of types this app does not know are left out.
    public init(projectJSON data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let general = root["general"] as? [String: Any] else {
            self.init()
            return
        }
        let raw = general["properties"] as? [String: Any] ?? [:]
        let properties = raw.compactMap { key, value in
            (value as? [String: Any]).flatMap { Self.property(key, $0) }
        }
        .sorted { ($0.order, $0.key) < ($1.order, $1.key) }
        let localization = (general["localization"] as? [String: Any] ?? [:]).reduce(into: [String: [String: String]]()) {
            if let table = $1.value as? [String: Any] {
                $0[$1.key.lowercased()] = table.compactMapValues { $0 as? String }
            }
        }
        self.init(properties: properties, localization: localization)
    }

    /// The text `key` stands for in `language` (Wallpaper Engine's codes; the closest one the wallpaper ships, then
    /// English); nil when the wallpaper has no translation for it.
    public func localized(_ key: String, language: String) -> String? {
        let code = language.lowercased()
        let base = code.split(separator: "-").first.map(String.init) ?? code
        let candidates = [code] + localization.keys.filter { $0.hasPrefix(base + "-") || $0 == base }.sorted() + ["en-us"]
        for candidate in candidates {
            if let text = localization[candidate]?[key] { return text }
        }
        return nil
    }

    private static func property(_ key: String, _ p: [String: Any]) -> WallpaperProperty? {
        guard let type = (p["type"] as? String)?.lowercased() else { return nil }
        let number = { (name: String) in (p[name] as? NSNumber)?.doubleValue }
        let kind: WallpaperProperty.Kind
        switch type {
        case "bool": kind = .bool
        case "color": kind = .color
        case "textinput": kind = .textInput
        case "text": kind = .label
        case "group": kind = .group
        case "file", "directory", "scenetexture", "usershortcut": kind = .file
        case "slider":
            let lo = number("min") ?? 0, hi = number("max") ?? 100
            guard hi > lo else { return nil }
            // `fraction` sliders take decimals (`precision` of them); the others whole numbers.
            let fraction = (p["fraction"] as? Bool) ?? false
            let digits = fraction ? Int(number("precision") ?? 2) : 0
            let step = number("step") ?? (fraction ? 0 : 1)
            kind = .slider(min: lo, max: hi, step: step, digits: min(max(digits, 0), 6))
        case "combo":
            let options = (p["options"] as? [[String: Any]] ?? []).compactMap { option -> WallpaperProperty.Option? in
                guard let value = Self.value(option["value"]) else { return nil }
                let label = option["label"] as? String ?? value.description
                return WallpaperProperty.Option(label: label, value: value)
            }
            guard !options.isEmpty else { return nil }
            kind = .combo(options)
        default:
            return nil
        }
        let text = (p["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
        let condition = (p["condition"] as? String).flatMap(PropertyCondition.init)
        return WallpaperProperty(key: key, text: text, kind: kind, order: (p["order"] as? NSNumber)?.intValue ?? 0,
                                 condition: condition, defaultValue: Self.value(p["value"]))
    }

    /// A JSON value as a property value (NSNumber holds both booleans and numbers).
    static func value(_ raw: Any?) -> PropertyValue? {
        switch raw {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return .bool(n.boolValue)
        case let n as NSNumber: return .number(n.doubleValue)
        case let s as String: return .string(s)
        default: return nil
        }
    }
}

extension PropertyValue {
    /// The value as JSON text would write it (numbers without a needless fraction).
    public var description: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): return s
        }
    }
}

// MARK: - Wallpaper Engine's built-in options

/// What kind of wallpaper the built-in options are for.
public enum WallpaperType: Sendable {
    case scene(SceneFeatures)
    case video
}

extension WallpaperProperty {
    /// Alignment values as Wallpaper Engine stores them, which its conditions compare against.
    public enum AlignmentValue: Double, CaseIterable, Sendable {
        case cover = 0, fill = 1, stretch = 2, center = 3, free = 4
    }

    /// The key of Wallpaper Engine's function that tells whether the position slider is of use: the wallpaper's aspect
    /// ratio differs from the display's, so cover crops or fill leaves bars.
    public static let positionVisibility = "checkPositionVisibility"

    /// Wallpaper Engine's built-in options for a wallpaper of `type`, with its keys, orders, ranges and conditions: a
    /// video has all of them; a scene has the volume only with sound, the alignment only as a 2D scene and the mouse
    /// parallax switch only when its camera follows the pointer. Slider values are in Wallpaper Engine's units
    /// (0...100 for most, 10...200 for the rate, 0...200 for the zoom).
    public static func builtIn(for type: WallpaperType) -> [WallpaperProperty] {
        let (sound, alignment, parallax): (Bool, Bool, Bool)
        switch type {
        case .video: (sound, alignment, parallax) = (true, true, false)
        case .scene(let f): (sound, alignment, parallax) = (f.sound, f.orthographic, f.parallax)
        }
        let percent = Kind.slider(min: 0, max: 100, step: 1, digits: 0)
        func p(_ key: String, _ text: String, _ kind: Kind, _ order: Int, _ condition: String? = nil,
               _ value: PropertyValue) -> WallpaperProperty {
            WallpaperProperty(key: key, text: text, kind: kind, order: order,
                              condition: condition.flatMap(PropertyCondition.init), defaultValue: value)
        }
        var list: [WallpaperProperty] = []
        if sound { list.append(p("volume", "ui_browse_properties_volume", percent, 1, nil, .number(100))) }
        list.append(p("rate", "ui_browse_properties_playback_rate", .slider(min: 10, max: 200, step: 1, digits: 0), 2,
                      nil, .number(100)))
        if parallax { list.append(p("cameraparallax", "ui_browse_properties_mouse_parallax", .bool, 3, nil, .bool(true))) }
        if alignment {
            let a = { (text: String, v: AlignmentValue) in Option(label: text, value: .number(v.rawValue)) }
            list.append(p("alignment", "ui_browse_properties_alignment", .combo([
                a("ui_browse_properties_alignment_cover", .cover), a("ui_browse_properties_alignment_fill", .fill),
                a("ui_browse_properties_alignment_center", .center), a("ui_browse_properties_alignment_stretch", .stretch),
                a("ui_browse_properties_alignment_free", .free),
            ]), 4, nil, .number(0)))
            list.append(p("alignmentposition", "ui_browse_properties_alignment_position", percent, 5,
                          "alignment.value<2&&\(positionVisibility)()", .number(50)))
            list.append(p("alignmentx", "ui_browse_properties_alignment_horizontal", percent, 5,
                          "alignment.value==3||alignment.value==4", .number(50)))
            list.append(p("alignmenty", "ui_browse_properties_alignment_vertical", percent, 6,
                          "alignment.value==3||alignment.value==4", .number(50)))
            list.append(p("alignmentz", "ui_browse_properties_alignment_zoom", .slider(min: 0, max: 200, step: 1, digits: 0),
                          7, "alignment.value==4", .number(100)))
        }
        list.append(p("alignmentfliph", "ui_browse_properties_alignment_flip_horizontally", .bool, 8, nil, .bool(false)))
        list.append(p("wcc_v", "ui_browse_properties_image_filter", .lutFilter, 9, nil, .string("")))
        list.append(p("wcc_amt", "ui_browse_properties_filter_strength", percent, 10, "wcc_v.value", .number(100)))
        list.append(p("wec_e", "ui_browse_properties_show_color_options", .bool, 12, nil, .bool(false)))
        for (i, (key, text)) in [("wec_brs", "ui_browse_properties_brightness"), ("wec_con", "ui_browse_properties_contrast"),
                                 ("wec_sa", "ui_browse_properties_saturation"), ("wec_hue", "ui_browse_properties_hue_shift")]
            .enumerated() {
            list.append(p(key, text, percent, 13 + i, "wec_e.value", .number(50)))
        }
        return list
    }
}
