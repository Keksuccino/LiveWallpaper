import Foundation
import CoreGraphics
import CoreMedia
import AVFoundation
import UniformTypeIdentifiers

// Shared model, persistence and file locations for both processes (Settings app and wallpaper agent).
// Core never imports SwiftUI, AppKit or Combine, so the agent does not link them.
// Everything other targets touch is `public`, with an explicit public init.

// MARK: - Library items

public struct VideoItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var path: String           // absolute path of the playable file
    public var title: String?         // display title (Workshop items); nil = file name
    public var author: String?
    public var workshopID: String?    // non-nil = downloaded from the Steam Workshop
    public var previewPath: String?   // absolute path of a preview image, if any
    public var tags: [String]?
    /// Non-nil = a Wallpaper Engine scene (schema v2). `path` is then the scene package (`scene.pkg`) or
    /// the folder's `scene.json`, `previewPath` the preview image shown when the scene cannot be rendered.
    public var scene: SceneInfo?

    // Containers the system may not map to a movie type.
    private static let fallbackExtensions: Set<String> =
        ["mp4", "m4v", "mov", "mpg", "mpeg", "avi", "mkv", "webm"]

    // New fields are optional so phase-1 records ({"id","path"}) still decode.
    public init(id: UUID = UUID(), path: String, title: String? = nil, author: String? = nil,
                workshopID: String? = nil, previewPath: String? = nil, tags: [String]? = nil,
                scene: SceneInfo? = nil) {
        self.id = id
        self.path = path
        self.title = title
        self.author = author
        self.workshopID = workshopID
        self.previewPath = previewPath
        self.tags = tags
        self.scene = scene
    }

    public init(url: URL) {
        self.init(path: url.standardizedFileURL.path)
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { title ?? url.deletingPathExtension().lastPathComponent }
    public var isWorkshop: Bool { workshopID != nil }
    public var kind: ItemKind { scene == nil ? .video : .scene }
    /// Where the item's presets are kept (LibraryState.presets): a Workshop item keeps them when it is downloaded
    /// again under a new id.
    public var presetKey: String { workshopID ?? id.uuidString }
    public var isScene: Bool { scene != nil }

    /// Identifies the file's content: its size and modification time. Changes when a Workshop item is re-downloaded
    /// with new content.
    public var contentStamp: String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(Int(modified))"
    }

    public static func isVideo(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.conforms(to: .movie) || type.conforms(to: .video) {
            return true
        }
        return fallbackExtensions.contains(ext)
    }
}

public enum IntervalUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case seconds, minutes, hours

    public var id: String { rawValue }

    public var multiplier: TimeInterval {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours: return 3600
        }
    }
}

// MARK: - Scenes (schema v2)

public enum ItemKind: String, Codable, Sendable {
    case video, scene
}

/// How much of a scene the engine can show (the badge in the UI). Decided by SceneFormat's analyzer when the
/// scene is imported and stored here, so the UI and the agent never need the SceneFormat module.
public enum SceneSupport: String, Codable, Sendable {
    case full          // everything the scene uses is supported
    case partial       // plays, but some effects, particles, sounds or scripts are ignored
    case previewOnly   // the preview image is shown instead
}

public struct SceneInfo: Codable, Hashable, Sendable {
    public var support: SceneSupport
    public var notes: [String]            // short user-facing reasons, e.g. "Particles are not supported yet."
    public var designWidth: Int           // scene design resolution (orthogonal projection)
    public var designHeight: Int
    public var loopSeconds: Double?       // the scene's own period if the analyzer found one
    public var needsSharedAssets: Bool    // references files that only Wallpaper Engine's shared assets have
    public var analysisRevision: Int      // SceneFormat analyzer revision that produced this record

    public init(support: SceneSupport, notes: [String] = [], designWidth: Int = 1920, designHeight: Int = 1080,
                loopSeconds: Double? = nil, needsSharedAssets: Bool = false, analysisRevision: Int = 1) {
        self.support = support
        self.notes = notes
        self.designWidth = designWidth
        self.designHeight = designHeight
        self.loopSeconds = loopSeconds
        self.needsSharedAssets = needsSharedAssets
        self.analysisRevision = analysisRevision
    }
}

// MARK: - Library + settings (state.json, written only by the service)

