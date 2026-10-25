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
    /// The rotation playlist; nil = none yet (LibraryState.playlist).
    @Published private(set) var playlistIDs: [VideoItem.ID]? = nil { didSet { persist() } }
    /// Per display (LibraryState.displays). A display's `muted` goes to the service as `.setMuted`.
    @Published private(set) var displays: [String: DisplayConfig] = [:] { didSet { persist() } }
    @Published var stillDelay: Double = LibraryState.defaultStillDelay { didSet { persist() } }

    /// The connected displays, as arranged in System Settings > Displays. UI state only.
    @Published private(set) var screens: [ScreenInfo] = []
    /// The display Home and its inspector configure: the leftmost one unless the user picked another. UI state only.
    @Published var selectedDisplayID: String?
    /// A library item Home scrolls to and highlights once (Show in Library in the Workshop). UI state only.
    @Published var focusedID: VideoItem.ID? = nil

    // Service mirror (read-only for views).
    /// Videos imported from the phase-1 app on this launch (0 = none). Drives a dismissible banner.
    @Published private(set) var importedFromPhase1: Int = 0
    /// A phase-1 copy of the app is running; it would fight the service over the wallpaper.
    @Published private(set) var legacyAppRunning: Bool = false
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
        state.playlist = playlistIDs
        state.displays = displays
        state.stillDelay = stillDelay
        return state
    }

    // MARK: Displays

    var selectedScreen: ScreenInfo? { screens.first { $0.id == selectedDisplayID } }

    func config(for display: String) -> DisplayConfig { displays[display] ?? DisplayConfig() }

    /// The wallpaper set for `display`.
    func wallpaper(on display: String) -> VideoItem? { snapshot.item(config(for: display).wallpaperID) }

    /// What the service shows live on `display` (a rotating display moves on from its wallpaper).
    func liveItem(on display: String) -> VideoItem? { snapshot.item(serviceStatus?.display(display)?.itemID) }

    /// What `display` shows: its live item, else its wallpaper.
    func shownItem(on display: String) -> VideoItem? { liveItem(on: display) ?? wallpaper(on: display) }

    /// The picture of `display`'s system wallpaper, and the library item it is a still of (nil: another picture).
    func systemWallpaper(on display: String) -> (url: URL, stillOf: UUID?)? {
        guard let status = serviceStatus?.display(display), let path = status.systemWallpaper else { return nil }
        return (URL(fileURLWithPath: path), status.stillItemID)
    }

    /// Why `display`'s wallpaper could not be shown, as the service reported it.
    func error(on display: String) -> String? { serviceStatus?.display(display)?.error }

    /// Edits one display's settings and commits them to the service. `muted` is not changed here (`setMuted`).
    func updateDisplay(_ display: String, _ change: (inout DisplayConfig) -> Void) {
        edit { change(&$0.displays[display, default: DisplayConfig()]) }
    }

    /// Puts `id` on `display` at once.
    func setWallpaper(_ id: VideoItem.ID, on display: String) {
        edit { $0.setWallpaper(id, on: display) }
    }

    /// Puts `id` on every connected display.
    func setWallpaperOnAllDisplays(_ id: VideoItem.ID) {
        edit { state in screens.forEach { state.setWallpaper(id, on: $0.id) } }
    }

    /// Takes `display`'s wallpaper away; the service gives it macOS's default wallpaper.
    func removeWallpaper(from display: String) {
        edit { $0.setWallpaper(nil, on: display) }
    }

    func setMuted(_ muted: Bool, on display: String) {
        guard config(for: display).muted != muted else { return }
        batch(persisting: false) { displays[display, default: DisplayConfig()].muted = muted }
        written.displays[display, default: DisplayConfig()].muted = muted
        send(.setMuted(display: display, muted: muted))
    }

    func sceneOptions(on display: String, for id: UUID) -> SceneOptions {
        config(for: display).sceneOptions(for: id)
    }

    /// Edits one scene's options on one display and commits them to the service.
    func updateSceneOptions(on display: String, for id: UUID, _ change: (inout SceneOptions) -> Void) {
        updateDisplay(display) { config in
            var options = config.sceneOptions(for: id)
            change(&options)
            config.sceneOptions[id.uuidString] = options
        }
    }

    // MARK: Playlist

    /// The playlist's items in order.
    var playlistItems: [VideoItem] { snapshot.playlistItems }
    var canRotate: Bool { snapshot.canRotate }

    /// Writes the playlist (nil = no playlist); ids no longer in the library are dropped.
    func setPlaylist(_ ids: [VideoItem.ID]?) {
        let valid = Set(videos.map(\.id))
        let pruned = ids.map { $0.filter { valid.contains($0) } }
        if pruned != playlistIDs { playlistIDs = pruned }
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
    /// checks for a phase-1 copy and connects to the service. Never writes state.json.
    func bootstrap() {
        let loaded = StateStore.loadOrMigrate()
        batch(persisting: false) { apply(loaded.state) }
        written = loaded.state
        refreshScreens()
        reanalyzeStaleScenes()
        importedFromPhase1 = loaded.importedCount
        legacyAppRunning = Self.otherInstances().contains { $0.legacy }
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

    /// Removes from the library, the playlist and every display (which gets macOS's default wallpaper back).
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

    func dismissImportNotice() {
        importedFromPhase1 = 0
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
        playlistIDs = state.playlist
        displays = state.displays
        stillDelay = state.stillDelay
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

    /// A status arrived (reply or push): the service owns each display's `muted` (its menu can toggle them all).
    private func statusReceived(_ status: ServiceStatus) {
        if commitPending {
            commitPending = false
            persist(force: true)
        }
        let changed = status.displays.filter { display in
            displays[display.id].map { $0.muted != display.muted } ?? false
        }
        guard !changed.isEmpty else { return }
        batch(persisting: false) {
            for display in changed { displays[display.id]?.muted = display.muted }
        }
        for display in changed { written.displays[display.id]?.muted = display.muted }
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
        let workspace = NSWorkspace.shared.notificationCenter
        let appKey = NSWorkspace.applicationUserInfoKey
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[appKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor [weak self] in
                    if bundleID == AppIdentity.settingsBundleID { self?.legacyAppRunning = Self.otherInstances().contains { $0.legacy } }
                }
            }
            observers.append((workspace, token))
        }
    }

    // MARK: Other processes

    /// Other running copies of this app's bundle id. `legacy`: a phase-1 build (its Info.plist has no LWRole key).
    static func otherInstances() -> [(app: NSRunningApplication, legacy: Bool)] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.settingsBundleID)
            .compactMap { app -> (app: NSRunningApplication, legacy: Bool)? in
                guard app.processIdentifier != me, !app.isTerminated else { return nil }
                let role = app.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: AppIdentity.roleKey)
                return (app, role == nil)
            }
    }
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
