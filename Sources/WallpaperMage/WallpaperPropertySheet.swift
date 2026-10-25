import AVFoundation
import Foundation
import Core
import SceneFormat

// What the Wallpaper section of the inspector lists for one wallpaper, and how its values map onto WallpaperOptions:
// Wallpaper Engine's built-in options (stored as fields of WallpaperOptions) and, for a scene, its own properties
// (WallpaperOptions.properties), merged in Wallpaper Engine's order.

/// One wallpaper's property list, read off the main actor.
struct WallpaperSheet: Sendable {
    /// Built-in options and the scene's own properties, sorted by order.
    let properties: [WallpaperProperty]
    let project: ProjectProperties
    /// The wallpaper's own picture size (a 2D scene's design size, a video's frame size); nil when unknown.
    let contentSize: CGSize?

    @MainActor private static var cache: [UUID: WallpaperSheet] = [:]

    @MainActor static func load(for item: VideoItem) async -> WallpaperSheet {
        if let cached = cache[item.id] { return cached }
        let sheet = await Task.detached(priority: .userInitiated) { await read(item) }.value
        cache[item.id] = sheet
        return sheet
    }

    private static func read(_ item: VideoItem) async -> WallpaperSheet {
        guard let info = item.scene else {
            let size = await videoSize(item.url)
            return WallpaperSheet(properties: WallpaperProperty.builtIn(for: .video), project: ProjectProperties(),
                                  contentSize: size)
        }
        let folder = item.url.deletingLastPathComponent()
        // A loose scene keeps project.json next to its scene folder.
        let projectURL = [folder, folder.deletingLastPathComponent()].map { $0.appendingPathComponent("project.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let project = projectURL.flatMap { try? Data(contentsOf: $0) }.map(ProjectProperties.init) ?? ProjectProperties()
        let features = SceneFeatures.read(scenePath: item.url) ?? SceneFeatures()
        let own = project.properties.filter { $0.kind != .file }
        let merged = (WallpaperProperty.builtIn(for: .scene(features)) + own).sorted { $0.order < $1.order }
        return WallpaperSheet(properties: merged, project: project,
                              contentSize: CGSize(width: info.designWidth, height: info.designHeight))
    }

    /// The size a video is shown at: its track's size, turned by its transform.
    private static func videoSize(_ url: URL) async -> CGSize? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let turned = size.applying(transform)
        return CGSize(width: abs(turned.width), height: abs(turned.height))
    }
}

// MARK: - Labels

enum PropertyText {
    /// A property or option label as the user should read it: the wallpaper's own translation, this app's translation
    /// of Wallpaper Engine's keys (`ui_...`), a readable form of an unknown key, or the text itself; without HTML.
    static func display(_ text: String, project: ProjectProperties) -> String {
        if let own = project.localized(text, language: weLanguage) { return plain(own) }
        guard text.hasPrefix("ui_") else { return plain(text) }
        let translated = Bundle.main.localizedString(forKey: text, value: nil, table: nil)
        return translated == text ? readable(text) : translated
    }

    /// The app's language as Wallpaper Engine names languages (`de-de`, `zh-chs`, ...); a bare language matches any of
    /// its regions in ProjectProperties.localized.
    static var weLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        switch code {
        case "zh-Hans": return "zh-chs"
        case "zh-Hant": return "zh-cht"
        case "en": return "en-us"
        default: return code.lowercased().replacingOccurrences(of: "_", with: "-")
        }
    }

