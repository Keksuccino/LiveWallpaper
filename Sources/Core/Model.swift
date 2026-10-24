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

    public var label: String {
        switch self {
        case .seconds: return "Seconds"
        case .minutes: return "Minutes"
        case .hours: return "Hours"
        }
    }

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

// MARK: - Library + settings (state.json, written only by the Settings app)

/// What the desktop plays and how it rotates. The lock screen shows the system wallpaper, which the service sets to
/// a still of the desktop's wallpaper.
public struct PlaybackConfig: Codable, Equatable, Sendable {
    public var enabled: Bool              // false = the desktop is left alone (Apple's wallpaper stays)
    public var selectedID: UUID?          // starting / current choice
    public var playlist: [UUID]?          // nil = every library item in library order; else this order
    public var rotateEnabled: Bool
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit

    public init(enabled: Bool = true, selectedID: UUID? = nil, playlist: [UUID]? = nil, rotateEnabled: Bool = false,
                intervalValue: Int = 5, intervalUnit: IntervalUnit = .minutes) {
        self.enabled = enabled
        self.selectedID = selectedID
        self.playlist = playlist
        self.rotateEnabled = rotateEnabled
        self.intervalValue = intervalValue
        self.intervalUnit = intervalUnit
    }

    public var intervalSeconds: TimeInterval {
        max(LibraryState.minimumInterval, Double(intervalValue) * intervalUnit.multiplier)
    }
    public var intervalIsClamped: Bool {
        Double(intervalValue) * intervalUnit.multiplier < LibraryState.minimumInterval
    }
}

public struct LibraryState: Codable, Equatable, Sendable {
    public static let minimumInterval: TimeInterval = 5
    public static let currentSchema = 2

    public var schema: Int
    public var revision: Int          // bumped by StateStore.commit on every write
    public var videos: [VideoItem]    // the whole library (videos and scenes); the name is a phase-1 leftover
    public var muted: Bool            // default true; changed only through StateStore.setMuted
    public var sceneFPS: Int          // frame rate cap for live scenes; the agent lowers it on battery
    public var sceneZoom: Double      // 1 = as authored; below 1 shows more of the scene (edges go black), above crops in
    public var desktop: PlaybackConfig
    public var sceneOptions: [String: SceneOptions] = [:]   // per scene, keyed by VideoItem.id.uuidString
    public var power: PowerOptions = PowerOptions()           // global scene settings
    /// Seconds the service waits before it makes a new still for the system wallpaper (see `stillDelayOptions`).
    public var stillDelay: Double = LibraryState.defaultStillDelay

    public init(schema: Int = LibraryState.currentSchema, revision: Int = 0, videos: [VideoItem] = [],
                muted: Bool = true, sceneFPS: Int = LibraryState.defaultSceneFPS, sceneZoom: Double = 1.0,
                desktop: PlaybackConfig = PlaybackConfig()) {
        self.schema = schema
        self.revision = revision
        self.videos = videos
        self.muted = muted
        self.sceneFPS = LibraryState.clampedSceneFPS(sceneFPS)
        self.sceneZoom = LibraryState.clampedSceneZoom(sceneZoom)
        self.desktop = desktop
    }

    public static let defaultSceneFPS = 30
    public static func clampedSceneFPS(_ fps: Int) -> Int { min(max(fps, 10), 120) }
    public static func clampedSceneZoom(_ zoom: Double) -> Double { min(max(zoom, 0.5), 2.0) }

    /// The choices for `stillDelay`. The wait exists because a slider in Settings sends a change for every step, and
    /// a scene's still loads the whole scene a second time: waiting lets the drag finish before one still is made,
    /// and gives a new wallpaper time to start before its still competes with it for the machine.
    public static let stillDelayOptions: [Double] = [0, 0.5, 1, 2, 5]
    public static let defaultStillDelay: Double = 2
    public static func clampedStillDelay(_ seconds: Double) -> Double { min(max(seconds, 0), 5) }

    // MARK: Codable with v1 migration (schema 1 files have no desktop section)
    // Files written by older versions also hold `sameForBoth` and a `lock` section; both are ignored.

