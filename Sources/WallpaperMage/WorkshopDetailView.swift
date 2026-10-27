import SwiftUI
import AppKit
import Core

// The Workshop detail pane: opens when a result is clicked. Large preview that animates when it is an animation
// (WorkshopPreviews, shared with the result cards; also once the item is in the library), title, the Info box
// (WallpaperInfoView.swift), description, Download; a downloaded scene adds the way to Wallpaper Engine's shared files
// while they are missing.

@MainActor
struct WorkshopDetailView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let item: WorkshopItem
    let close: () -> Void
    let openSteamSetup: () -> Void
    let openLibrary: () -> Void
    @State private var preview: AnimatedPicture?
    @State private var previewFailed = false

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
                WallpaperInfoBox(rows: infoRows, tags: item.topicTags)
                Text(item.summary.isEmpty ? String(localized: "No description.") : item.summary)
                    .font(.callout)
                    .foregroundStyle(item.summary.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .padding(24)
            // The pane starts at the window's top edge, as every page does (RootView).
            .padding(.top, WMTheme.toolbarStripPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WMBackground())
        .task(id: item.id) {
            guard let url = item.previewURL else { return }
            preview = await WorkshopPreviews.shared.picture(at: url)
            previewFailed = preview == nil
        }
    }

    // MARK: Preview

    private var previewArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            previewImage
                .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
            if libraryItem?.scene != nil { SharedFilesHint(setup: .shared, openSteamSetup: openSteamSetup) }
        }
    }

    private var previewImage: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            // The card's picture is usually at hand already.
            if let picture = preview ?? WorkshopPreviews.shared.cached(item.previewURL) {
                AnimatedPictureView(picture: picture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if previewFailed || item.previewURL == nil {
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

/// Below a downloaded scene's preview while Wallpaper Engine's shared files are missing: the way to get them.
@MainActor
private struct SharedFilesHint: View {
    /// Observed only to redraw when the wizard installs or removes the shared files; their folder is the truth.
    @ObservedObject var setup: SteamSetupModel
    let openSteamSetup: () -> Void

    var body: some View {
        if !SceneImporter.hasSharedAssets {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scenes need Wallpaper Engine’s shared files to play.").font(.callout).foregroundStyle(.secondary)
                Button("Get Wallpaper Engine’s shared files", action: openSteamSetup).buttonStyle(.link)
            }
        }
    }
}