/// What one display shows and how. Stored in `LibraryState.displays` under the display's UUID (DisplayIdentity), so
/// it survives restarts and reconnecting. A display without a wallpaper keeps whatever system wallpaper it has.
public struct DisplayConfig: Codable, Equatable, Sendable {
    public var wallpaperID: UUID?
    /// Cycles the playlist (LibraryState.playlist), going on from the wallpaper.
    public var rotateEnabled: Bool
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit
    public var power: PowerOptions
    /// Per wallpaper, keyed by VideoItem.id.uuidString.
    public var wallpaperOptions: [String: WallpaperOptions]

    public init(wallpaperID: UUID? = nil, rotateEnabled: Bool = false, intervalValue: Int = 5,
                intervalUnit: IntervalUnit = .minutes, power: PowerOptions = PowerOptions(),
                wallpaperOptions: [String: WallpaperOptions] = [:]) {
        self.wallpaperID = wallpaperID
        self.rotateEnabled = rotateEnabled
        self.intervalValue = LibraryState.clampedInterval(intervalValue)
        self.intervalUnit = intervalUnit
        self.power = power
        self.wallpaperOptions = wallpaperOptions
    }

    public var intervalSeconds: TimeInterval {
        max(LibraryState.minimumInterval, Double(intervalValue) * intervalUnit.multiplier)
    }
    public var intervalIsClamped: Bool {
        Double(intervalValue) * intervalUnit.multiplier < LibraryState.minimumInterval
    }

    public func options(for id: UUID) -> WallpaperOptions { wallpaperOptions[id.uuidString] ?? .standard }

    // `sceneOptions` is the key of the per-wallpaper options since scenes were the first to have them. Older files
    // also hold a `muted` per display, which is ignored: sound is muted per wallpaper and for the whole app.
    private enum CodingKeys: String, CodingKey {
        case wallpaperID, rotateEnabled, intervalValue, intervalUnit, power
        case wallpaperOptions = "sceneOptions"
    }

    // Every key may be missing, so a file written before a setting existed still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(wallpaperID: try c.decodeIfPresent(UUID.self, forKey: .wallpaperID),
                  rotateEnabled: try c.decodeIfPresent(Bool.self, forKey: .rotateEnabled) ?? false,
                  intervalValue: try c.decodeIfPresent(Int.self, forKey: .intervalValue) ?? 5,
                  intervalUnit: try c.decodeIfPresent(IntervalUnit.self, forKey: .intervalUnit) ?? .minutes,
                  power: try c.decodeIfPresent(PowerOptions.self, forKey: .power) ?? PowerOptions(),
                  wallpaperOptions: try c.decodeIfPresent([String: WallpaperOptions].self,
                                                          forKey: .wallpaperOptions) ?? [:])
    }
}

public struct LibraryState: Codable, Equatable, Sendable {
    public static let minimumInterval: TimeInterval = 5
    public static let currentSchema = 5

    public var schema: Int
    public var revision: Int          // bumped by StateStore.commit on every write
    public var videos: [VideoItem]    // the whole library (videos and scenes); the name is a phase-1 leftover
    /// The wallpapers a rotating display cycles, in this order; nil = no playlist yet (rotation needs one).
    public var playlist: [UUID]?
    /// Every display that was ever given a wallpaper or a setting, keyed by its UUID (DisplayIdentity).
    public var displays: [String: DisplayConfig]
    /// Seconds the service waits before it makes a new still for the system wallpaper (see `stillDelayOptions`).
    public var stillDelay: Double
    /// 0...1, scales every wallpaper's own volume on every display.
    public var masterVolume: Double
    /// Silences every wallpaper (the menu bar's Mute Sound). Changed only through StateStore.setMuted, never by a
    /// commit.
    public var muted: Bool
    /// The presets the user saved, per wallpaper (VideoItem.presetKey).
    public var presets: [String: [WallpaperPreset]]

    public init(schema: Int = LibraryState.currentSchema, revision: Int = 0, videos: [VideoItem] = [],
                playlist: [UUID]? = nil, displays: [String: DisplayConfig] = [:],
                stillDelay: Double = LibraryState.defaultStillDelay, masterVolume: Double = 1, muted: Bool = false,
                presets: [String: [WallpaperPreset]] = [:]) {
        self.schema = schema
        self.revision = revision
        self.videos = videos
        self.playlist = playlist
        self.displays = displays
        self.stillDelay = LibraryState.clampedStillDelay(stillDelay)
        self.masterVolume = min(max(masterVolume, 0), 1)
        self.muted = muted
        self.presets = presets
    }