    private enum CodingKeys: String, CodingKey {
        case schema, revision, videos, muted, sceneFPS, sceneZoom, desktop, sceneOptions, power, stillDelay
        // schema 1 only
        case selectedID, rotateEnabled, intervalValue, intervalUnit, applyToDesktop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let diskSchema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        videos = try c.decodeIfPresent([VideoItem].self, forKey: .videos) ?? []
        schema = LibraryState.currentSchema
        sceneFPS = LibraryState.clampedSceneFPS(try c.decodeIfPresent(Int.self, forKey: .sceneFPS) ?? Self.defaultSceneFPS)
        sceneZoom = LibraryState.clampedSceneZoom(try c.decodeIfPresent(Double.self, forKey: .sceneZoom) ?? 1.0)
        sceneOptions = try c.decodeIfPresent([String: SceneOptions].self, forKey: .sceneOptions) ?? [:]
        power = try c.decodeIfPresent(PowerOptions.self, forKey: .power) ?? PowerOptions()
        stillDelay = LibraryState.clampedStillDelay(
            try c.decodeIfPresent(Double.self, forKey: .stillDelay) ?? Self.defaultStillDelay)
        if diskSchema >= 2 || c.contains(.desktop) {
            muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? true
            desktop = try c.decodeIfPresent(PlaybackConfig.self, forKey: .desktop) ?? PlaybackConfig()
        } else {
            // v1: one selection / rotation setting and an "apply to desktop" flag.
            let selected = try c.decodeIfPresent(UUID.self, forKey: .selectedID)
            let rotate = try c.decodeIfPresent(Bool.self, forKey: .rotateEnabled) ?? true
            let value = try c.decodeIfPresent(Int.self, forKey: .intervalValue) ?? 5
            let unit = try c.decodeIfPresent(IntervalUnit.self, forKey: .intervalUnit) ?? .minutes
            let onDesktop = try c.decodeIfPresent(Bool.self, forKey: .applyToDesktop) ?? true
            muted = true
            desktop = PlaybackConfig(enabled: onDesktop, selectedID: selected, rotateEnabled: rotate,
                                     intervalValue: value, intervalUnit: unit)
        }
        desktop.intervalValue = LibraryState.clampedInterval(desktop.intervalValue)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(revision, forKey: .revision)
        try c.encode(videos, forKey: .videos)
        try c.encode(muted, forKey: .muted)
        try c.encode(sceneFPS, forKey: .sceneFPS)
        try c.encode(sceneZoom, forKey: .sceneZoom)
        try c.encode(sceneOptions, forKey: .sceneOptions)
        try c.encode(power, forKey: .power)
        try c.encode(stillDelay, forKey: .stillDelay)
        try c.encode(desktop, forKey: .desktop)
    }

    // MARK: Reads

    /// True when `id` is a library scene (a live-rendered Wallpaper Engine wallpaper).
    public func isScene(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return videos.first { $0.id == id }?.isScene == true
    }

    /// The items the desktop rotates through: the playlist (ids that no longer exist are skipped) or the library.
    public var items: [VideoItem] {
        guard let ids = desktop.playlist else { return videos }
        return ids.compactMap { id in videos.first { $0.id == id } }
    }

    public var selectedItem: VideoItem? { items.first { $0.id == desktop.selectedID } }
    /// The desktop is enabled and has something to play.
    public var canPlay: Bool { desktop.enabled && !items.isEmpty }
    public var hasMultipleItems: Bool { items.count > 1 }
    /// Rotation only ever cycles a playlist the user curated. Without one, the selected wallpaper stays.
    public var rotates: Bool { desktop.playlist != nil && desktop.rotateEnabled && hasMultipleItems }

    /// Something can be played: a non-empty library and the desktop enabled.
    public var canStart: Bool { !videos.isEmpty && desktop.enabled }

    // MARK: Writes

    /// Selects `id` and turns the desktop on. An id that is not in the library is ignored.
    public mutating func assign(_ id: UUID) {
        guard videos.contains(where: { $0.id == id }) else { return }
        desktop.selectedID = id
        desktop.enabled = true
    }

    // MARK: Shortcuts to the desktop config (the Settings app binds to these)

    public var selectedID: UUID? {
        get { desktop.selectedID }
        set { desktop.selectedID = newValue }
    }
    public var rotateEnabled: Bool {
        get { desktop.rotateEnabled }
        set { desktop.rotateEnabled = newValue }
    }
    public var intervalValue: Int {
        get { desktop.intervalValue }
        set { desktop.intervalValue = newValue }
    }
    public var intervalUnit: IntervalUnit {
        get { desktop.intervalUnit }
        set { desktop.intervalUnit = newValue }
    }
    public var applyToDesktop: Bool {
        get { desktop.enabled }
        set { desktop.enabled = newValue }
    }
    public var intervalSeconds: TimeInterval { desktop.intervalSeconds }
    public var intervalIsClamped: Bool { desktop.intervalIsClamped }

    public static func clampedInterval(_ value: Int) -> Int {
        min(max(value, 1), 999)
    }
}

// MARK: - File locations

public enum AppPaths {
    private static let applicationSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// ~/Library/Application Support/LiveWallpaper
    public static let supportDirectory = applicationSupport
        .appendingPathComponent("LiveWallpaper", isDirectory: true)
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
        .appendingPathComponent("LiveWallpaperSteam", isDirectory: true)

    /// Where the app installs Valve's SteamCMD itself (downloaded on first use, never bundled).
    public static let steamToolsDirectory = supportDirectory.appendingPathComponent("SteamCMD", isDirectory: true)
    /// HOME for the app's own SteamCMD runs, so its cached login lives here and nowhere else (UNVERIFIED that
    /// SteamCMD honours HOME on macOS, see SPEC3.md section 4).
    public static let steamHomeDirectory = supportDirectory.appendingPathComponent("SteamHome", isDirectory: true)
    /// Wallpaper Engine's shared assets, fetched with the user's own account (optional, SPEC3.md section 4.8).
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
    public static let phase1DefaultsKey = "LiveWallpaper.state.v1"
    private static let importedFlagKey = "LiveWallpaper.v2.importedPhase1"

