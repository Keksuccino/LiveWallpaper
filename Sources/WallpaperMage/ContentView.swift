import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Core

// Home: the connected displays (DisplayArrangementView) above the library of playlists and wallpapers, in the order
// the user sorts it by (LibraryOrder). Clicking one puts it on the selected display at once; the inspector holds that
// display's settings. Clicking a display scrolls the card of what it shows to the middle of the library. A playlist's
// editor (PlaylistEditorView) takes the library's place while it is open.

enum LibraryLayout: String, CaseIterable {
    case grid, list
}

/// A kind of content the library lists; a button in the library's title row shows or hides each kind. Sorted by type
/// (descending), the library lists the kinds in this order.
enum LibraryKind: CaseIterable, Identifiable, Comparable {
    case playlist, scene, video

    /// A wallpaper's kind: Workshop videos and the user's own videos are videos alike.
    init(_ item: VideoItem) {
        self = item.isScene ? .scene : .video
    }

    var id: Self { self }

    var label: String {
        switch self {
        case .playlist: return String(localized: "Playlists")
        case .scene: return String(localized: "Scenes")
        case .video: return String(localized: "Videos")
        }
    }
}

/// One entry of the library: a playlist (with its wallpapers, for its picture) or a wallpaper.
enum LibraryEntry: Identifiable, Equatable {
    case playlist(Playlist, items: [VideoItem])
    case wallpaper(VideoItem)

    var id: UUID {
        switch self {
        case .playlist(let playlist, _): return playlist.id
        case .wallpaper(let item): return item.id
        }
    }

    /// What a display shows when the entry is put on it.
    var content: DisplayContent {
        switch self {
        case .playlist(let playlist, _): return .playlist(playlist.id)
        case .wallpaper(let item): return .wallpaper(item.id)
        }
    }

    var name: String {
        switch self {
        case .playlist(let playlist, _): return playlist.name
        case .wallpaper(let item): return item.name
        }
    }

    var kind: LibraryKind {
        switch self {
        case .playlist: return .playlist
        case .wallpaper(let item): return LibraryKind(item)
        }
    }

    /// When the entry itself was made (Playlist.created, VideoItem.created), for a Workshop item when it was last
    /// updated on the Workshop (VideoItem.workshopUpdated).
    var created: Date? {
        switch self {
        case .playlist(let playlist, _): return playlist.created
        case .wallpaper(let item): return item.isWorkshop ? item.workshopUpdated : item.created
        }
    }

    /// When the entry came into the library or last changed (VideoItem.updated, Playlist.updated).
    var updated: Date? {
        switch self {
        case .playlist(let playlist, _): return playlist.updated
        case .wallpaper(let item): return item.updated
        }
    }

    /// The library in its own order: the playlists, then the wallpapers as they were added, without the `hidden` kinds
    /// and without what does not match `search` (a playlist's name, a wallpaper's name or author). Home lists it as
    /// LibraryOrder sorts it.
    static func library(videos: [VideoItem], playlists: [Playlist], search: String,
                        hiding hidden: Set<LibraryKind>) -> [LibraryEntry] {
        func matches(_ text: String?) -> Bool {
            search.isEmpty || (text ?? "").localizedCaseInsensitiveContains(search)
        }
        var entries: [LibraryEntry] = []
        if !hidden.contains(.playlist) {
            let library = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            entries += playlists
                .filter { matches($0.name) }
                .map { .playlist($0, items: $0.items.compactMap { library[$0] }) }
        }
        entries += videos
            .filter { !hidden.contains(LibraryKind($0)) && (matches($0.name) || matches($0.author)) }
            .map(LibraryEntry.wallpaper)
        return entries
    }
}

@MainActor
struct HomeView: View {
    @ObservedObject var model: SettingsModel
    let openWorkshop: () -> Void

