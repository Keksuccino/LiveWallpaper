import AppKit
import CryptoKit
import UniformTypeIdentifiers
import Core

// The system wallpaper of every display with a live wallpaper is a still of it, framed exactly like the live one on
// that display. The menu bar's background, Mission Control and the lock screen show the system wallpaper, never our
// windows, so without it they would show whatever picture was set before. A still is made only when what it shows
// changes (another wallpaper, display size or scene framing), never to follow the animation. It stays when the
// service quits: from then on it simply is the user's wallpaper. A display whose live wallpaper is taken away gets
// macOS's default wallpaper back.

@MainActor final class WallpaperStills {
    /// Bump when the still of an unchanged wallpaper would come out differently; every display gets a new one.
    private static let revision = 2
    nonisolated private static let directory = AppPaths.wallpaperStillsDirectory
    /// The picture macOS itself starts with (a link to the still of its current default wallpaper).
    private static let defaultWallpaper = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")

    /// Fired after stills were applied with the displays (by UUID) that got a new system wallpaper: their live
    /// windows have to let it through once (see DisplayWindow.revealSystemWallpaper) or the menu bar keeps showing
    /// the old one. Also fired, with possibly none listed, when `systemWallpapers` changed.
    var onApplied: (([String]) -> Void)?
    /// Each display's system wallpaper as this service set it or found it set, by display UUID. Read for the status
    /// rather than asking NSWorkspace, which reports a wallpaper only some moments after it was set.
    private(set) var systemWallpapers: [String: SystemWallpaper] = [:]

    struct SystemWallpaper: Equatable {
        let url: URL
        /// The library item the picture is a still of; nil for macOS's default wallpaper.
        let stillOf: UUID?
    }
    /// Seconds to wait before making stills (LibraryState.stillDelay): edits come in bursts (a slider sends every
    /// step), and a new wallpaper should get the machine before its still loads the scene a second time.
    var delay = LibraryState.defaultStillDelay
    /// What each display shows live, by display UUID.
    private var looks: [String: Look] = [:]
    /// The still each display should show, once it exists.
    private var targets: [String: Target] = [:]
    private var work: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// `display` now shows `item` with these wallpaper options.
    func show(_ item: VideoItem, options: WallpaperOptions, on display: String) {
        let look = Look(item: item, options: options)
        guard look != looks[display] else { return }
        looks[display] = look
        if observers.isEmpty { installObservers() }
        refresh()
    }

    /// `display` shows nothing live any more; its still stays its system wallpaper.
    func forget(_ display: String) {
        looks[display] = nil
        targets[display] = nil
    }

    /// `display`'s live wallpaper was taken away: it gets macOS's default wallpaper, and its still goes.
    func revert(_ display: String) {
        forget(display)
        systemWallpapers[display] = nil
        if let screen = NSScreen.screens.first(where: { $0.displayID == display }) {
            do {
                try NSWorkspace.shared.setDesktopImageURL(Self.defaultWallpaper, for: screen, options: [:])
                systemWallpapers[display] = SystemWallpaper(url: Self.defaultWallpaper, stillOf: nil)
            } catch {
                NSLog("WallpaperMage: couldn’t set the default wallpaper: \(error.localizedDescription)")
            }
        }
        AgentRecordStore.update { $0.stills[display] = nil }
        removeUnusedStills()
    }