    public static func clampedInterval(_ value: Int) -> Int { min(max(value, 1), 999) }

    /// The choices for `stillDelay`. The wait exists because a slider in Settings sends a change for every step, and
    /// a scene's still loads the whole scene a second time: waiting lets the drag finish before one still is made,
    /// and gives a new wallpaper time to start before its still competes with it for the machine.
    public static let stillDelayOptions: [Double] = [0, 0.5, 1, 2, 5]
    public static let defaultStillDelay: Double = 2
    public static func clampedStillDelay(_ seconds: Double) -> Double { min(max(seconds, 0), 5) }

    // MARK: Codable with migration
    // Schema 1 and 2 files hold one wallpaper with its settings for the whole desktop. Reading one gives that
    // wallpaper and its settings to every display connected at the time; the next commit writes them per display.
    // Files before schema 4 muted sound by default (the desktop's or each display's `muted`), from before wallpapers
    // had working sound with a volume of their own; reading one leaves the sound on. From schema 4 on, `muted` is the
    // whole app's mute.
    // Files before schema 5 also had a frame rate per display for the wallpapers without their own, and a cap; reading
    // one gives every wallpaper of the library the frame rate it ran at (see `LegacyFrameRate`).
    // Files written by older versions may also hold `sameForBoth` and a `lock` section; both are ignored.

