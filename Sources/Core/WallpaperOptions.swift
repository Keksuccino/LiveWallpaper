import Foundation

// How wallpapers look and sound on one display: per wallpaper (DisplayConfig.wallpaperOptions) and for all scenes of
// the display (DisplayConfig.power). Edited in the settings app, applied by WallpaperMageService: scenes through
// SceneBridge, videos through AVFoundation and Core Image. Every field has a default, so older files load.

/// Where a wallpaper sits on its display: Wallpaper Engine's alignment options.
public enum WallpaperAlignment: String, Codable, CaseIterable, Sendable {
    /// Covers the display; the overflow is cropped and `position` picks the part that shows.
    case cover
    /// Shows the whole wallpaper; `position` places it between the bars this leaves.
    case fill
    /// One wallpaper pixel per display pixel, placed by `alignX` and `alignY`.
    case center
    /// Stretched onto the display, ignoring the aspect ratio.
    case stretch
    /// Like center, magnified by `zoom`; can be moved all the way off the display.
    case free

    /// Alignments that can leave part of the display uncovered (bars).
    public var canLeaveBars: Bool { self == .fill || self == .center || self == .free }
}

/// One value of a scene's own user property (from its project.json), set from the settings app.
public enum ScenePropertyValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case color(red: Double, green: Double, blue: Double)
}

/// Settings for one wallpaper on one display. Keyed by the item's id in `DisplayConfig.wallpaperOptions`. The first
/// group holds Wallpaper Engine's own options, which every wallpaper has (its "wallpaper properties"); the second
/// group applies to scenes only.
public struct WallpaperOptions: Codable, Equatable, Sendable {
    public var volume: Double            // 0...1, the wallpaper's sound; the master volume (LibraryState) scales it
    public var muted: Bool               // this wallpaper stays silent
    public var rate: Double              // 0.1...2, playback speed, 1 = as made
    public var alignment: WallpaperAlignment
    public var position: Double          // 0...1, cover and fill: place along the axis that overflows or has bars
    public var alignX: Double            // 0...1, center and free: horizontal place, 0.5 = centred
    public var alignY: Double            // 0...1, vertical place
    public var zoom: Double              // 0...2, free: 1 = one wallpaper pixel per display pixel
    public var flip: Bool                // mirrored left to right
    public var blurBars: Bool            // bars show a blurred copy of the wallpaper (an addition of this app)
    public var colorAdjust: Bool         // "Show colour options": the four values below apply
    public var brightness: Double        // 0...1, 0.5 = unchanged
    public var contrast: Double
    public var saturation: Double
    public var hue: Double
    public var filter: String?           // image filter: the name of one of Wallpaper Engine's lookup tables
    public var filterStrength: Double    // 0...1
    public var mouseParallax: Bool       // a scene's camera parallax follows the pointer (when it has one)

    public var fps: Int                  // 10...120, frames per second; lowered on battery (PowerOptions)
    public var renderScale: Double       // 0.25...1, share of the display's pixels the scene is drawn at
    public var antialiasing: Bool        // smoother edges (multisampling)
    public var properties: [String: ScenePropertyValue]

    public init(volume: Double = 1, muted: Bool = false, rate: Double = 1, alignment: WallpaperAlignment = .cover, position: Double = 0.5,
                alignX: Double = 0.5, alignY: Double = 0.5, zoom: Double = 1, flip: Bool = false,
                blurBars: Bool = true, colorAdjust: Bool = false, brightness: Double = 0.5, contrast: Double = 0.5,
                saturation: Double = 0.5, hue: Double = 0.5, filter: String? = nil, filterStrength: Double = 1,
                mouseParallax: Bool = true, fps: Int = WallpaperOptions.defaultFPS, renderScale: Double = 1,
                antialiasing: Bool = false, properties: [String: ScenePropertyValue] = [:]) {
        let unit = { (v: Double) in min(max(v, 0), 1) }
        self.volume = unit(volume)
        self.muted = muted
        self.rate = min(max(rate, 0.1), 2)
        self.alignment = alignment
        self.position = unit(position)
        self.alignX = unit(alignX)
        self.alignY = unit(alignY)
        self.zoom = min(max(zoom, 0), 2)
        self.flip = flip
        self.blurBars = blurBars
        self.colorAdjust = colorAdjust
        self.brightness = unit(brightness)
        self.contrast = unit(contrast)
        self.saturation = unit(saturation)
        self.hue = unit(hue)
        self.filter = filter.flatMap { $0.isEmpty ? nil : $0 }
        self.filterStrength = unit(filterStrength)
        self.mouseParallax = mouseParallax
        self.fps = Self.clampedFPS(fps)
        self.renderScale = min(max(renderScale, 0.25), 1)
        self.antialiasing = antialiasing
        self.properties = properties
    }

