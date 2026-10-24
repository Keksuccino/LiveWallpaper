import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Core
import SceneBridge

// The system wallpaper of every display is a still of the live wallpaper, framed exactly like the live one on that
// display. The menu bar's background, Mission Control and the lock screen show the system wallpaper, never our
// windows, so without it they would show whatever picture was set before. A still is made only when what it shows
// changes (another wallpaper, display size or scene framing), never to follow the animation. It stays when playback
// stops: from then on it simply is the user's wallpaper.

@MainActor final class WallpaperStills {
    /// Bump when the still of an unchanged wallpaper would come out differently; every display gets a new one.
    private static let revision = 1
    /// Edits come in bursts (a slider), and the live wallpaper should get the machine first.
    private static let settleDelay: UInt64 = 2_000_000_000
    nonisolated private static let directory = AppPaths.wallpaperStillsDirectory

    /// A display got a new system wallpaper; the live windows have to let it through once (see
    /// DesktopWindows.revealSystemWallpaper) or the menu bar keeps showing the old one.
    var onApplied: (() -> Void)?
    private var look: Look?
    /// The stills the displays should show, once they exist.
    private var targets: [Target] = []
    private var work: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// The desktop now shows `item`; `options` are its scene options (nil for a video).
    func show(_ item: VideoItem, options: SceneOptions?) {
        let look = Look(item: item, options: options)
        guard look != self.look else { return }
        self.look = look
        if observers.isEmpty { installObservers() }
        refresh()
    }

    /// Playback stopped: pending work ends and the stills stay the system wallpaper.
    func stop() {
        work?.cancel()
        work = nil
        look = nil
        targets = []
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    // MARK: Making and applying

    /// Works out the still of every display, makes the missing ones after the settle delay and applies them.
    private func refresh() {
        work?.cancel()
        guard let look else { return }
        let targets = NSScreen.screens.map { Target(screen: $0, look: look) }
        work = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.settleDelay) } catch { return }
            var jobs: [String: Target] = [:]
            for target in targets where !FileManager.default.fileExists(atPath: target.url.path) {
                jobs[target.fileName] = target
            }
            if !jobs.isEmpty {
                do {
                    try await Self.make(Array(jobs.values), of: look)
                } catch {
                    if !Task.isCancelled { NSLog("LiveWallpaper: couldn’t make the wallpaper still: \(error)") }
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.work = nil
            self.targets = targets
            self.apply()
            Self.removeStills(except: Set(targets.map(\.fileName)))
        }
    }

    /// Sets each display's still as its system wallpaper, skipping displays that show it already.
    private func apply() {
        var changed = false
        for screen in NSScreen.screens {
            guard let target = targets.first(where: { $0.displayID == screen.displayID }),
                  FileManager.default.fileExists(atPath: target.url.path),
                  NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL != target.url.standardizedFileURL
            else { continue }
            // The still has the display's exact aspect ratio, so filling the screen neither crops nor shifts it.
            let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ]
            do {
                try NSWorkspace.shared.setDesktopImageURL(target.url, for: screen, options: options)
                changed = true
            } catch {
                NSLog("LiveWallpaper: couldn’t set the wallpaper still: \(error.localizedDescription)")
            }
        }
        if changed { onApplied?() }
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

