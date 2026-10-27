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
    /// Scenes react to what the Mac plays (LibraryState.audioResponse).
    @Published var audioResponse = true { didSet { persist() } }
    /// Saved presets per wallpaper (LibraryState.presets).
    @Published private(set) var presets: [String: [WallpaperPreset]] = [:] { didSet { persist() } }
    /// Every wallpaper is silent (LibraryState.muted). The service owns it (its menu toggles it too): it changes
    /// through `setMuted`, never by a commit.
    @Published private(set) var muted = false

    /// The connected displays, as arranged in System Settings > Displays. UI state only.
    @Published private(set) var screens: [ScreenInfo] = []
    /// The display Home and its inspector configure: the leftmost one unless the user picked another. UI state only.
    @Published var selectedDisplayID: String?
    /// A library item Home scrolls to and highlights once (Show in Library in the Workshop). UI state only.
    @Published var focusedID: VideoItem.ID? = nil
    /// The kinds of content Home's library leaves out (its filter buttons); empty shows everything. UI state only.
    @Published var hiddenLibraryKinds: Set<LibraryKind> = []
    /// The playlist editor Home shows instead of the library; nil while it is closed. UI state only.
    @Published private(set) var playlistEdit: PlaylistEdit?
    /// A way out of the playlist editor waiting for the user to confirm that the edit is undone. UI state only.
    @Published private(set) var leaveRequest: LeaveRequest?

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
        state.audioResponse = audioResponse
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

    /// The settings of `item` go to every other wallpaper in `scope` (every library wallpaper on a display, the
    /// playlist's wallpapers in a playlist); each keeps its own scene properties. The performance settings go along
    /// only from a scene: a video does not show them, so its values were never chosen.
    func applySettingsToAll(from item: VideoItem, in scope: OptionsScope) {
        let source = options(in: scope, for: item.id)
        let performance = item.isScene
        switch scope {
        case .display(let display):
            updateDisplay(display) { config in
                for other in videos where other.id != item.id {
                    config.wallpaperOptions[other.id.uuidString] =
                        config.options(for: other.id).withSettings(of: source, performance: performance)
                }
            }
        case .playlist(let playlist):
            updatePlaylist(playlist) { playlist in
                for other in playlist.items where other != item.id {
                    playlist.wallpaperOptions[other.uuidString] =
                        playlist.options(for: other).withSettings(of: source, performance: performance)
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
    private func createPlaylist(with items: [VideoItem.ID]) -> Playlist.ID {
        let names = Set(playlists.map(\.name))
        var name = String(localized: "New Playlist")
        var number = 2
        while names.contains(name) {
            name = String(localized: "New Playlist \(number)")
            number += 1
        }
        let now = Date()
        let playlist = Playlist(name: name, items: Self.unique(items), created: now, updated: now)
        playlists.append(playlist)
        return playlist.id
    }

    /// Edits a playlist and commits it (dated, see Playlist.updated). A wallpaper stays in a playlist once, and the
    /// options of wallpapers that left it go with them.
    func updatePlaylist(_ id: Playlist.ID, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var playlist = playlists[index]
        change(&playlist)
        playlist.items = Self.unique(playlist.items)
        let kept = Set(playlist.items.map(\.uuidString))
        playlist.wallpaperOptions = playlist.wallpaperOptions.filter { kept.contains($0.key) }
        playlist.intervalValue = Playlist.clampedInterval(playlist.intervalValue)
        playlist.transitionDuration = Playlist.clampedTransitionDuration(playlist.transitionDuration)
        guard playlist != playlists[index] else { return }
        playlist.updated = Date()
        playlists[index] = playlist
    }

    /// Adds wallpapers to the end of a playlist (those already in it stay where they are).
    func addToPlaylist(_ id: Playlist.ID, items: [VideoItem.ID]) {
        updatePlaylist(id) { $0.items += items }
    }

    /// Deletes a playlist and its pictures (with those chosen in its open editor); the displays that played it get
    /// macOS's default wallpaper back.
    func deletePlaylist(_ id: Playlist.ID) {
        var images = Set([playlist(id)?.image].compactMap { $0 })
        if let session = playlistEdit, session.original.id == id {
            images.formUnion(session.images.union([session.original.image].compactMap { $0 }))
            playlistEdit = nil
        }
        edit { $0.removePlaylist(id) }
        Self.deleteImages(images)
    }

    /// Makes the picture at `url` the open editor's playlist's own (a scaled-down copy, see PlaylistImage). False when
    /// it could not be read as a picture.
    func setPlaylistImage(_ id: Playlist.ID, from url: URL) async -> Bool {
        let name = await Task.detached(priority: .userInitiated) { PlaylistImage.store(url) }.value
        guard let name else { return false }
        // The editor may have been closed (cancelled) while the picture was read: it is not wanted any more.
        guard playlistEdit?.original.id == id, let previous = playlist(id) else {
            Self.deleteImages([name])
            return true
        }
        updatePlaylist(id) { $0.image = name }
        playlistEdit?.images.insert(name)
        retireImage(previous.image)
        return true
    }

    /// The open editor's playlist shows its wallpapers' previews again.
    func clearPlaylistImage(_ id: Playlist.ID) {
        guard let previous = playlist(id)?.image else { return }
        updatePlaylist(id) { $0.image = nil }
        retireImage(previous)
    }

    // MARK: Playlist editor
    // The editor changes its playlist live (a display that plays it follows every edit); Done keeps the changes and
    // every other way out of the editor (Cancel, another page, Settings, quitting) undoes them, after asking when
    // there is something to undo (`leaveEditor`). Pictures change only in the editor: a picture the playlist had when
    // the editor opened stays on disk until the editor closes, so Cancel can go back to it.

    /// The open playlist editor: the playlist as it was when the editor opened.
    struct PlaylistEdit {
        private(set) var original: Playlist
        /// Made for the editor (New Playlist): undoing the edit deletes it again.
        let isNew: Bool
        /// The pictures chosen in the editor (file names); the ones the playlist does not keep go when it closes.
        var images: Set<String> = []

        init(original: Playlist, isNew: Bool) {
            self.original = original
            self.isNew = isNew
        }

        /// A wallpaper was downloaded again under a new id (LibraryState.replace): the playlist as it was follows,
        /// like the playlist itself.
        mutating func replace(_ id: UUID, with newID: UUID) {
            guard id != newID else { return }
            original.items = original.items.map { $0 == id ? newID : $0 }
            if let options = original.wallpaperOptions.removeValue(forKey: id.uuidString) {
                original.wallpaperOptions[newID.uuidString] = options
            }
        }
    }

    /// A way out of the editor: what happens once the edit is undone, or when the user keeps editing.
    struct LeaveRequest {
        let discard: () -> Void
        let stay: () -> Void
    }

    var editingPlaylistID: Playlist.ID? { playlistEdit?.original.id }

    /// The playlist differs from what it was when the editor opened. An edit the user took back still left its date,
    /// which alone is no change.
    var editHasChanges: Bool {
        guard let session = playlistEdit else { return false }
        guard var current = playlist(session.original.id) else { return true }
        current.updated = session.original.updated
        return current != session.original
    }

    func editPlaylist(_ id: Playlist.ID) {
        guard let playlist = playlist(id) else { return }
        playlistEdit = PlaylistEdit(original: playlist, isNew: false)
    }

    /// Makes a playlist of `items` and opens the editor for it.
    func createAndEditPlaylist(with items: [VideoItem.ID] = []) {
        guard let playlist = playlist(createPlaylist(with: items)) else { return }
        playlistEdit = PlaylistEdit(original: playlist, isNew: true)
    }

    /// Done: the playlist keeps its changes and the editor closes.
    func finishEditing() {
        guard let session = playlistEdit else { return }
        // Edits the user took back leave the playlist as it was, its date included.
        if !editHasChanges, let index = playlists.firstIndex(where: { $0.id == session.original.id }),
           playlists[index] != session.original {
            playlists[index] = session.original
        }
        playlistEdit = nil
        let kept = playlist(session.original.id)?.image
        let unused = session.images.union([session.original.image].compactMap { $0 })
        Self.deleteImages(unused.subtracting([kept].compactMap { $0 }))
    }

    /// Leaves the editor, undoing its changes, then runs `proceed`. With changes to undo it asks first
    /// (`leaveRequest`, answered with `answerLeaveRequest`), and `stay` runs if the user keeps editing. Without an
    /// open editor `proceed` runs at once.
    func leaveEditor(then proceed: @escaping () -> Void, otherwise stay: @escaping () -> Void = {}) {
        guard playlistEdit != nil else { return proceed() }
        guard editHasChanges else {
            cancelEditing()
            return proceed()
        }
        leaveRequest = LeaveRequest(discard: { [weak self] in
            self?.cancelEditing()
            proceed()
        }, stay: stay)
    }

    func answerLeaveRequest(discard: Bool) {
        guard let request = leaveRequest else { return }
        leaveRequest = nil
        if discard { request.discard() } else { request.stay() }
    }

    /// Puts the playlist back as it was when the editor opened (a new one is deleted) and closes the editor.
    /// Wallpapers that left the library meanwhile stay out.
    private func cancelEditing() {
        guard let session = playlistEdit else { return }
        playlistEdit = nil
        let id = session.original.id
        if session.isNew {
            edit { $0.removePlaylist(id) }
        } else if let index = playlists.firstIndex(where: { $0.id == id }) {
            let library = Set(videos.map(\.id.uuidString))
            var original = session.original
            original.items.removeAll { !library.contains($0.uuidString) }
            original.wallpaperOptions = original.wallpaperOptions.filter { library.contains($0.key) }
            if playlists[index] != original { playlists[index] = original }
        }
        Self.deleteImages(session.images)
    }

    /// A picture the playlist no longer shows: one chosen in the open editor goes at once, the one the playlist had
    /// when the editor opened stays for Cancel.
    private func retireImage(_ image: String?) {
        guard let image, playlistEdit?.images.remove(image) != nil else { return }
        Self.deleteImages([image])
    }

    private static func deleteImages(_ names: Set<String>) {
        for name in names {
            try? FileManager.default.removeItem(at: AppPaths.playlistImagesDirectory.appendingPathComponent(name))
        }
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
    private var lastCommit: Task<Void, Never>?
    /// `fillCreationDates` ran (or runs) in this launch.
    private var creationDatesRequested = false
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

    /// Filters non-video, dedupes by path and appends (dated, see VideoItem.created and .updated). Returns the number
    /// added.
    @discardableResult func addVideos(urls: [URL]) -> Int {
        var knownPaths = Set(videos.map(\.path))
        var added: [VideoItem] = []
        let now = Date()
        for url in urls where VideoItem.isVideo(url) {
            var item = VideoItem(url: url)
            guard knownPaths.insert(item.path).inserted else { continue }
            item.created = url.creationDate
            item.updated = now
            added.append(item)
        }
        guard !added.isEmpty else { return 0 }
        videos += added
        return added.count
    }

    /// Called by the Workshop importer with a finished item (files already in AppPaths.libraryDirectory).
    /// A re-download replaces the earlier copy of the same Workshop item in place, on every display that shows it;
    /// either way the item is dated now (VideoItem.updated).
    func addImported(_ item: VideoItem) {
        var item = item
        item.updated = Date()
        let old = videos.first { $0.workshopID != nil && $0.workshopID == item.workshopID }
        edit { state in
            if let old {
                state.replace(old.id, with: item)
            } else {
                state.videos.append(item)
            }
        }
        if let old { playlistEdit?.replace(old.id, with: item.id) }
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

    /// Scenes analysed by an older analyzer get a fresh record (off the main thread; the files are tiny to read but
    /// can be large to scan).
    private func reanalyzeStaleScenes() {
        let stale = videos.filter { ($0.scene?.analysisRevision).map { $0 != SceneAnalysis.revision } ?? false }
        guard !stale.isEmpty else { return }
        Task { @MainActor [weak self] in
            let fresh = await Task.detached(priority: .utility) { stale.map { SceneImporter.reanalyze($0) } }.value
            self?.replace(fresh)
        }
    }

    /// Looks up the dates Home's creation date sort needs that the library does not know yet (LibraryEntry.created),
    /// off the main actor: the user's own wallpapers' creation from their files (VideoItem.created), Workshop items'
    /// last update from Steam in one request (VideoItem.workshopUpdated). Items Steam no longer has stay unknown. Once
    /// per launch (again after Steam could not be reached), when Home first sorts by creation date.
    func fillCreationDates() {
        guard !creationDatesRequested else { return }
        creationDatesRequested = true
        let missing = videos.filter { ($0.isWorkshop ? $0.workshopUpdated : $0.created) == nil }
        guard !missing.isEmpty else { return }
        Task { @MainActor [weak self] in
            let own = await Task.detached(priority: .utility) {
                Dictionary(missing.filter { $0.workshopID == nil }.compactMap { item in
                    item.url.creationDate.map { (item.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
            }.value
            var workshop: [String: Date] = [:]
            let workshopIDs = Array(Set(missing.compactMap(\.workshopID)))
            if !workshopIDs.isEmpty {
                do {
                    workshop = try await WorkshopKit.API.updateDates(ids: workshopIDs)
                } catch {
                    self?.creationDatesRequested = false
                }
            }
            self?.setCreationDates(own: own, workshop: workshop)
        }
    }

    /// One change of `videos`, so the library is published and committed once.
    private func setCreationDates(own: [UUID: Date], workshop: [String: Date]) {
        var dated = videos
        for index in dated.indices {
            let item = dated[index]
            if let workshopID = item.workshopID {
                if item.workshopUpdated == nil { dated[index].workshopUpdated = workshop[workshopID] }
            } else if item.created == nil {
                dated[index].created = own[item.id]
            }
        }
        if dated != videos { videos = dated }
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
        audioResponse = state.audioResponse
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

    /// Waits until the last commit has been answered or failed (before the app quits).
    func commitsSettled() async {
        await lastCommit?.value
    }

    /// Sends a command. An error the service answers with shows up as `localMessage`; without a connection the
    /// sidebar already says so, and a commit is sent again once the service answers.
    private func send(_ command: ServiceCommand) {
        let task = Task { @MainActor [weak self] in
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
        if case .commit = command { lastCommit = task }
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