    public static let standard = WallpaperOptions()
    public static let defaultFPS = 30
    public static func clampedFPS(_ fps: Int) -> Int { min(max(fps, 10), 120) }

    /// The colour options change the picture (they are on and not all at their middle).
    public var adjustsColor: Bool {
        colorAdjust && [brightness, contrast, saturation, hue].contains { $0 != 0.5 }
    }

    /// The colour options or the image filter change the picture.
    public var gradesColor: Bool { adjustsColor || (filter != nil && filterStrength > 0) }

    private enum CodingKeys: String, CodingKey {
        case volume, muted, rate, alignment, position, alignX, alignY, zoom, flip, blurBars, colorAdjust, brightness,
             contrast, saturation, hue, filter, filterStrength, mouseParallax, fps, renderScale, antialiasing,
             properties
        // Older files: a fit mode in place of the alignment; their zoom and pan meant something else and are dropped.
        // They may also hold an `audioResponse`, which is ignored: LibraryState.audioResponse applies to every
        // wallpaper.
        case fitMode
    }

    // Every key may be missing, so a file written before an option existed still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WallpaperOptions.standard
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        var alignment = try c.decodeIfPresent(WallpaperAlignment.self, forKey: .alignment)
        var blurBars = try c.decodeIfPresent(Bool.self, forKey: .blurBars)
        let legacy = alignment == nil ? try c.decodeIfPresent(String.self, forKey: .fitMode) : nil
        if let legacy {
            // fill covered the display, fit and matchBlurred showed all of it (with black or blurred bars), none was
            // one pixel per pixel.
            alignment = ["fill": .cover, "fit": .fill, "matchBlurred": .fill, "stretch": .stretch, "none": .center][legacy]
            blurBars = legacy != "fit"
        }
        self.init(volume: try value(.volume, d.volume), muted: try value(.muted, d.muted), rate: try value(.rate, d.rate),
                  alignment: alignment ?? d.alignment, position: try value(.position, d.position),
                  alignX: try value(.alignX, d.alignX), alignY: try value(.alignY, d.alignY),
                  zoom: legacy == nil ? try value(.zoom, d.zoom) : d.zoom, flip: try value(.flip, d.flip),
                  blurBars: blurBars ?? d.blurBars, colorAdjust: try value(.colorAdjust, d.colorAdjust),
                  brightness: try value(.brightness, d.brightness), contrast: try value(.contrast, d.contrast),
                  saturation: try value(.saturation, d.saturation), hue: try value(.hue, d.hue),
                  filter: try c.decodeIfPresent(String.self, forKey: .filter),
                  filterStrength: try value(.filterStrength, d.filterStrength),
                  mouseParallax: try value(.mouseParallax, d.mouseParallax),
                  fps: try value(.fps, d.fps),
                  renderScale: try value(.renderScale, d.renderScale),
                  antialiasing: try value(.antialiasing, d.antialiasing),
                  properties: try value(.properties, d.properties))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volume, forKey: .volume)
        try c.encode(muted, forKey: .muted)
        try c.encode(rate, forKey: .rate)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(position, forKey: .position)
        try c.encode(alignX, forKey: .alignX)
        try c.encode(alignY, forKey: .alignY)
        try c.encode(zoom, forKey: .zoom)
        try c.encode(flip, forKey: .flip)
        try c.encode(blurBars, forKey: .blurBars)
        try c.encode(colorAdjust, forKey: .colorAdjust)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(hue, forKey: .hue)
        try c.encodeIfPresent(filter, forKey: .filter)
        try c.encode(filterStrength, forKey: .filterStrength)
        try c.encode(mouseParallax, forKey: .mouseParallax)
        try c.encode(fps, forKey: .fps)
        try c.encode(renderScale, forKey: .renderScale)
        try c.encode(antialiasing, forKey: .antialiasing)
        try c.encode(properties, forKey: .properties)
    }
}

