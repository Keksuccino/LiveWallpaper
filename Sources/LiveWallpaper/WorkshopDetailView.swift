import SwiftUI
import AppKit
import Core

// Owner: SETTINGS. The Workshop detail pane (SPEC3.md section 6.3): opens when a result is clicked. Large preview
// that ANIMATES (Workshop previews are often GIFs), title, tags, size, description, Download; after the download
// the pane shows the real preview of the library item (the video, or the scene preview with its support badge).
// This file is a stub with the final types. It is not wired into WorkshopView yet.

/// NSImageView with `animates = true`, so animated GIF previews play. SwiftUI's Image and AsyncImage show frame 1.
struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage?

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.isEditable = false
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}

/// Loads a preview image from a URL (http(s) or file) once; keeps the original bytes so GIFs keep their frames.
@MainActor final class WorkshopPreviewLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var failed = false

    func load(_ url: URL?) async {
        image = nil
        failed = false
        guard let url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let loaded = NSImage(data: data) { image = loaded } else { failed = true }
        } catch {
            failed = true
        }
    }
}

@MainActor
struct WorkshopDetailView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let item: WorkshopItem
    let close: () -> Void
    let openSteamSetup: () -> Void
    @StateObject private var preview = WorkshopPreviewLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AnimatedImageView(image: preview.image)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
            Text(item.title).font(.title2)
            Text(item.summary).font(.callout).foregroundStyle(.secondary)
            Button("Close", action: close)
        }
        .padding(16)
        .task(id: item.id) { await preview.load(item.previewURL) }
    }
}