    /// `ui_editor_properties_light_speed` → "Light speed".
    private static func readable(_ key: String) -> String {
        var name = key
        for prefix in ["ui_browse_properties_", "ui_editor_properties_", "ui_"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Text without HTML tags (line breaks kept) and with the common entities decoded.
    private static func plain(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Values

extension WallpaperOptions {
    /// The value of a built-in option, in Wallpaper Engine's units; nil for keys that are not built-in.
    func builtInValue(_ key: String) -> PropertyValue? {
        switch key {
        case "volume": return .number((volume * 100).rounded())
        case "rate": return .number((rate * 100).rounded())
        case "cameraparallax": return .bool(mouseParallax)
        case "alignment": return .number(alignment.weValue.rawValue)
        case "alignmentposition": return .number((position * 100).rounded())
        case "alignmentx": return .number((alignX * 100).rounded())
        case "alignmenty": return .number((alignY * 100).rounded())
        case "alignmentz": return .number((zoom * 100).rounded())
        case "alignmentfliph": return .bool(flip)
        case "wcc_v": return .string(filter ?? "")
        case "wcc_amt": return .number((filterStrength * 100).rounded())
        case "wec_e": return .bool(colorAdjust)
        case "wec_brs": return .number((brightness * 100).rounded())
        case "wec_con": return .number((contrast * 100).rounded())
        case "wec_sa": return .number((saturation * 100).rounded())
        case "wec_hue": return .number((hue * 100).rounded())
        default: return nil
        }
    }

    /// Sets a built-in option from a value in Wallpaper Engine's units. Returns false for keys that are not built-in.
    @discardableResult
    mutating func setBuiltIn(_ key: String, _ value: PropertyValue) -> Bool {
        let number: Double = {
            switch value {
            case .number(let n): return n
            case .bool(let b): return b ? 1 : 0
            case .string(let s): return Double(s) ?? 0
            }
        }()
        let flag: Bool = { if case .bool(let b) = value { return b }; return number != 0 }()
        switch key {
        case "volume": volume = number / 100
        case "rate": rate = number / 100
        case "cameraparallax": mouseParallax = flag
        case "alignment": alignment = WallpaperProperty.AlignmentValue(rawValue: number).map(WallpaperAlignment.init) ?? .cover
        case "alignmentposition": position = number / 100
        case "alignmentx": alignX = number / 100
        case "alignmenty": alignY = number / 100
        case "alignmentz": zoom = number / 100
        case "alignmentfliph": flip = flag
        case "wcc_v": if case .string(let s) = value { filter = s.isEmpty ? nil : s }
        case "wcc_amt": filterStrength = number / 100
        case "wec_e": colorAdjust = flag
        case "wec_brs": brightness = number / 100
        case "wec_con": contrast = number / 100
        case "wec_sa": saturation = number / 100
        case "wec_hue": hue = number / 100
        default: return false
        }
        // The initialiser clamps every value into its range.
        self = WallpaperOptions(volume: volume, rate: rate, alignment: alignment, position: position, alignX: alignX,
                                alignY: alignY, zoom: zoom, flip: flip, blurBars: blurBars, colorAdjust: colorAdjust,
                                brightness: brightness, contrast: contrast, saturation: saturation, hue: hue,
                                filter: filter, filterStrength: filterStrength, mouseParallax: mouseParallax, fps: fps,
                                renderScale: renderScale, audioResponse: audioResponse, antialiasing: antialiasing,
                                properties: properties)
        return true
    }
}

extension WallpaperAlignment {
    var weValue: WallpaperProperty.AlignmentValue {
        switch self {
        case .cover: return .cover
        case .fill: return .fill
        case .center: return .center
        case .stretch: return .stretch
        case .free: return .free
        }
    }

    init(_ value: WallpaperProperty.AlignmentValue) {
        switch value {
        case .cover: self = .cover
        case .fill: self = .fill
        case .center: self = .center
        case .stretch: self = .stretch
        case .free: self = .free
        }
    }
}

extension ScenePropertyValue {
    /// The value as conditions see it (a colour as Wallpaper Engine's "r g b" text).
    var conditionValue: PropertyValue {
        switch self {
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .color(let r, let g, let b): return .string("\(r) \(g) \(b)")
        }
    }

    /// A project.json default as the value type the renderer takes for a property of `kind`.
    init?(_ value: PropertyValue?, kind: WallpaperProperty.Kind) {
        switch (kind, value) {
        case (.bool, .bool(let b)?): self = .bool(b)
        case (.bool, .number(let n)?): self = .bool(n != 0)
        case (.slider, .number(let n)?): self = .number(n)
        case (.color, .string(let s)?):
            let c = s.split(separator: " ").compactMap { Double($0) }
            guard c.count >= 3 else { return nil }
            self = .color(red: c[0], green: c[1], blue: c[2])
        case (.textInput, .string(let s)?): self = .string(s)
        case (.combo, .number(let n)?): self = .number(n)
        case (.combo, .string(let s)?): self = .string(s)
        default: return nil
        }
    }
}
