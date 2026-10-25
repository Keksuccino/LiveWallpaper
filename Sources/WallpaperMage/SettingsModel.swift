import Foundation
import AppKit
import Combine
import Core
import SceneFormat

// The Settings app's model. It holds the library and settings the user edits and the status the service reports;
// it never plays anything and never writes state.json. Every change is sent to the service as `.commit`.

@MainActor final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    // Persisted in state.json; UI-bound. Every change is sent to the service (`.commit`). Bulk changes go through
    // `batch` (one write) and never write while loading.
    @Published var videos: [VideoItem] = [] { didSet { persist() } }
    /// The user's playlists (LibraryState.playlists); edited through the playlist methods below.
    @Published private(set) var playlists: [Playlist] = [] { didSet { persist() } }
    /// Per display (LibraryState.displays).
    @Published private(set) var displays: [String: DisplayConfig] = [:] { didSet { persist() } }
    @Published var stillDelay: Double = LibraryState.defaultStillDelay { didSet { persist() } }
    /// Scales every wallpaper's own volume (LibraryState.masterVolume).
    @Published var masterVolume: Double = 1 { didSet { persist() } }
    /// Saved presets per wallpaper (LibraryState.presets).
    @Published private(set) var presets: [String: [WallpaperPreset]] = [:] { didSet { persist() } }
    /// Every wallpaper is silent (LibraryState.muted). The service owns it (its menu toggles it too): it changes
    /// through `setMuted`, never by a commit.
    @Published private(set) var muted = false

    /// The connected displays, as arranged in System Settings > Displays. UI state only.
    @Published private(set) var screens: [ScreenInfo] = []
    /// The display Home and its inspector configure: the leftmost one unless the user picked another. UI state only.
    @Published var selectedDisplayID: String?
    /// A library item Home scrolls to and highlights once (Show in Library in the Workshop); Home then leaves the
    /// playlist editor. UI state only.
    @Published var focusedID: VideoItem.ID? = nil {
        didSet { if focusedID != nil { editingPlaylistID = nil } }
    }
    /// The playlist Home shows its editor for instead of the library. UI state only.
    @Published var editingPlaylistID: Playlist.ID?

    // Service mirror (read-only for views).
    /// A command the service answered with an error; cleared by clearStatus(). A service that cannot be reached
    /// is ServiceClient.problem instead.
    @Published private(set) var localMessage: String? = nil

    private var serviceStatus: ServiceStatus? { client.status }
    var statusMessage: String? { localMessage ?? serviceStatus?.message }

    /// The persisted fields as one value (what gets written to state.json).
    var snapshot: LibraryState {
        // Starts from what state.json last held so fields this model does not edit survive.
        var state = written
        state.videos = videos
        state.playlists = playlists
        state.displays = displays
        state.stillDelay = stillDelay
        state.masterVolume = masterVolume
        state.presets = presets
        return state
    }

    // MARK: Displays

    var selectedScreen: ScreenInfo? { screens.first { $0.id == selectedDisplayID } }

    func config(for display: String) -> DisplayConfig { displays[display] ?? DisplayConfig() }

    /// What `display` is set to show: a wallpaper, a playlist or nothing.
    func content(on display: String) -> DisplayContent? { config(for: display).content }

    /// The playlist `display` plays.
    func playlist(on display: String) -> Playlist? { playlist(content(on: display)?.playlistID) }

    /// What the service shows live on `display` (a playlist moves on by itself).
    func liveItem(on display: String) -> VideoItem? { snapshot.item(serviceStatus?.display(display)?.itemID) }

    /// What `display` shows: its live item, else its wallpaper or its playlist's first wallpaper.
    func shownItem(on display: String) -> VideoItem? { liveItem(on: display) ?? snapshot.lineup(on: display).first }

    /// How `display` shows `id` right now: with its playlist's options while it plays one that has it.
    func shownOptions(on display: String, for id: UUID) -> WallpaperOptions { snapshot.options(for: id, on: display) }

    /// The picture of `display`'s system wallpaper, and the library item it is a still of (nil: another picture).
    func systemWallpaper(on display: String) -> (url: URL, stillOf: UUID?)? {
        guard let status = serviceStatus?.display(display), let path = status.systemWallpaper else { return nil }
        return (URL(fileURLWithPath: path), status.stillItemID)
    }

    /// Why `display`'s wallpaper could not be shown, as the service reported it.
    func error(on display: String) -> String? { serviceStatus?.display(display)?.error }

    /// Edits one display's settings and commits them to the service.
    func updateDisplay(_ display: String, _ change: (inout DisplayConfig) -> Void) {
        edit { change(&$0.displays[display, default: DisplayConfig()]) }
    }

    /// Puts a wallpaper or a playlist on `display` at once.
    func setContent(_ content: DisplayContent, on display: String) {
        edit { $0.setContent(content, on: display) }
    }

    /// Puts a wallpaper or a playlist on every connected display.
    func setContentOnAllDisplays(_ content: DisplayContent) {
        edit { state in screens.forEach { state.setContent(content, on: $0.id) } }
    }

    /// Takes `display`'s wallpaper or playlist away; the service gives it macOS's default wallpaper.
    func removeContent(from display: String) {
        edit { $0.setContent(nil, on: display) }
    }

    /// Mutes or unmutes every wallpaper.
    func setMuted(_ muted: Bool) {
        guard self.muted != muted else { return }
        self.muted = muted
        written.muted = muted
        send(.setMuted(muted))
    }

    func options(in scope: OptionsScope, for id: UUID) -> WallpaperOptions {
        switch scope {
        case .display(let display): return config(for: display).options(for: id)
        case .playlist(let playlist): return self.playlist(playlist)?.options(for: id) ?? .standard
        }
    }

    /// Edits one wallpaper's options on one display or in one playlist and commits them to the service.
    func updateOptions(in scope: OptionsScope, for id: UUID, _ change: (inout WallpaperOptions) -> Void) {
        switch scope {
        case .display(let display):
            updateDisplay(display) { config in
                var options = config.options(for: id)
                change(&options)
                config.wallpaperOptions[id.uuidString] = options
            }
        case .playlist(let playlist):
            updatePlaylist(playlist) { playlist in
                var options = playlist.options(for: id)
                change(&options)
                playlist.wallpaperOptions[id.uuidString] = options
            }
        }
    }

    // MARK: Presets

    func presets(for item: VideoItem) -> [WallpaperPreset] { presets[item.presetKey] ?? [] }

    /// Saves the item's options in `scope` under `name`; a preset of the same name is replaced.
    func savePreset(named name: String, for item: VideoItem, in scope: OptionsScope) {
        let preset = WallpaperPreset(name: name, options: options(in: scope, for: item.id))
        var list = presets(for: item).filter { $0.name != name }
        list.append(preset)
        presets[item.presetKey] = list
    }

    func deletePreset(_ preset: WallpaperPreset, of item: VideoItem) {
        presets[item.presetKey] = presets(for: item).filter { $0.id != preset.id }
    }

    /// Wallpaper Engine's built-in options of `item` go to every other wallpaper in `scope` (every library wallpaper on
    /// a display, the playlist's wallpapers in a playlist); each keeps its own properties and performance settings.
    func applyBuiltInsToAll(from item: VideoItem, in scope: OptionsScope) {
        let source = options(in: scope, for: item.id)
        switch scope {
        case .display(let display):
            updateDisplay(display) { config in
                for other in videos where other.id != item.id {
                    config.wallpaperOptions[other.id.uuidString] = config.options(for: other.id).withBuiltIns(of: source)
                }
            }
        case .playlist(let playlist):
            updatePlaylist(playlist) { playlist in
                for other in playlist.items where other != item.id {
                    playlist.wallpaperOptions[other.uuidString] = playlist.options(for: other).withBuiltIns(of: source)
                }
            }
        }
    }

    // MARK: Playlists

    func playlist(_ id: Playlist.ID?) -> Playlist? {
        guard let id else { return nil }
        return playlists.first { $0.id == id }
    }

    /// The playlist's wallpapers in order (ids no longer in the library are skipped).
    func items(of playlist: Playlist) -> [VideoItem] { snapshot.items(of: playlist) }

    /// Makes a playlist of `items` and returns its id. It is called "New Playlist", numbered when that name is taken.
    @discardableResult func createPlaylist(with items: [VideoItem.ID] = []) -> Playlist.ID {
        let names = Set(playlists.map(\.name))
        var name = String(localized: "New Playlist")
        var number = 2
        while names.contains(name) {
            name = String(localized: "New Playlist \(number)")
            number += 1
        }
        let playlist = Playlist(name: name, items: Self.unique(items))
        playlists.append(playlist)
        return playlist.id
    }

    /// Edits a playlist and commits it. A wallpaper stays in a playlist once, and the options of wallpapers that left
    /// it go with them.
    func updatePlaylist(_ id: Playlist.ID, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var playlist = playlists[index]
        change(&playlist)
        playlist.items = Self.unique(playlist.items)
        let kept = Set(playlist.items.map(\.uuidString))
        playlist.wallpaperOptions = playlist.wallpaperOptions.filter { kept.contains($0.key) }
        playlist.intervalValue = Playlist.clampedInterval(playlist.intervalValue)
        playlist.transitionDuration = Playlist.clampedTransitionDuration(playlist.transitionDuration)
        if playlist != playlists[index] { playlists[index] = playlist }
    }

    /// Adds wallpapers to the end of a playlist (those already in it stay where they are).
    func addToPlaylist(_ id: Playlist.ID, items: [VideoItem.ID]) {
        updatePlaylist(id) { $0.items += items }
    }

    /// Deletes a playlist and its picture; the displays that played it get macOS's default wallpaper back.
    func deletePlaylist(_ id: Playlist.ID) {
        let image = playlist(id)?.imageURL
        edit { $0.removePlaylist(id) }
        if editingPlaylistID == id { editingPlaylistID = nil }
        if let image { try? FileManager.default.removeItem(at: image) }
    }

    /// Makes the picture at `url` the playlist's own (a scaled-down copy, see PlaylistImage). False when it could not
    /// be read as a picture.
    func setPlaylistImage(_ id: Playlist.ID, from url: URL) async -> Bool {
        let name = await Task.detached(priority: .userInitiated) { PlaylistImage.store(url) }.value
        guard let name else { return false }
        guard let old = playlist(id) else {
            try? FileManager.default.removeItem(at: AppPaths.playlistImagesDirectory.appendingPathComponent(name))
            return false
        }
        updatePlaylist(id) { $0.image = name }
        if let previous = old.imageURL { try? FileManager.default.removeItem(at: previous) }
        return true
    }

    /// The playlist shows its wallpapers' previews again; its own picture is deleted.
    func clearPlaylistImage(_ id: Playlist.ID) {
        guard let previous = playlist(id)?.imageURL else { return }
        updatePlaylist(id) { $0.image = nil }
        try? FileManager.default.removeItem(at: previous)
    }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    let client = ServiceClient.shared
    private var written = LibraryState()           // what state.json last held, revision included
    private var writesSuspended = false
    /// A commit could not be sent because the service was not connected; it goes out once the service answers.
    private var commitPending = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var clientWatch: [AnyCancellable] = []

    // Loads state only; bootstrap() starts the first real work.
    init() {}

    // MARK: Lifecycle (called by AppDelegate)

    /// Once, from applicationDidFinishLaunching: reads the library (to show it before the service answers),
    /// and connects to the service. Never writes state.json.
    func bootstrap() {
        let loaded = StateStore.loadOrMigrate()
        batch(persisting: false) { apply(loaded) }
        written = loaded
        refreshScreens()
        reanalyzeStaleScenes()
        clientWatch = [
            client.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            client.$status.compactMap { $0 }.sink { [weak self] status in self?.statusReceived(status) },
        ]
        observeSystem()
        client.start()
    }

    /// From applicationWillTerminate. Does not stop the service.
    func shutdown() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        clientWatch = []
        client.stop()
    }

    // MARK: Library intents

    /// Filters non-video, dedupes by path and appends. Returns the number added.
    @discardableResult func addVideos(urls: [URL]) -> Int {
        var knownPaths = Set(videos.map(\.path))
        var added: [VideoItem] = []
        for url in urls where VideoItem.isVideo(url) {
            let item = VideoItem(url: url)
            if knownPaths.insert(item.path).inserted { added.append(item) }
        }
        guard !added.isEmpty else { return 0 }
        videos += added
        return added.count
    }

    /// Called by the Workshop importer with a finished item (files already in AppPaths.libraryDirectory).
    /// A re-download replaces the earlier copy of the same Workshop item in place, on every display that shows it.
    func addImported(_ item: VideoItem) {
        edit { state in
            if let old = state.videos.first(where: { $0.workshopID != nil && $0.workshopID == item.workshopID }) {
                state.replace(old.id, with: item)
            } else {
                state.videos.append(item)
            }
        }
    }

    func hasWorkshopItem(_ workshopID: String) -> Bool {
        videos.contains { $0.workshopID == workshopID }
    }

    /// Removes from the library, every playlist and every display (which gets macOS's default wallpaper back).
    /// Files are deleted only when AppPaths.isInsideLibrary(item.url) (imported Workshop copies); a local video is
    /// never touched.
    func remove(ids: Set<VideoItem.ID>) {
        let removed = videos.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        edit { $0.remove(ids) }
        for item in removed { Self.deleteDownloadedFiles(of: item) }
    }

    // MARK: Service intents

    func restartService() { Task { await client.restart() } }

    func clearStatus() {
        localMessage = nil
    }

    // MARK: Persistence

    /// Applies `change` to a copy of the persisted fields and commits the result once.
    private func edit(_ change: (inout LibraryState) -> Void) {
        var state = snapshot
        change(&state)
        guard state != snapshot else { return }
        batch { apply(state) }
    }

    /// Runs `body` with writes suspended, then commits once (unless `persisting` is false).
    private func batch(persisting: Bool = true, _ body: () -> Void) {
        writesSuspended = true
        body()
        writesSuspended = false
        if persisting { persist() }
    }

    /// Commits the persisted fields when they differ from what was last sent (`force`: in any case).
    private func persist(force: Bool = false) {
        guard !writesSuspended else { return }
        var state = snapshot
        state.revision = written.revision
        guard force || state != written else { return }
        written = state
        send(.commit(state))   // the service writes state.json and bumps the revision
    }

    /// Scenes analysed by an older analyzer get a fresh support verdict (off the main thread; the files are tiny
    /// to read but can be large to scan).
    private func reanalyzeStaleScenes() {
        let stale = videos.filter { ($0.scene?.analysisRevision).map { $0 != SceneAnalysis.revision } ?? false }
        guard !stale.isEmpty else { return }
        Task { @MainActor [weak self] in
            let fresh = await Task.detached(priority: .utility) { stale.map { SceneImporter.reanalyze($0) } }.value
            self?.replace(fresh)
        }
    }

    private func replace(_ items: [VideoItem]) {
        batch {
            for item in items {
                if let index = videos.firstIndex(where: { $0.id == item.id }) { videos[index] = item }
            }
        }
    }

    private func apply(_ state: LibraryState) {
        videos = state.videos
        playlists = state.playlists
        displays = state.displays
        stillDelay = state.stillDelay
        masterVolume = state.masterVolume
        presets = state.presets
        muted = state.muted
    }

    private static func deleteDownloadedFiles(of item: VideoItem) {
        let file = item.url.standardizedFileURL
        guard AppPaths.isInsideLibrary(file) else { return }
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: AppPaths.isInsideLibrary(folder) ? folder : file)
    }

    // MARK: Service

    /// Sends a command. An error the service answers with shows up as `localMessage`; without a connection the
    /// sidebar already says so, and a commit is sent again once the service answers.
    private func send(_ command: ServiceCommand) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.client.perform(command)
                if case .commit = command { self.written.revision = max(self.written.revision, status.stateRevision) }
            } catch {
                if self.client.state == .connected {
                    self.localMessage = error.localizedDescription
                } else if case .commit = command {
                    self.commitPending = true
                }
            }
        }
    }

    /// A status arrived (reply or push): the service owns the app's `muted` (its menu can toggle it).
    private func statusReceived(_ status: ServiceStatus) {
        if commitPending {
            commitPending = false
            persist(force: true)
        }
        muted = status.muted
        written.muted = status.muted
    }

    // MARK: Screens

    /// Reads the connected displays and keeps a valid display selected.
    private func refreshScreens() {
        screens = NSScreen.screens.map { ScreenInfo(id: $0.displayID, name: $0.localizedName, frame: $0.frame) }
        if selectedScreen == nil {
            selectedDisplayID = screens.min { ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY) }?.id
        }
    }

    // MARK: Workspace

    private func observeSystem() {
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshScreens() }
        }
        observers.append((NotificationCenter.default, screens))
    }

    // MARK: Other processes

    /// Other running copies of this app's bundle id.
    static func otherInstances() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.settingsBundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
    }
}

/// Whose options a wallpaper's settings edit: a display's (for the wallpaper shown there on its own) or a playlist's.
enum OptionsScope: Hashable {
    case display(String)
    case playlist(Playlist.ID)
}

/// A connected display.
struct ScreenInfo: Identifiable, Equatable {
    /// The display's UUID (DisplayIdentity), the key of its settings.
    let id: String
    let name: String
    /// In the global screen space (points, origin at the bottom-left of the main display).
    let frame: CGRect
}

extension NSScreen {
    /// The display's UUID (DisplayIdentity): the key of its settings in state.json.
    var displayID: String {
        let number = (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return DisplayIdentity.uuid(of: number)
    }
}