    @State private var searchText = ""
    @AppStorage("librarySort") private var sort: LibrarySort = .updated
    /// One direction for every sort (LibraryOrder.ascending).
    @AppStorage("librarySortAscending") private var sortAscending = false
    @State private var layout: LibraryLayout = .grid
    @State private var isTargeted = false
    @State private var skippedCount = 0
    @State private var showSkipped = false
    @State private var importFailures: [String] = []
    @State private var showFailures = false
    @State private var pendingRemoval: Set<VideoItem.ID> = []
    @State private var pendingDeletion: Playlist.ID?
    /// Ringed for a moment after Show in Library scrolled to it.
    @State private var highlightedID: VideoItem.ID?
    /// Scrolls the card of what a clicked display shows to the middle of the library.
    @State private var cardReveal = LibraryReveal()

    var body: some View {
        Group {
            if model.videos.isEmpty && model.playlists.isEmpty {
                emptyState
            } else {
                gallery
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: previewDemand) { await makeMissingPreviews() }
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { isTargeted = $0 }
        .alert(skippedTitle, isPresented: $showSkipped) { Button("OK", role: .cancel) {} }
        .alert("Some wallpapers couldn’t be imported", isPresented: $showFailures) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importFailures.joined(separator: "\n"))
        }
        .alert(removalTitle, isPresented: confirmingRemoval) {
            Button("Remove", role: .destructive) { finishRemoval() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can download it again from the Workshop.")
        }
        .alert(deletionTitle, isPresented: confirmingDeletion) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeletion { model.deletePlaylist(id) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its wallpapers stay in your library.")
        }
    }

    // MARK: Data

    /// The playlists and wallpapers of the kinds shown that match the search, in the order chosen.
    private var entries: [LibraryEntry] {
        let library = LibraryEntry.library(videos: model.videos, playlists: model.playlists, search: searchText,
                                           hiding: model.hiddenLibraryKinds)
        return LibraryOrder(sort: sort, ascending: sortAscending).sorted(library)
    }

    /// What the selected display is set to; its card is ringed.
    private var currentContent: DisplayContent? {
        model.selectedDisplayID.flatMap { model.content(on: $0) }
    }

    private func isBroken(_ item: VideoItem) -> Bool {
        !FileManager.default.fileExists(atPath: item.path)
    }

    // MARK: Previews

    /// The library's wallpapers while the service answers: it makes the previews they miss.
    private var previewDemand: [VideoItem.ID]? {
        model.client.state == .connected ? model.videos.map(\.id) : nil
    }

    /// Asks for the missing previews, those of the wallpapers listed first, in the order they are listed.
    private func makeMissingPreviews() async {
        guard previewDemand != nil else { return }
        let listed = entries.compactMap { entry -> VideoItem? in
            if case .wallpaper(let item) = entry { return item }
            return nil
        }
        let listedIDs = Set(listed.map(\.id))
        let items = listed + model.videos.filter { !listedIDs.contains($0.id) }
        await LibraryPreviewStore.shared.makeMissing(items, options: previewOptions)
    }

    /// A preview shows the wallpaper with the options it has on the selected display on its own, as a click on its
    /// card puts it there.
    private func previewOptions(_ id: VideoItem.ID) -> WallpaperOptions {
        model.selectedDisplayID.map { model.config(for: $0).options(for: id) } ?? .standard
    }

    // MARK: Content

