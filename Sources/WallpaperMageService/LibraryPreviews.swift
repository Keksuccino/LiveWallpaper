import Foundation
import CoreGraphics
import Core

// The library's previews (LibraryPreview): a still of each wallpaper, drawn like a display's system wallpaper
// (StillRendering) and kept until the wallpaper leaves the library or its file changes; only a refresh makes one
// again. Settings asks for the previews it misses while Home is open, and for a new one on Refresh Preview. They are
// made one at a time at low priority, so the live wallpapers keep the machine.

@MainActor final class LibraryPreviews {
    /// Fired when `status` changed.
    var onChange: (() -> Void)?
    private(set) var status = PreviewStatus()

    /// The refreshes first, then the missing previews in the order Settings asked for them.
    private var queue: [PreviewRequest] = []
    /// The request being made.
    private var current: PreviewRequest?
    /// Wallpapers whose preview could not be made in this launch; only a refresh tries again.
    private var failed: Set<UUID> = []
    private var worker: Task<Void, Never>?

    /// A scene is drawn at a common display's size and scaled down, so its text, lines and effects come out as they
    /// do on a display, only smoother.
    nonisolated private static let sceneCanvas = StillCanvas(width: 1920, height: 1080, colorSpace: StillCanvas.sRGB)
    nonisolated private static let canvas = StillCanvas(width: LibraryPreview.width, height: LibraryPreview.height,
                                                        colorSpace: StillCanvas.sRGB)

    /// Takes Settings' requests (ServiceCommand.makePreviews).
    func make(_ requests: [PreviewRequest]) {
        let refreshes = requests.filter(\.refresh)
        let refreshed = Set(refreshes.map(\.item.id))
        failed.subtract(refreshed)
        let waiting = queue.filter { $0.refresh && !refreshed.contains($0.item.id) } + refreshes
        let queued = Set(waiting.map(\.item.id))
        queue = waiting + requests.filter {
            !$0.refresh && !queued.contains($0.item.id) && !failed.contains($0.item.id)
                && $0.item.id != current?.item.id
        }
        publish()
        startWorking()
    }

    /// The library's wallpapers are these: the previews of any other wallpaper are deleted and no longer made.
    func retain(_ library: Set<UUID>) {
        queue.removeAll { !library.contains($0.item.id) }
        publish()
        Task.detached(priority: .utility) { [weak self] in
            guard Self.removeFiles(where: { id, _ in !library.contains(id) }) else { return }
            await self?.publish(changedFiles: true)
        }
    }

    /// The service quits: what waits is dropped.
    func stop() {
        queue = []
        worker?.cancel()
        worker = nil
    }

    // MARK: Working through the queue

    private func startWorking() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { @MainActor [weak self] in
            while let request = self?.next() {
                let outcome = await Task.detached(priority: .utility) { await Self.make(request) }.value
                if Task.isCancelled { return }
                self?.finish(request, outcome)
            }
            self?.worker = nil
        }
    }

    private func next() -> PreviewRequest? {
        current = queue.isEmpty ? nil : queue.removeFirst()
        return current
    }

    private func finish(_ request: PreviewRequest, _ outcome: Outcome) {
        current = nil
        if outcome == .failed { failed.insert(request.item.id) }
        publish(changedFiles: outcome == .made)
    }

    private func publish(changedFiles: Bool = false) {
        var status = status
        if changedFiles { status.revision += 1 }
        status.refreshing = ([current].compactMap { $0 } + queue).filter(\.refresh).map(\.item.id)
        guard status != self.status else { return }
        self.status = status
        onChange?()
    }

    // MARK: Making (off the main actor)

    private enum Outcome {
        case made, existed, failed
    }

    /// Draws the preview and writes it, then deletes the wallpaper's older previews.
    nonisolated private static func make(_ request: PreviewRequest) async -> Outcome {
        let item = request.item
        let name = LibraryPreview.fileName(for: item)
        let url = AppPaths.libraryPreviewsDirectory.appendingPathComponent(name)
        guard request.refresh || !FileManager.default.fileExists(atPath: url.path) else { return .existed }
        do {
            try AppPaths.ensureDirectory(AppPaths.libraryPreviewsDirectory)
            var preview: CGImage?
            if item.isScene {
                try StillRendering.renderScene(path: item.path, options: request.options, into: [sceneCanvas]) {
                    preview = try StillRendering.scaled($1, to: canvas)
                }
            } else {
                let frame = try await StillRendering.videoFrame(path: item.path, options: request.options,
                                                                maxPixelSize: CGSize(width: 1920, height: 1080))
                preview = try StillRendering.place(frame, request.options, into: canvas)
            }
            guard let preview else { throw StillRendering.Failure.encode }
            try StillRendering.write(preview, to: url, as: .heic, quality: LibraryPreview.quality)
        } catch {
            NSLog("WallpaperMage: couldn’t make the preview of \(item.name): \(error)")
            return .failed
        }
        removeFiles { $0 == item.id && $1 != name }
        return .made
    }

    /// Deletes the previews (by wallpaper and file name) that `remove` picks; true when it deleted any.
    @discardableResult
    nonisolated private static func removeFiles(where remove: (UUID, String) -> Bool) -> Bool {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(atPath: AppPaths.libraryPreviewsDirectory.path)) ?? []
        var removed = false
        for name in files {
            guard let id = LibraryPreview.itemID(ofFile: name), remove(id, name) else { continue }
            let file = AppPaths.libraryPreviewsDirectory.appendingPathComponent(name)
            if (try? manager.removeItem(at: file)) != nil { removed = true }
        }
        return removed
    }
}