    /// Deletes the stills no display uses any more (older wallpapers, sizes and framings).
    private static func removeStills(except keep: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Rendering (off the main actor)

    /// Writes the still of every target: one renderer or video frame serves all of them.
    nonisolated private static func make(_ jobs: [Target], of look: Look) async throws {
        try AppPaths.ensureDirectory(directory)
        if let scene = look.scene {
            try renderScene(scene, path: look.path, into: jobs)
        } else {
            guard let frame = await VideoStills.cgImage(for: URL(fileURLWithPath: look.path), maxPixelSize: nil) else {
                throw StillError.noFrame
            }
            for job in jobs {
                try Task.checkCancellation()
                try write(fill(frame, into: job), to: job.url)
            }
        }
    }

    /// A scene is drawn by a renderer of its own, with the live one's framing and properties.
    nonisolated private static func renderScene(_ scene: SceneLook, path: String, into jobs: [Target]) throws {
        let renderer = try Renderer(pkgPath: path)
        defer { renderer.stop() }
        renderer.setMuted(muted: true)
        // A clock or date the scene computes would stay frozen in the still.
        renderer.setHideScriptedText(hide: true)
        renderer.setFitMode(mode: scene.fitMode.renderer)
        renderer.setPanZoom(of: scene.options)
        for (name, value) in scene.properties.sorted(by: { $0.key < $1.key }) {
            renderer.applyProperty(name: name, valueJson: value.json)
        }
        // Particles and scripts need a second to settle; the warm-up frames are tiny.
        renderer.setFrameSize(width: 160, height: 90)
        for frame in 0..<30 {
            try Task.checkCancellation()
            _ = try renderer.renderFrame(time: Double(frame) / 30)
        }
        for job in jobs {
            try Task.checkCancellation()
            renderer.setFrameSize(width: UInt32(job.width), height: UInt32(job.height))
            let pixels = try renderer.renderFrame(time: 1)
            try write(image(fromBGRA: pixels, of: job), to: job.url)
        }
    }

    /// The renderer's BGRA pixels carry no colour space, and the window server treats the live layer's pixels as
    /// sRGB; the still's target space is sRGB too (Target), so both look the same on every display.
    nonisolated private static func image(fromBGRA pixels: Data, of job: Target) throws -> CGImage {
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: job.width, height: job.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: job.width * 4, space: job.colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { throw StillError.encode }
        return image
    }

    /// The video frame scaled to fill the display and centred, like the player's aspect-fill layer.
    nonisolated private static func fill(_ frame: CGImage, into job: Target) throws -> CGImage {
        guard let context = CGContext(data: nil, width: job.width, height: job.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: job.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw StillError.encode }
        let scale = max(Double(job.width) / Double(frame.width), Double(job.height) / Double(frame.height))
        let size = CGSize(width: Double(frame.width) * scale, height: Double(frame.height) * scale)
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: (Double(job.width) - size.width) / 2,
                                       y: (Double(job.height) - size.height) / 2,
                                       width: size.width, height: size.height))
        guard let image = context.makeImage() else { throw StillError.encode }
        return image
    }

    /// Written under a temporary name first, so a half-written file is never taken for a finished still.
    nonisolated private static func write(_ image: CGImage, to url: URL) throws {
        let partial = url.appendingPathExtension("partial")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.jpeg.identifier as CFString,
                                                                1, nil)
        else { throw StillError.encode }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: partial)
            throw StillError.encode
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
    }

    private enum StillError: Swift.Error {
        case noFrame, encode
    }

    // MARK: What a still shows

    /// Everything that decides a still apart from the display: the item, its content and, for a scene, its framing
    /// and properties (frame rate, sound and render scale do not change the picture).
    private struct Look: Codable, Equatable, Sendable {
        var itemID: UUID
        var path: String
        var stamp: String
        var scene: SceneLook?

        init(item: VideoItem, options: SceneOptions?) {
            itemID = item.id
            path = item.path
            stamp = item.contentStamp
            scene = item.isScene ? SceneLook(options ?? .standard) : nil
        }
    }

    private struct SceneLook: Codable, Equatable, Sendable {
        var fitMode: SceneFitMode
        var panX: Double
        var panY: Double
        var zoom: Double
        var properties: [String: ScenePropertyValue]

        init(_ options: SceneOptions) {
            fitMode = options.fitMode
            panX = options.panX
            panY = options.panY
            zoom = options.zoom
            properties = options.properties
        }

        var options: SceneOptions { SceneOptions(zoom: zoom, fitMode: fitMode, panX: panX, panY: panY) }
    }

    /// The still one display needs. Displays of the same size and colour space share one file.
    private struct Target: Sendable {
        let displayID: String
        let width: Int
        let height: Int
        let colorSpace: CGColorSpace
        /// Named after a digest of everything that decides its pixels, so a changed wallpaper gets a new file
        /// (macOS caches a wallpaper by its path) and an unchanged one is found again after a restart.
        let fileName: String
        var url: URL { WallpaperStills.directory.appendingPathComponent(fileName) }

        @MainActor init(screen: NSScreen, look: Look) {
            displayID = screen.displayID
            let scale = screen.backingScaleFactor
            width = Int((screen.frame.width * scale).rounded())
            height = Int((screen.frame.height * scale).rounded())
            // A scene's pixels are sRGB (see image(fromBGRA:)). A video frame is converted into the display's own
            // space, like the player's layer does, when that is an RGB space a bitmap context can draw into.
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
            let display = screen.colorSpace?.cgColorSpace
            colorSpace = look.scene == nil && display?.model == .rgb ? display! : sRGB
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