    /// The page header, the display picker and the library's title row stay put; only the library below them
    /// scrolls.
    private var gallery: some View {
        let entries = entries
        return ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 26) {
                    WMPageHeader(title: "Home")
                    DisplayPicker(model: model) { revealCurrent(with: proxy) }
                    libraryHeader(count: entries.count)
                }
                .padding([.horizontal, .top], WMTheme.contentPadding)
                .padding(.bottom, 8)
                ScrollView {
                    libraryItems(entries)
                        .padding([.horizontal, .bottom], WMTheme.contentPadding)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .coordinateSpace(.named(LibraryReveal.contentSpace))
                }
                .scrollIndicators(.visible)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
                    cardReveal.scrolled(geometry)
                }
                .onScrollPhaseChange { _, phase in cardReveal.phaseChanged(to: phase) }
                .onAppear { reveal(with: proxy) }
                .onChange(of: model.focusedID) { reveal(with: proxy) }
            }
        }
        .overlay(alignment: .top) {
            if isTargeted {
                Text("Drop wallpapers to add them")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isTargeted)
    }

    /// Scrolls to the wallpaper Show in Library asked for and rings it for a moment, showing its kind if it was hidden.
    private func reveal(with proxy: ScrollViewProxy) {
        guard let id = model.focusedID else { return }
        model.focusedID = nil
        searchText = ""
        if let item = model.videos.first(where: { $0.id == id }) {
            model.hiddenLibraryKinds.remove(LibraryKind(item))
        }
        Task { @MainActor in
            await Task.yield()  // the cards exist after this layout pass
            withAnimation(WMMotion.content) { proxy.scrollTo(id, anchor: .center) }
            withAnimation(WMMotion.select) { highlightedID = id }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(WMMotion.content) { if highlightedID == id { highlightedID = nil } }
        }
    }

    /// Scrolls the card of what the clicked display shows to the middle of the library's view.
    private func revealCurrent(with proxy: ScrollViewProxy) {
        guard let content = currentContent, let id = content.wallpaperID ?? content.playlistID else { return }
        cardReveal.reveal(id, with: proxy)
    }

    /// The library's title, kind filters, sort controls, layout picker, search and Add menu in one row where they fit;
    /// in a narrow window, the title and the Add menu above the others.
    private func libraryHeader(count: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                libraryTitle(count: count)
                Spacer(minLength: 16)
                kindFilters
                sortControls
                layoutPicker
                searchField
                addMenu
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    libraryTitle(count: count)
                    Spacer(minLength: 16)
                    addMenu
                }
                HStack(spacing: 10) {
                    kindFilters
                    sortControls
                    layoutPicker
                    Spacer(minLength: 16)
                    searchField
                }
            }
        }
        // The sort menu is as wide as the sort's name: the controls around it move over smoothly.
        .animation(WMMotion.content, value: sort)
        .task(id: sort) {
            if sort == .created { model.fillCreationDates() }
        }
    }

    private func libraryTitle(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Your library")
                .font(.title3.weight(.semibold))
            Text(count, format: .number)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .fixedSize()
    }

    /// A button per kind of content; a kind that is off leaves the library.
    private var kindFilters: some View {
        HStack(spacing: WMTheme.chipSpacing) {
            ForEach(LibraryKind.allCases) { kind in
                WMTopicChip(title: kind.label, selected: !model.hiddenLibraryKinds.contains(kind)) {
                    if model.hiddenLibraryKinds.remove(kind) == nil { model.hiddenLibraryKinds.insert(kind) }
                }
            }
        }
        .fixedSize()
        .help("Show or hide playlists, scenes and videos")
    }

    /// What the library is sorted by, and which way.
    private var sortControls: some View {
        HStack(spacing: 4) {
            WMSortMenu(title: "Sort By", selection: $sort, options: LibrarySort.allCases, label: \.label)
                .help("Order of the library")
            WMIconPicker(title: "Sort Order", selection: $sortAscending, options: [
                .init(value: true, title: "Ascending", systemImage: "arrow.up"),
                .init(value: false, title: "Descending", systemImage: "arrow.down"),
            ])
            .help("Sort the library ascending or descending")
        }
    }

    private var layoutPicker: some View {
        WMIconPicker(title: "Layout", selection: $layout, options: [
            .init(value: .grid, title: "Grid", systemImage: "square.grid.2x2"),
            .init(value: .list, title: "List", systemImage: "list.bullet"),
        ])
        .help("Show the library as a grid or a list")
    }

    private var searchField: some View {
        WMSearchField(prompt: "Search your library", text: $searchText)
            .frame(minWidth: 120, idealWidth: 180, maxWidth: 260)
    }

    private var addMenu: some View {
        Menu {
            Button { importWallpapers() } label: {
                Label("Import Wallpapers", systemImage: "square.and.arrow.down.on.square")
            }
            Button { chooseVideos() } label: {
                Label("Add Videos", systemImage: "film")
            }
            Divider()
            Button { newPlaylist() } label: {
                Label("New Playlist", systemImage: "rectangle.stack.badge.plus")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Import videos, Wallpaper Engine scene packages or scene folders (⌘O), or make a playlist")
        .accessibilityLabel("Add wallpapers or a playlist")
    }

    private func libraryItems(_ entries: [LibraryEntry]) -> some View {
        Group {
            if entries.isEmpty {
                noResults
            } else {
                switch layout {
                case .grid:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: WMTheme.cardMinWidth, maximum: 340),
                                                 spacing: WMTheme.gridSpacing)],
                              alignment: .leading, spacing: WMTheme.gridSpacing) {
                        ForEach(entries) { entry in
                            let state = cardState(entry)
                            LibraryCard(entry: entry, broken: broken(entry), state: state, actions: actions(entry))
                                .id(entry.id)
                                .libraryRevealCard(entry.id, current: state.current, in: cardReveal)
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                case .list:
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in
                            let state = cardState(entry)
                            LibraryListRow(entry: entry, broken: broken(entry), state: state, actions: actions(entry))
                                .id(entry.id)
                                .libraryRevealCard(entry.id, current: state.current, in: cardReveal)
                        }
                    }
                }
            }
        }
        .animation(WMMotion.content, value: entries.map(\.id))
        .animation(WMMotion.select, value: currentContent)
    }

    private func broken(_ entry: LibraryEntry) -> Bool {
        if case .wallpaper(let item) = entry { return isBroken(item) }
        return false
    }

    private func cardState(_ entry: LibraryEntry) -> CardState {
        CardState(current: entry.content == currentContent, highlighted: entry.id == highlightedID)
    }

    private func actions(_ entry: LibraryEntry) -> CardActions {
        let content = entry.content
        let useOnAll: (() -> Void)? = model.screens.count > 1 ? { model.setContentOnAllDisplays(content) } : nil
        let click = { if let display = model.selectedDisplayID { model.setContent(content, on: display) } }
        switch entry {
        case .playlist(let playlist, _):
            return CardActions(click: click, useOnAllDisplays: useOnAll,
                               edit: { model.editPlaylist(playlist.id) },
                               remove: { pendingDeletion = playlist.id })
        case .wallpaper(let item):
            let choices = model.playlists.map {
                PlaylistChoice(id: $0.id, name: $0.name, containsItem: $0.items.contains(item.id))
            }
            return CardActions(click: click, useOnAllDisplays: useOnAll,
                               addToPlaylist: AddToPlaylist(playlists: choices) { playlist in
                                   if let playlist {
                                       model.addToPlaylist(playlist, items: [item.id])
                                   } else {
                                       model.createAndEditPlaylist(with: [item.id])
                                   }
                               },
                               showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) },
                               refreshPreview: isBroken(item) ? nil : {
                                   LibraryPreviewStore.shared.refresh(item, options: previewOptions(item.id))
                               },
                               remove: { remove(item) })
        }
    }

    private var emptyState: some View {
        WMEmptyState(icon: "play.rectangle.on.rectangle",
                     title: "Your wallpaper library is empty",
                     message: "Drop videos, Wallpaper Engine scene packages (.pkg) or scene folders here — or choose files from your Mac.",
                     actionTitle: "Import Wallpapers", action: importWallpapers,
                     secondaryTitle: "Browse the Workshop", secondaryAction: openWorkshop,
                     targeted: isTargeted)
        .contentShape(Rectangle())
        .onTapGesture(perform: importWallpapers)
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "line.3.horizontal.decrease" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No wallpapers match").font(.title3.weight(.semibold))
            Text(noResultsHint).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var noResultsHint: LocalizedStringKey {
        if model.hiddenLibraryKinds.isEmpty { return "Try another search." }
        return searchText.isEmpty ? "Turn on more content types above."
                                  : "Try another search, or turn on more content types above."
    }

    // MARK: Adding, removing and playlists

    private var skippedTitle: LocalizedStringKey {
        "Skipped \(skippedCount) files that aren’t wallpapers."
    }

    /// Brings dropped or chosen files in: videos by reference, scene packages and folders through the
    /// shared scene importer. Everything lands in the library and is committed to the service (state.json).
    private func add(_ urls: [URL]) {
        Task { @MainActor in
            let outcome = await WallpaperImporter.importURLs(urls, into: model)
            skippedCount = outcome.skipped
            importFailures = outcome.failed
            showSkipped = outcome.skipped > 0
            showFailures = !outcome.failed.isEmpty
        }
    }

    private func chooseVideos() {
        let urls = VideoPicker.choose()
        if !urls.isEmpty { add(urls) }
    }

    private func importWallpapers() {
        let urls = WallpaperPicker.choose()
        if !urls.isEmpty { add(urls) }
    }

    /// Makes an empty playlist and opens its editor.
    private func newPlaylist() {
        model.createAndEditPlaylist()
    }

    /// A Workshop download is deleted with it, so that asks first; a local video only leaves the library.
    private func remove(_ item: VideoItem) {
        if item.isWorkshop {
            pendingRemoval = [item.id]
        } else {
            model.remove(ids: [item.id])
        }
    }

    private func finishRemoval() {
        model.remove(ids: pendingRemoval)
        pendingRemoval = []
    }

    private var confirmingRemoval: Binding<Bool> {
        Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
    }

    private var removalTitle: LocalizedStringKey {
        let name = model.videos.first { pendingRemoval.contains($0.id) }?.name ?? ""
        return "Remove “\(name)” and delete its downloaded files?"
    }

    private var confirmingDeletion: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var deletionTitle: LocalizedStringKey {
        "Delete the playlist “\(model.playlist(pendingDeletion)?.name ?? "")”?"
    }
}

