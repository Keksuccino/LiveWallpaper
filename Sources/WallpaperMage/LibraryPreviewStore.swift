import Foundation
import Combine
import Core

// The library's previews (LibraryPreview) as Settings sees them: the files the service made, which ItemThumbnail
// shows instead of a wallpaper's own preview image. Home asks the service for the missing ones; a library card's
// Refresh Preview asks for a new one. The service reports each new file through PreviewStatus.revision, upon which the
// directory is read again.

@MainActor final class LibraryPreviewStore: ObservableObject {
    static let shared = LibraryPreviewStore()

    /// A preview file; `modified` tells a refreshed preview from the one it replaced.
    struct File: Hashable, Sendable {
        let url: URL
        let modified: Date
    }

    /// Each wallpaper's newest preview, by item id.
    @Published private(set) var files: [UUID: File] = [:]
    /// Wallpapers whose previews are being made again.
    @Published private(set) var refreshing: Set<UUID> = []

    private let client = ServiceClient.shared
    private var listedRevision: Int?
    private var listing: Task<Void, Never>?
    private var watch: AnyCancellable?

    private init() {
        watch = client.$status.sink { [weak self] status in self?.statusChanged(status?.previews) }
        reload()
    }

    /// Asks the service for the previews `items` miss, or that a changed file made out of date, in their order,
    /// drawn with `options`. Items whose file is gone are left out.
    func makeMissing(_ items: [VideoItem], options: (UUID) -> WallpaperOptions) async {
        await listing?.value
        let present = Set(files.values.map(\.url.lastPathComponent))
        let missing = await Task.detached(priority: .utility) {
            items.filter {
                FileManager.default.fileExists(atPath: $0.path) && !present.contains(LibraryPreview.fileName(for: $0))
            }
        }.value
        guard !missing.isEmpty, !Task.isCancelled else { return }
        send(missing.map { PreviewRequest(item: $0, options: options($0.id), refresh: false) })
    }

    /// Has the service make `item`'s preview again, with `options`.
    func refresh(_ item: VideoItem, options: WallpaperOptions) {
        refreshing.insert(item.id)
        send([PreviewRequest(item: item, options: options, refresh: true)])
    }

    /// Without an answer (no service, or one older than previews) nothing is being made.
    private func send(_ requests: [PreviewRequest]) {
        Task { @MainActor [weak self] in
            do {
                try await self?.client.perform(.makePreviews(requests))
            } catch {
                self?.statusChanged(self?.client.status?.previews)
            }
        }
    }

    private func statusChanged(_ status: PreviewStatus?) {
        let refreshing = Set(status?.refreshing ?? [])
        if refreshing != self.refreshing { self.refreshing = refreshing }
        guard let revision = status?.revision, revision != listedRevision else { return }
        listedRevision = revision
        reload()
    }

    /// Reads the previews directory off the main thread.
    private func reload() {
        listing?.cancel()
        listing = Task { @MainActor [weak self] in
            let files = await Task.detached(priority: .utility) { Self.list() }.value
            guard !Task.isCancelled, let self, files != self.files else { return }
            self.files = files
        }
    }

    nonisolated private static func list() -> [UUID: File] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.libraryPreviewsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var files: [UUID: File] = [:]
        for url in urls {
            guard let id = LibraryPreview.itemID(ofFile: url.lastPathComponent) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let known = files[id], known.modified >= modified { continue }
            files[id] = File(url: url, modified: modified)
        }
        return files
    }
}