    private enum CodingKeys: String, CodingKey {
        case schema, revision, videos, playlist, displays, stillDelay, masterVolume, presets
        // schema 2
        case desktop, muted, sceneOptions, power
        // schema 1
        case selectedID, rotateEnabled, intervalValue, intervalUnit, applyToDesktop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = LibraryState.currentSchema
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        videos = try c.decodeIfPresent([VideoItem].self, forKey: .videos) ?? []
        stillDelay = LibraryState.clampedStillDelay(
            try c.decodeIfPresent(Double.self, forKey: .stillDelay) ?? Self.defaultStillDelay)
        masterVolume = min(max(try c.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 1, 0), 1)
        presets = try c.decodeIfPresent([String: [WallpaperPreset]].self, forKey: .presets) ?? [:]
        let fileSchema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        muted = fileSchema >= 4 ? try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false : false
        var rates: [String: LegacyFrameRate] = [:]
        if c.contains(.displays) {
            playlist = try c.decodeIfPresent([UUID].self, forKey: .playlist)
            displays = try c.decode([String: DisplayConfig].self, forKey: .displays)
            if fileSchema < 5 { rates = try c.decode([String: LegacyFrameRate].self, forKey: .displays) }
        } else {
            let legacy = try Self.legacyDesktop(c)
            playlist = legacy.playlist
            displays = Self.everyDisplay(legacy.config)
            let rate = try LegacyFrameRate(from: decoder)
            rates = displays.mapValues { _ in rate }
        }
        for (id, rate) in rates {
            displays[id].map { config in displays[id] = rate.applied(to: config, videos: videos) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(revision, forKey: .revision)
        try c.encode(videos, forKey: .videos)
        try c.encodeIfPresent(playlist, forKey: .playlist)
        try c.encode(displays, forKey: .displays)
        try c.encode(stillDelay, forKey: .stillDelay)
        try c.encode(masterVolume, forKey: .masterVolume)
        try c.encode(muted, forKey: .muted)
        try c.encode(presets, forKey: .presets)
    }

    /// `config` for every display connected now (DisplayIdentity.active).
    public static func everyDisplay(_ config: DisplayConfig) -> [String: DisplayConfig] {
        Dictionary(DisplayIdentity.active().map { ($0, config) }, uniquingKeysWith: { first, _ in first })
    }

    /// The single desktop setting of a schema 1 or 2 file.
    private static func legacyDesktop(_ c: KeyedDecodingContainer<CodingKeys>) throws
        -> (playlist: [UUID]?, config: DisplayConfig) {
        let desktop: LegacyDesktop
        if c.contains(.desktop) {
            desktop = try c.decode(LegacyDesktop.self, forKey: .desktop)
        } else {
            // Schema 1: the same fields at the top level, with `applyToDesktop` for `enabled`.
            desktop = LegacyDesktop(
                enabled: try c.decodeIfPresent(Bool.self, forKey: .applyToDesktop) ?? true,
                selectedID: try c.decodeIfPresent(UUID.self, forKey: .selectedID),
                rotateEnabled: try c.decodeIfPresent(Bool.self, forKey: .rotateEnabled) ?? true,
                intervalValue: try c.decodeIfPresent(Int.self, forKey: .intervalValue) ?? 5,
                intervalUnit: try c.decodeIfPresent(IntervalUnit.self, forKey: .intervalUnit) ?? .minutes)
        }
        let config = DisplayConfig(
            wallpaperID: desktop.enabled ? desktop.selectedID : nil,
            rotateEnabled: desktop.rotateEnabled,
            intervalValue: desktop.intervalValue,
            intervalUnit: desktop.intervalUnit,
            power: try c.decodeIfPresent(PowerOptions.self, forKey: .power) ?? PowerOptions(),
            wallpaperOptions: try c.decodeIfPresent([String: WallpaperOptions].self, forKey: .sceneOptions) ?? [:])
        return (desktop.playlist, config)
    }

    /// The frame rates a display of a file before schema 5 gave its wallpapers: the display's own (`sceneFPS`) for the
    /// wallpapers without one, all of them capped by `power.frameRateCap`. Schema 1 and 2 files hold the same keys at
    /// the top level.
    private struct LegacyFrameRate: Decodable {
        var sceneFPS: Int?
        var power: Power?
        var sceneOptions: [String: Rate]?

        struct Power: Decodable { var frameRateCap: Int? }
        struct Rate: Decodable { var fps: Int? }

        /// `config` with every wallpaper of `videos` set to the frame rate it ran at, where that is not what decoding
        /// gave it.
        func applied(to config: DisplayConfig, videos: [VideoItem]) -> DisplayConfig {
            var config = config
            let cap = power?.frameRateCap.map { max($0, 1) } ?? .max
            for item in videos {
                let key = item.id.uuidString
                let rate = min(sceneOptions?[key]?.fps ?? sceneFPS ?? WallpaperOptions.defaultFPS, cap)
                var options = config.options(for: item.id)
                guard WallpaperOptions.clampedFPS(rate) != options.fps else { continue }
                options.fps = WallpaperOptions.clampedFPS(rate)
                config.wallpaperOptions[key] = options
            }
            return config
        }
    }

    private struct LegacyDesktop: Decodable {
        var enabled = true
        var selectedID: UUID?
        var playlist: [UUID]?
        var rotateEnabled = false
        var intervalValue = 5
        var intervalUnit = IntervalUnit.minutes

        init(enabled: Bool, selectedID: UUID?, rotateEnabled: Bool, intervalValue: Int, intervalUnit: IntervalUnit) {
            self.enabled = enabled
            self.selectedID = selectedID
            self.rotateEnabled = rotateEnabled
            self.intervalValue = intervalValue
            self.intervalUnit = intervalUnit
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, selectedID, playlist, rotateEnabled, intervalValue, intervalUnit
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            selectedID = try c.decodeIfPresent(UUID.self, forKey: .selectedID)
            playlist = try c.decodeIfPresent([UUID].self, forKey: .playlist)
            rotateEnabled = try c.decodeIfPresent(Bool.self, forKey: .rotateEnabled) ?? false
            intervalValue = try c.decodeIfPresent(Int.self, forKey: .intervalValue) ?? 5
            intervalUnit = try c.decodeIfPresent(IntervalUnit.self, forKey: .intervalUnit) ?? .minutes
        }
    }

    // MARK: Reads

    public func item(_ id: UUID?) -> VideoItem? {
        guard let id else { return nil }
        return videos.first { $0.id == id }
    }

    /// The display's settings; a display that has none yet gets the defaults.
    public func config(for display: String) -> DisplayConfig { displays[display] ?? DisplayConfig() }

    /// The playlist's wallpapers in order (ids that are no longer in the library are skipped); empty without one.
    public var playlistItems: [VideoItem] { (playlist ?? []).compactMap { item($0) } }

    /// Rotation needs a playlist of at least two wallpapers.
    public var canRotate: Bool { playlistItems.count > 1 }

    /// `display` cycles the playlist.
    public func rotates(_ display: String) -> Bool { config(for: display).rotateEnabled && canRotate }

    // MARK: Writes

    /// Puts `id` on `display`; nil takes its wallpaper away. An id that is not in the library is ignored.
    public mutating func setWallpaper(_ id: UUID?, on display: String) {
        guard id == nil || item(id) != nil else { return }
        displays[display, default: DisplayConfig()].wallpaperID = id
    }

    /// Takes the items out of the library, the playlist and every display (with their wallpaper options and presets).
    public mutating func remove(_ ids: Set<UUID>) {
        for item in videos where ids.contains(item.id) { presets[item.presetKey] = nil }
        videos.removeAll { ids.contains($0.id) }
        playlist = playlist?.filter { !ids.contains($0) }
        for key in displays.keys {
            if let wallpaper = displays[key]?.wallpaperID, ids.contains(wallpaper) { displays[key]?.wallpaperID = nil }
            for id in ids { displays[key]?.wallpaperOptions[id.uuidString] = nil }
        }
    }

    /// Puts `item` in place of the library item `id` (a Workshop item downloaded again gets a new id): the
    /// playlist and every display that used the old one use the new one, with the same wallpaper options.
    public mutating func replace(_ id: UUID, with item: VideoItem) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        videos[index] = item
        guard item.id != id else { return }
        playlist = playlist?.map { $0 == id ? item.id : $0 }
        for key in displays.keys {
            if displays[key]?.wallpaperID == id { displays[key]?.wallpaperID = item.id }
            if let options = displays[key]?.wallpaperOptions.removeValue(forKey: id.uuidString) {
                displays[key]?.wallpaperOptions[item.id.uuidString] = options
            }
        }
    }
}

// MARK: - File locations

public enum AppPaths {
    private static let applicationSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// ~/Library/Application Support/WallpaperMage
    public static let supportDirectory = applicationSupport
        .appendingPathComponent("WallpaperMage", isDirectory: true)
    public static let stateFile = supportDirectory.appendingPathComponent("state.json")
    public static let agentFile = supportDirectory.appendingPathComponent("agent.json")
    /// Imported Workshop items: Library/<workshop id>/<video, preview, project.json>.
    public static let libraryDirectory = supportDirectory.appendingPathComponent("Library", isDirectory: true)
    /// The stills the service sets as each display's system wallpaper (WallpaperStills in the service).
    public static let wallpaperStillsDirectory = supportDirectory
        .appendingPathComponent("WallpaperStills", isDirectory: true)
    /// Apple's original Aerial files, set aside by older versions for their lock-screen video. The service puts
    /// them back at launch (LegacyLockScreen).
    public static let backupsDirectory = supportDirectory.appendingPathComponent("Backups", isDirectory: true)
    /// Lock-screen stills of older versions; deleted at launch.
    public static let legacyStillsDirectory = supportDirectory.appendingPathComponent("Stills", isDirectory: true)
    /// Where Apple keeps downloaded Aerial videos.
    public static let aerialVideosDirectory = applicationSupport
        .appendingPathComponent("com.apple.wallpaper/aerials/videos", isDirectory: true)
    /// Transient steamcmd download area. No spaces in the path on purpose (steamcmd argument parsing).
    public static let steamStagingDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WallpaperMageSteam", isDirectory: true)