// MARK: - Cards

/// How a library card looks.
struct CardState: Equatable {
    /// The selected display shows this wallpaper or playlist.
    var current: Bool
    /// Show in Library pointed here a moment ago.
    var highlighted: Bool

    var ringColor: Color {
        if current { return WMTheme.accent }
        return highlighted ? WMTheme.accent.opacity(0.6) : Color.primary.opacity(0.07)
    }

    var ringWidth: CGFloat { current ? 2.5 : (highlighted ? 2 : 1) }
}

/// A playlist a wallpaper can be added to.
struct PlaylistChoice: Identifiable {
    let id: Playlist.ID
    let name: String
    let containsItem: Bool
}

/// The Add to Playlist menu of a wallpaper.
struct AddToPlaylist {
    let playlists: [PlaylistChoice]
    /// Adds the wallpaper to the playlist; nil = to a new playlist.
    let add: (Playlist.ID?) -> Void
}

/// What a library card can do.
struct CardActions {
    /// Puts the wallpaper or playlist on the selected display.
    let click: () -> Void
    /// nil with a single display.
    let useOnAllDisplays: (() -> Void)?
    /// Playlists: opens the editor.
    var edit: (() -> Void)? = nil
    /// Wallpapers.
    var addToPlaylist: AddToPlaylist? = nil
    var showInFinder: (() -> Void)? = nil
    /// Wallpapers that can play: has the service make the library's preview again.
    var refreshPreview: (() -> Void)? = nil
    /// Removes the wallpaper from the library or deletes the playlist, asking first where that deletes files.
    let remove: () -> Void
}