extension WallpaperOptions {
    /// These options with every setting taken from `other` except the scene's own properties, which stay. The scene
    /// performance settings (frame rate, render scale, antialiasing) come along only with `performance`; otherwise
    /// these keep theirs. "Apply to all wallpapers" uses it.
    public func withSettings(of other: WallpaperOptions, performance: Bool) -> WallpaperOptions {
        var o = other
        o.properties = properties
        if !performance {
            (o.fps, o.renderScale, o.antialiasing) = (fps, renderScale, antialiasing)
        }
        return o
    }
}

/// A named set of one wallpaper's options the user saved (Wallpaper Engine's "your presets"), with the energy
/// settings of the display it was saved on.
public struct WallpaperPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var options: WallpaperOptions
    /// The display's energy settings (DisplayConfig.power); nil when saved in a playlist, which has none. Loading a
    /// preset without them leaves a display's own.
    public var power: PowerOptions?

    public init(id: UUID = UUID(), name: String, options: WallpaperOptions, power: PowerOptions? = nil) {
        self.id = id
        self.name = name
        self.options = options
        self.power = power
    }
}

/// What "Share JSON" puts on the clipboard: a wallpaper's options and, from a display, its energy settings under
/// `power`, all in one object. JSON with the options' keys alone loads too, without energy settings.
public struct SharedWallpaperSettings: Codable, Equatable, Sendable {
    public var options: WallpaperOptions
    public var power: PowerOptions?

    public init(options: WallpaperOptions, power: PowerOptions? = nil) {
        self.options = options
        self.power = power
    }

    // `power` sits beside the options' own keys: both containers are the same JSON object.
    private enum CodingKeys: String, CodingKey { case power }

    public init(from decoder: Decoder) throws {
        options = try WallpaperOptions(from: decoder)
        power = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(PowerOptions.self, forKey: .power)
    }

    public func encode(to encoder: Encoder) throws {
        try options.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(power, forKey: .power)
    }
}

/// The image filters Wallpaper Engine's wallpaper settings offer: colour lookup tables in its shared assets
/// (`materials/lut/<name>.tex`).
public enum LUTFilter {
    public static let names = [
        "lutx32_amber", "lutx32_sandyskyd", "lutx32_beach", "lutx32_backsea", "lutx32_coloration", "lutx32_daisy",
        "desert_4", "lutx32_bluenavy", "lutx32_emeraldd", "lutx32_honeyb", "80s_post-apocalyptic_action",
        "desperado", "lutx32_ferne", "gamebob_2", "tower", "lutx32_slate", "simple_film", "lutx32_studio",
        "lutx32_dusk", "setting_sun", "aliens_2", "k23_b", "sharp_wasteland", "lutx32_westernf", "lutx32_adventure",
    ]
}

/// What the scene battery rule does (maps to the bridge's battery mode).
public enum BatteryMode: String, Codable, CaseIterable, Sendable {
    case keepRunning, reducedQuality, pause
}

/// Settings for every scene on one display. Stored in `DisplayConfig.power`.
public struct PowerOptions: Codable, Equatable, Sendable {
    public var batteryMode: BatteryMode
    public var batteryRenderScale: Double      // 0.25...1, used in reduced quality
    public var batteryFPS: Int                 // used in reduced quality

    public init(batteryMode: BatteryMode = .reducedQuality, batteryRenderScale: Double = 0.5, batteryFPS: Int = 24) {
        self.batteryMode = batteryMode
        self.batteryRenderScale = min(max(batteryRenderScale, 0.25), 1)
        self.batteryFPS = min(max(batteryFPS, 10), 120)
    }

    public static let standard = PowerOptions()
}