    /// The service quits: pending work ends and the stills stay the system wallpapers.
    func stop() {
        work?.cancel()
        work = nil
        looks = [:]
        targets = [:]
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    // MARK: Making and applying

    /// Works out the still of every display, makes the missing ones after the settle delay and applies them.
    private func refresh() {
        work?.cancel()
        var targets: [String: Target] = [:]
        for screen in NSScreen.screens {
            if let look = looks[screen.displayID] { targets[screen.displayID] = Target(screen: screen, look: look) }
        }
        guard !targets.isEmpty else { return }
        let delay = delay
        work = Task { @MainActor [weak self] in
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
            // One renderer or video frame serves every display that shows the same look; a file that exists already
            // (same look, size and colour space) is not made again.
            var groups: [(look: Look, jobs: [String: Target])] = []
            for target in targets.values where !FileManager.default.fileExists(atPath: target.url.path) {
                if let index = groups.firstIndex(where: { $0.look == target.look }) {
                    groups[index].jobs[target.fileName] = target
                } else {
                    groups.append((target.look, [target.fileName: target]))
                }
            }
            for group in groups {
                do {
                    try await Self.make(Array(group.jobs.values), of: group.look)
                } catch {
                    if Task.isCancelled { return }
                    NSLog("WallpaperMage: couldn’t make the wallpaper still: \(error)")
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.work = nil
            // A display that shows something else by now waits for its own refresh.
            self.targets = targets.filter { self.looks[$0.key] == $0.value.look }
            self.apply()
            self.removeUnusedStills()
        }
    }

    /// Sets each display's still as its system wallpaper, skipping displays that show it already, and records which
    /// still each display has.
    private func apply() {
        let old = systemWallpapers
        var stills: [String: String] = [:]
        var applied: [String] = []
        for screen in NSScreen.screens {
            let id = screen.displayID
            guard let target = targets[id], FileManager.default.fileExists(atPath: target.url.path) else { continue }
            guard NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL != target.url.standardizedFileURL
            else {
                stills[id] = target.fileName
                systemWallpapers[id] = SystemWallpaper(url: target.url, stillOf: target.look.itemID)
                continue
            }
            // The still has the display's exact aspect ratio, so filling the screen neither crops nor shifts it.
            let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ]
            do {
                try NSWorkspace.shared.setDesktopImageURL(target.url, for: screen, options: options)
                stills[id] = target.fileName
                systemWallpapers[id] = SystemWallpaper(url: target.url, stillOf: target.look.itemID)
                applied.append(id)
            } catch {
                NSLog("WallpaperMage: couldn’t set the wallpaper still: \(error.localizedDescription)")
            }
        }
        let recorded = AgentRecordStore.load().stills
        if stills.contains(where: { recorded[$0.key] != $0.value }) {
            AgentRecordStore.update { $0.stills.merge(stills) { _, new in new } }
        }
        if !applied.isEmpty || systemWallpapers != old { onApplied?(applied) }
    }

    // A Space shows its own wallpaper unless "Show on all Spaces" is on, so a Space the stills were never set on
    // gets them when it becomes active. A display change needs stills of new sizes.
    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let spaces = workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                           queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.apply() }
        }
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        observers = [(workspace, spaces), (NotificationCenter.default, screens)]
    }

    /// Deletes the stills no display uses any more (older wallpapers, sizes and framings). The last still of a
    /// display that is not connected right now stays, so it still has its wallpaper when it comes back.
    private func removeUnusedStills() {
        let keep = Set(AgentRecordStore.load().stills.values).union(targets.values.map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil))
            ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Rendering (off the main actor)

    /// Writes the still of every target, all of the same look: one renderer or video frame serves all of them.
    nonisolated private static func make(_ jobs: [Target], of look: Look) async throws {
        try AppPaths.ensureDirectory(directory)
        if look.isScene {
            try StillRendering.renderScene(path: look.path, options: look.options, into: jobs.map(\.canvas)) {
                try write($1, to: jobs[$0].url)
            }
        } else {
            let frame = try await StillRendering.videoFrame(path: look.path, options: look.options, maxPixelSize: nil)
            for job in jobs {
                try Task.checkCancellation()
                try write(StillRendering.place(frame, look.options, into: job.canvas), to: job.url)
            }
        }
    }

    nonisolated private static func write(_ image: CGImage, to url: URL) throws {
        try StillRendering.write(image, to: url, as: .jpeg, quality: 0.9)
    }

    // MARK: What a still shows

    /// Everything that decides a still apart from the display: the item, its content and the options that change
    /// its picture (sound, speed, frame rate, render scale and the pointer's parallax do not).
    private struct Look: Codable, Equatable, Sendable {
        var itemID: UUID
        var path: String
        var stamp: String
        var isScene: Bool
        var options: WallpaperOptions

        init(item: VideoItem, options: WallpaperOptions) {
            itemID = item.id
            path = item.path
            stamp = item.contentStamp
            isScene = item.isScene
            var picture = options
            (picture.volume, picture.muted, picture.rate, picture.fps, picture.renderScale) =
                (1, false, 1, WallpaperOptions.defaultFPS, 1)
            picture.mouseParallax = true
            if !item.isScene { (picture.antialiasing, picture.properties) = (false, [:]) }
            self.options = picture
        }
    }

    /// The still one display needs. Displays of the same look, size and colour space share one file.
    private struct Target: Sendable {
        let look: Look
        let canvas: StillCanvas
        /// Named after a digest of everything that decides its pixels, so a changed wallpaper gets a new file
        /// (macOS caches a wallpaper by its path) and an unchanged one is found again after a restart.
        let fileName: String
        var url: URL { WallpaperStills.directory.appendingPathComponent(fileName) }

        @MainActor init(screen: NSScreen, look: Look) {
            self.look = look
            let scale = screen.backingScaleFactor
            let width = Int((screen.frame.width * scale).rounded())
            let height = Int((screen.frame.height * scale).rounded())
            // A scene's pixels are sRGB (see StillCanvas). A video frame is converted into the display's own space,
            // like the player's layer does, when that is an RGB space a bitmap context can draw into.
            let display = screen.colorSpace?.cgColorSpace
            let colorSpace = !look.isScene && display?.model == .rgb ? display! : StillCanvas.sRGB
            canvas = StillCanvas(width: width, height: height, colorSpace: colorSpace)
            let key = Key(revision: WallpaperStills.revision, look: look, width: width, height: height,
                          colorSpace: Self.identity(of: colorSpace))
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            fileName = Self.digest((try? encoder.encode(key)) ?? Data()) + ".jpg"
        }

        private struct Key: Codable {
            var revision: Int
            var look: Look
            var width: Int
            var height: Int
            var colorSpace: String
        }

        private static func identity(of space: CGColorSpace) -> String {
            if let name = space.name { return name as String }
            return space.copyICCData().map { digest($0 as Data) } ?? "unknown"
        }

        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        }
    }
}