/// The menu of a library card (its context menu and the … button).
@MainActor
private struct CardMenu: View {
    let actions: CardActions

    var body: some View {
        if let edit = actions.edit {
            Button("Edit Playlist", action: edit)
        }
        if let useOnAllDisplays = actions.useOnAllDisplays {
            Button("Use on All Displays", action: useOnAllDisplays)
        }
        if let addToPlaylist = actions.addToPlaylist {
            Menu("Add to Playlist") {
                ForEach(addToPlaylist.playlists) { playlist in
                    Button(playlist.name) { addToPlaylist.add(playlist.id) }
                        .disabled(playlist.containsItem)
                }
                if !addToPlaylist.playlists.isEmpty { Divider() }
                Button("New Playlist") { addToPlaylist.add(nil) }
            }
        }
        if let showInFinder = actions.showInFinder {
            Button("Show in Finder", action: showInFinder)
        }
        if let refreshPreview = actions.refreshPreview {
            Button("Refresh Preview", action: refreshPreview)
        }
        Divider()
        if actions.edit != nil {
            Button("Delete Playlist", role: .destructive, action: actions.remove)
        } else {
            Button("Remove", role: .destructive, action: actions.remove)
        }
    }
}

/// An entry's picture: a wallpaper's preview or a playlist's artwork.
@MainActor
private struct EntryArtwork: View {
    let entry: LibraryEntry
    let broken: Bool
    let cornerRadius: CGFloat