    /// Where the app installs Valve's SteamCMD itself (downloaded on first use, never bundled).
    public static let steamToolsDirectory = supportDirectory.appendingPathComponent("SteamCMD", isDirectory: true)
    /// HOME for the app's own SteamCMD runs, so its cached login lives here and nowhere else (UNVERIFIED that
    /// SteamCMD honours HOME on macOS).
    public static let steamHomeDirectory = supportDirectory.appendingPathComponent("SteamHome", isDirectory: true)
    /// Wallpaper Engine's shared assets, fetched with the user's own account (optional).
    public static let sharedAssetsDirectory = supportDirectory
        .appendingPathComponent("WallpaperEngineAssets", isDirectory: true)

    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// True when `url` lies inside the imported-Workshop library folder (the only files the app may delete).
    public static func isInsideLibrary(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(libraryDirectory.standardizedFileURL.path + "/")
    }
}

// MARK: - State store

public enum StateStore {
    /// Reads state.json (files of older schemas are migrated in memory). Returns nil if it is missing; an unreadable
    /// file is moved aside (never overwritten).
    public static func load() -> LibraryState? {
        guard let data = try? Data(contentsOf: AppPaths.stateFile) else { return nil }
        if let state = try? JSONDecoder().decode(LibraryState.self, from: data) { return state }
        let aside = AppPaths.supportDirectory
            .appendingPathComponent("state.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: AppPaths.stateFile, to: aside)
        return nil
    }

    /// The `schema` number inside state.json as written (1 for a file without one); nil when there is no file.
    public static func diskSchema() -> Int? {
        guard let data = try? Data(contentsOf: AppPaths.stateFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["schema"] as? Int ?? 1
    }

    /// Writes state.json atomically and bumps `state.revision` past anything already on disk. The app's `muted` is
    /// not changed by a commit: the value on disk wins (it is changed only by `setMuted`, which the service's menu
    /// also uses). Returns false if the file could not be written.
    @discardableResult
    public static func commit(_ state: inout LibraryState) -> Bool {
        let onDisk = load()
        if let onDisk { state.muted = onDisk.muted }
        state.revision = max(state.revision, onDisk?.revision ?? 0) + 1
        state.schema = LibraryState.currentSchema
        return write(state)
    }

    /// The only write besides `commit`: mutes or unmutes every wallpaper (read, change, write, revision + 1). Returns
    /// the written state, nil on failure.
    @discardableResult
    public static func setMuted(_ muted: Bool) -> LibraryState? {
        var state = load() ?? LibraryState()
        guard state.muted != muted || diskSchema() == nil else { return state }
        state.muted = muted
        state.revision += 1
        return write(state) ? state : nil
    }

    private static func write(_ state: LibraryState) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return false }
        do {
            try AppPaths.ensureDirectory(AppPaths.supportDirectory)
            try data.write(to: AppPaths.stateFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Settings app only: loads state.json (rewriting a file of an older schema once, after keeping a copy as
    /// state.v<schema>-backup.json), or writes an empty library when there is none.
    public static func loadOrMigrate() -> LibraryState {
        if var state = load() {
            if let schema = diskSchema(), schema < LibraryState.currentSchema {
                let backup = AppPaths.supportDirectory.appendingPathComponent("state.v\(schema)-backup.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.copyItem(at: AppPaths.stateFile, to: backup)
                }
                commit(&state)
            }
            return state
        }
        var state = LibraryState()
        commit(&state)
        return state
    }
}

// MARK: - Agent record (agent.json, written only by the agent)

public struct AgentRecord: Codable, Equatable, Sendable {
    /// Aerial files an older version swapped for its lock-screen video; LegacyLockScreen puts Apple's back.
    public var aerialSlots: [String]
    /// The still each display was last given as its system wallpaper (a file name in
    /// AppPaths.wallpaperStillsDirectory), keyed by display UUID. A display that is not connected keeps its file.
    public var stills: [String: String]

    public init(aerialSlots: [String] = [], stills: [String: String] = [:]) {
        self.aerialSlots = aerialSlots
        self.stills = stills
    }

    private enum CodingKeys: String, CodingKey { case aerialSlots, stills }

    // Every key may be missing: older versions wrote other fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aerialSlots = try c.decodeIfPresent([String].self, forKey: .aerialSlots) ?? []
        stills = try c.decodeIfPresent([String: String].self, forKey: .stills) ?? [:]
    }
}

public enum AgentRecordStore {
    /// Never fails. Without a readable agent.json it starts (and writes) an empty record.
    public static func load() -> AgentRecord {
        if let data = try? Data(contentsOf: AppPaths.agentFile) {
            if let record = try? JSONDecoder().decode(AgentRecord.self, from: data) { return record }
            let aside = AppPaths.supportDirectory
                .appendingPathComponent("agent.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: AppPaths.agentFile, to: aside)
        }
        let record = AgentRecord()
        save(record)
        return record
    }

    public static func save(_ record: AgentRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? AppPaths.ensureDirectory(AppPaths.supportDirectory)
        try? data.write(to: AppPaths.agentFile, options: .atomic)
    }

    public static func update(_ body: (inout AgentRecord) -> Void) {
        var record = load()
        body(&record)
        save(record)
    }

    /// Originals waiting in Backups/. Restoring from this listing works even when no record survived,
    /// so Apple's files cannot be stranded by a lost or unreadable record.
    public static func backupSlotsOnDisk() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.backupsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "mov" }.map(\.lastPathComponent).sorted()
    }
}

// MARK: - Frame extraction

public enum VideoStills {
    /// A still from `url` (frame at min(1 s, duration / 2), transform applied); nil on failure.
    /// `maxPixelSize` nil = native size. Runs off the main actor.
    public static func cgImage(for url: URL, maxPixelSize: CGSize?) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize { generator.maximumSize = maxPixelSize }
        let seconds = duration.seconds
        let time = CMTime(seconds: seconds.isFinite ? min(1, seconds / 2) : 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