    /// Reads state.json (schema 1 files are migrated in memory). Returns nil if it is missing; an unreadable file
    /// is moved aside (never overwritten).
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

    /// Writes state.json atomically and bumps `state.revision` past anything already on disk.
    /// Settings app only. `muted` is not changed by a commit: the value on disk wins (it is changed only by
    /// `setMuted`, which the agent's menu also uses). Returns false if the file could not be written.
    @discardableResult
    public static func commit(_ state: inout LibraryState) -> Bool {
        let onDisk = load()
        if let onDisk { state.muted = onDisk.muted }
        state.revision = max(state.revision, onDisk?.revision ?? 0) + 1
        state.schema = LibraryState.currentSchema
        return write(state)
    }

    /// The only write besides `commit`: changes `muted` in state.json (read, change, write, revision + 1).
    /// May be called from the Settings app and from the agent. Returns the written state, nil on failure.
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

    /// Settings app only: loads state.json (rewriting a schema 1 file as schema 2 once, after keeping a copy as
    /// state.v1-backup.json), or imports the phase-1 library from its UserDefaults once
    /// (the Settings app has the phase-1 bundle id, so `.standard` is the phase-1 domain).
    public static func loadOrMigrate(defaults: UserDefaults = .standard) -> (state: LibraryState, importedCount: Int) {
        if var state = load() {
            if let schema = diskSchema(), schema < LibraryState.currentSchema {
                let backup = AppPaths.supportDirectory.appendingPathComponent("state.v1-backup.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.copyItem(at: AppPaths.stateFile, to: backup)
                }
                commit(&state)
            }
            return (state, 0)
        }
        var state = LibraryState()
        var imported = 0
        if !defaults.bool(forKey: importedFlagKey),
           let data = defaults.data(forKey: phase1DefaultsKey),
           let old = try? JSONDecoder().decode(Phase1State.self, from: data) {
            let value = LibraryState.clampedInterval(old.intervalValue)
            state = LibraryState(
                videos: old.videos,
                desktop: PlaybackConfig(enabled: old.applyToDesktop, selectedID: old.selectedID,
                                        rotateEnabled: old.rotateEnabled, intervalValue: value,
                                        intervalUnit: old.intervalUnit))
            imported = old.videos.count
        }
        defaults.set(true, forKey: importedFlagKey)
        commit(&state)
        return (state, imported)
    }

    // Shape of the phase-1 UserDefaults blob (LiveWallpaper.state.v1).
    private struct Phase1State: Decodable {
        var videos: [VideoItem]
        var selectedID: UUID?
        var rotateEnabled: Bool
        var intervalValue: Int
        var intervalUnit: IntervalUnit
        var applyToDesktop: Bool
    }
}

// MARK: - Agent record (agent.json, written only by the agent)

public struct AgentRecord: Codable, Equatable, Sendable {
    public var wantsRunning: Bool    // resume playing when the agent launches
    /// Aerial files an older version swapped for its lock-screen video; LegacyLockScreen puts Apple's back.
    public var aerialSlots: [String]
    public var legacyImported: Bool

    public init(wantsRunning: Bool = false, aerialSlots: [String] = [], legacyImported: Bool = false) {
        self.wantsRunning = wantsRunning
        self.aerialSlots = aerialSlots
        self.legacyImported = legacyImported
    }
}

public enum AgentRecordStore {
    private static let legacyDomain = "com.noob3301.LiveWallpaper"

    /// Never fails. The first call without agent.json imports the phase-1 records (wasRunning, aerial backup)
    /// from the old app's preferences domain, which the old app never clears on its own.
    public static func load() -> AgentRecord {
        if let data = try? Data(contentsOf: AppPaths.agentFile) {
            if let record = try? JSONDecoder().decode(AgentRecord.self, from: data) { return record }
            let aside = AppPaths.supportDirectory
                .appendingPathComponent("agent.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: AppPaths.agentFile, to: aside)
        }
        var record = AgentRecord()
        record.legacyImported = true
        if let data = legacyData("LiveWallpaper.aerialBackup.v1"),
           let backup = try? JSONDecoder().decode(LegacyBackup.self, from: data) {
            record.aerialSlots = backup.slots
        }
        if let data = legacyData("LiveWallpaper.state.v1"),
           let running = try? JSONDecoder().decode(LegacyRunning.self, from: data) {
            record.wantsRunning = running.wasRunning ?? false
        }
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

    private static func legacyData(_ key: String) -> Data? {
        CFPreferencesCopyAppValue(key as CFString, legacyDomain as CFString) as? Data
    }

    // Phase 1 recorded a single `slot` before it recorded `slots`.
    private struct LegacyBackup: Decodable {
        var slots: [String]

        private enum CodingKeys: String, CodingKey { case slots, slot }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            slots = try container.decodeIfPresent([String].self, forKey: .slots)
                ?? [container.decode(String.self, forKey: .slot)]
        }
    }

    private struct LegacyRunning: Decodable { var wasRunning: Bool? }
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