    var body: some View {
        switch entry {
        case .playlist(let playlist, let items):
            PlaylistArtwork(playlist: playlist, items: items, cornerRadius: cornerRadius)
        case .wallpaper(let item):
            ItemThumbnail(item: item, broken: broken, cornerRadius: cornerRadius)
        }
    }
}

/// Marks the entry the selected display shows, in the top-left corner of its picture: a bold white checkmark on an
/// accent circle that pops in and out with the selection.
@MainActor
private struct CurrentBadge: View {
    let shown: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if shown {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, WMTheme.accent)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(WMMotion.success, value: shown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)  // the entry itself carries the selected trait
    }
}

/// The line under an entry's name: its type, then what else there is to know about it ("Scene · Workshop"). A wallpaper
/// of the user's own that plays has only its type.
private func entryMeta(_ entry: LibraryEntry, broken: Bool) -> String {
    let detail: String?
    switch entry {
    case .playlist(_, let items):
        detail = String(localized: "\(items.count) wallpapers")
    case .wallpaper(let item):
        detail = broken ? String(localized: "Missing or unreadable")
                        : item.isWorkshop ? String(localized: "Workshop") : nil
    }
    switch (entry.kind, detail) {
    case (.playlist, let detail?): return String(localized: "Playlist · \(detail)")
    case (.scene, let detail?): return String(localized: "Scene · \(detail)")
    case (.video, let detail?): return String(localized: "Video · \(detail)")
    case (.playlist, nil): return String(localized: "Playlist")
    case (.scene, nil): return String(localized: "Scene")
    case (.video, nil): return String(localized: "Video")
    }
}

@MainActor
private struct LibraryCard: View {
    let entry: LibraryEntry
    let broken: Bool
    let state: CardState
    let actions: CardActions
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                EntryArtwork(entry: entry, broken: broken, cornerRadius: 12)
                    .aspectRatio(16 / 9, contentMode: .fit)

