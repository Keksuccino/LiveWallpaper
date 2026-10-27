import SwiftUI
import AppKit
import Core

// The Workshop detail pane: opens when a result is clicked. Large preview that ANIMATES (Workshop
// previews are often GIFs), title, the Info box (WallpaperInfoView.swift), description, Download; after the download
// the pane shows the library item's own preview (the muted looping video, or the scene preview).

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

    /// An NSImageView asks for the image's pixel size, which for a 4K preview pushes the whole pane apart.
    /// The view takes the size SwiftUI proposes and scales the image into it instead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
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
            if Task.isCancelled { return }
            if let loaded = NSImage(data: data) { image = loaded } else { failed = true }
        } catch {
            if !Task.isCancelled { failed = true }
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
    let openLibrary: () -> Void
    @StateObject private var preview = WorkshopPreviewLoader()

    init(model: SettingsModel, workshop: WorkshopModel, item: WorkshopItem, close: @escaping () -> Void,
         openSteamSetup: @escaping () -> Void, openLibrary: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._workshop = ObservedObject(wrappedValue: workshop)
        self.item = item
        self.close = close
        self.openSteamSetup = openSteamSetup
        self.openLibrary = openLibrary
    }

    private var libraryItem: VideoItem? { model.videos.first { $0.workshopID == item.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(action: close) {
                        Label("Results", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    if let url = WorkshopItem.pageURL(id: item.id) {
                        Link(destination: url) {
                            Label("Open in Steam", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
                previewArea
                Text(item.title)
                    .font(.system(size: 26, weight: .semibold))
                    .textSelection(.enabled)
                // The page link is in the top row already.
                WallpaperInfoBox(rows: infoRows, tags: item.topicTags)
                Text(item.summary.isEmpty ? String(localized: "No description.") : item.summary)
                    .font(.callout)
                    .foregroundStyle(item.summary.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .padding(24)
            // The pane starts at the window's top edge, in the toolbar strip (see `WorkshopView.content`).
            .padding(.top, WMTheme.toolbarStripPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WMBackground())
        .task(id: item.id) { await preview.load(item.previewURL) }
    }

    // MARK: Preview

    @ViewBuilder private var previewArea: some View {
        previewImage
            .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
    }

    @ViewBuilder private var previewImage: some View {
        if let video = libraryItem {
            ItemPreviewPane(item: video, broken: !FileManager.default.fileExists(atPath: video.path),
                            openSteamSetup: openSteamSetup)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = preview.image {
                    AnimatedImageView(image: image)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if preview.failed || item.previewURL == nil {
                    Image(systemName: "photo").font(.system(size: 32)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
        }
    }

    // MARK: Info

    /// What Steam's record of the item says, in the rows of a library wallpaper's Info box where they match.
    private var infoRows: [InfoRow] {
        var rows: [InfoRow] = []
        if let kind = item.kind.label { rows.append(InfoRow(title: "Type", value: kind)) }
        if let resolution = item.resolutionTag {
            rows.append(InfoRow(title: "Resolution", value: WallpaperInfoBox.resolution(tag: resolution)))
        }
        if item.sizeBytes > 0 { rows.append(InfoRow(title: "Size", value: WallpaperInfoBox.bytes(item.sizeBytes))) }
        if let rating = item.ratingTag { rows.append(InfoRow(title: "Rating", value: WallpaperInfoBox.rating(rating))) }
        if let author = item.author { rows.append(InfoRow(title: "Author", value: author)) }
        if let subscriptions = item.subscriptions {
            rows.append(InfoRow(title: "Subscribers", value: subscriptions.formatted()))
        }
        if let created = item.created { rows.append(InfoRow(title: "Created", value: WallpaperInfoBox.date(created))) }
        if let updated = item.updated { rows.append(InfoRow(title: "Updated", value: WallpaperInfoBox.date(updated))) }
        return rows
    }

    // MARK: Actions

    private var cardAction: WorkshopCardAction {
        WorkshopCardAction.make(item: item, state: workshop.downloads[item.id], inLibrary: libraryItem != nil)
    }

    @ViewBuilder private var actions: some View {
        if let video = libraryItem, case .inLibrary = cardAction {
            librarySection(video)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                WorkshopCardActions(item: item, action: cardAction, ready: workshop.setup.canDownload, compact: false,
                                    workshop: workshop, openSteamSetup: openSteamSetup, showInLibrary: showInLibrary)
                if case .download = cardAction, !workshop.setup.canDownload { setupHint }
            }
        }
    }

    private var setupHint: some View {
        HStack(spacing: 6) {
            Text(WorkshopCardActions.setupFirst).font(.caption).foregroundStyle(.orange)
            Button("Set up Steam", action: openSteamSetup).buttonStyle(.link).font(.caption)
        }
    }

    private func librarySection(_ video: VideoItem) -> some View {
        WrappingRows {
            Button("Show in Library", action: showInLibrary)
        }
        .controlSize(.small)
    }

    private func showInLibrary() {
        if let video = libraryItem { model.focusedID = video.id }
        openLibrary()
    }
}