                LinearGradient(colors: [.clear, .black.opacity(0.34)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if hovering {
                    HStack(spacing: 6) {
                        if let edit = actions.edit {
                            Button(action: edit) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 26, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Edit Playlist")
                            .accessibilityLabel("Edit Playlist")
                            .padding(4)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                        Menu {
                            CardMenu(actions: actions)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 26, height: 26)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                        .padding(4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(state.ringColor, lineWidth: state.ringWidth)
            }
            .overlay(alignment: .topLeading) {
                CurrentBadge(shown: state.current, size: 31)
                    .padding(8)
            }
            .shadow(color: .black.opacity(hovering || state.current ? 0.20 : 0), radius: 16, y: 8)
            .animation(WMMotion.hover, value: state)

            Text(entry.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(broken ? 0.6 : 1)
            Text(entryMeta(entry, broken: broken))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.click)
        .onHover { inside in
            withAnimation(WMMotion.hover) { hovering = inside }
        }
        .contextMenu { CardMenu(actions: actions) }
        .help(broken ? String(localized: "This file was moved, deleted, or can’t be played.") : entry.name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name), \(entryMeta(entry, broken: broken))")
        .accessibilityAddTraits(state.current ? .isSelected : [])
    }
}

@MainActor
private struct LibraryListRow: View {
    let entry: LibraryEntry
    let broken: Bool
    let state: CardState
    let actions: CardActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            EntryArtwork(entry: entry, broken: broken, cornerRadius: 8)
                .frame(width: 96, height: 54)
                .overlay(alignment: .topLeading) {
                    CurrentBadge(shown: state.current, size: 21)
                        .padding(4)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .opacity(broken ? 0.6 : 1)
                Text(entryMeta(entry, broken: broken))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let edit = actions.edit {
                Button(action: edit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit Playlist")
                    .accessibilityLabel("Edit Playlist")
            }
            Menu {
                CardMenu(actions: actions)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.click)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(state.current ? WMTheme.accent.opacity(0.12) : (hovering ? Color.primary.opacity(0.045) : .clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state.current || state.highlighted ? state.ringColor.opacity(0.5) : .clear, lineWidth: 1)
        }
        .onHover { inside in withAnimation(WMMotion.hover) { hovering = inside } }
        .contextMenu { CardMenu(actions: actions) }
        .accessibilityAddTraits(state.current ? .isSelected : [])
    }
}

// MARK: - Inspector

/// The selected display's wallpaper or playlist and that display's settings.
@MainActor
struct DisplayInspectorView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            if let screen = model.selectedScreen {
                content(screen)
                    .id(screen.id)  // a display's own state never carries over
                    .transition(.opacity)
            }
        }
        .scrollIndicators(.visible)
        .animation(WMMotion.content, value: model.selectedDisplayID)
    }

    private func content(_ screen: ScreenInfo) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.content(on: screen.id) {
            case .wallpaper:
                if let item = model.shownItem(on: screen.id) {
                    InspectorHeader(title: item.name, steamPage: item.workshopID.flatMap(WorkshopItem.pageURL(id:))) {
                        ItemThumbnail(item: item, broken: !FileManager.default.fileExists(atPath: item.path),
                                      cornerRadius: 8)
                    }
                    errorLine(screen)
                    WallpaperInfoSection(item: item)
                    WallpaperSettingsCard(model: model, scope: .display(screen.id), item: item)
                }
            case .playlist(let id):
                if let playlist = model.playlist(id) {
                    PlaylistSummary(model: model, playlist: playlist, screen: screen)
                    errorLine(screen)
                    EnergySection(model: model, display: screen.id)
                }
            case nil:
                VStack(spacing: 10) {
                    Image(systemName: "display").font(.system(size: 22, weight: .light))
                    Text(screen.name).font(.callout.weight(.medium))
                    Text("This display has no live wallpaper. Click a wallpaper or a playlist in your library to use it here.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
        }
        .padding(18)
        // The panel starts at the window's top edge, in the toolbar strip (see `wmInspectorPanel`).
        .padding(.top, WMTheme.toolbarStripPadding)
    }

    @ViewBuilder private func errorLine(_ screen: ScreenInfo) -> some View {
        if let error = model.error(on: screen.id) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The top of an inspector: a square picture, a name and, when given, a link to the Workshop page under the name.
struct InspectorHeader<Picture: View>: View {
    let title: String
    var steamPage: URL? = nil
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        HStack(spacing: 11) {
            picture()
                .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(3).truncationMode(.middle)
                if let steamPage {
                    Link(destination: steamPage) {
                        Label("Open in Steam", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }
}

/// A display's playlist in its inspector: what it shows now and the playlist's Info box, with the way to its editor.
@MainActor
private struct PlaylistSummary: View {
    @ObservedObject var model: SettingsModel
    let playlist: Playlist
    let screen: ScreenInfo

    var body: some View {
        let items = model.items(of: playlist)
        VStack(alignment: .leading, spacing: 20) {
            InspectorHeader(title: playlist.name) {
                PlaylistArtwork(playlist: playlist, items: items, cornerRadius: 8)
            }
            if let item = model.liveItem(on: screen.id) {
                InspectorSection(title: "Now Showing") {
                    HStack(spacing: 10) {
                        ItemThumbnail(item: item, cornerRadius: 5)
                            .frame(width: 64, height: 36)
                        Text(item.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                PlaylistInfoSection(playlist: playlist, items: items)
                Button {
                    model.editPlaylist(playlist.id)
                } label: {
                    Label("Edit Playlist", systemImage: "pencil").frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("Change the playlist’s wallpapers, their order and settings, its timing and its transition.")
            }
        }
    }
}
