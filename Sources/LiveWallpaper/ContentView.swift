import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers
import Core

// The Library: a gallery-first wall of wallpapers, with a large live preview and a context inspector.

enum LibraryFilter: String, CaseIterable, Identifiable, Equatable {
    case all, desktop, scenes

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Wallpapers"
        case .desktop: return "Desktop"
        case .scenes: return "Scenes"
        }
    }

    /// `selected`: the item is the selected desktop wallpaper.
    func includes(_ item: VideoItem, selected: Bool) -> Bool {
        switch self {
        case .all: return true
        case .desktop: return selected
        case .scenes: return item.isScene
        }
    }
}

enum LibraryLayout: String, CaseIterable {
    case grid, list
}

@MainActor
struct LibraryView: View {
    @ObservedObject var model: SettingsModel
    let filter: LibraryFilter
    @Binding var showInspector: Bool
    let openWorkshop: () -> Void
    let openSteamSetup: () -> Void

    @State private var searchText = ""
    @State private var layout: LibraryLayout = .grid
    @State private var isTargeted = false
    @State private var skippedCount = 0
    @State private var showSkipped = false
    @State private var importFailures: [String] = []
    @State private var showFailures = false
    @State private var pendingRemoval: Set<VideoItem.ID> = []
    @State private var selectedIDs: Set<VideoItem.ID> = []
    @State private var anchorID: VideoItem.ID?
    @State private var selectionMode = false

    init(model: SettingsModel, filter: LibraryFilter, showInspector: Binding<Bool>,
         openWorkshop: @escaping () -> Void, openSteamSetup: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self.filter = filter
        self._showInspector = showInspector
        self.openWorkshop = openWorkshop
        self.openSteamSetup = openSteamSetup
    }

    var body: some View {
        Group {
            if model.videos.isEmpty {
                emptyState
            } else if items.isEmpty {
                noResults
            } else {
                gallery
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { isTargeted = $0 }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search wallpapers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(LWMotion.panel) {
                        selectionMode.toggle()
                        if !selectionMode, let focused { selectedIDs = [focused.id] }
                    }
                } label: {
                    Image(systemName: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(selectionMode ? "Stop selecting multiple" : "Select multiple wallpapers")
                .accessibilityLabel(selectionMode ? "Stop selecting multiple" : "Select multiple wallpapers")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: removeSelection) {
                    Image(systemName: "trash")
                }
                .disabled(selectedIDs.isEmpty)
                .help(removalHelp)
                .accessibilityLabel(removalHelp)
                .keyboardShortcut(.delete, modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { layout = .grid } label: { Label("Grid", systemImage: "square.grid.2x2") }
                    Button { layout = .list } label: { Label("List", systemImage: "list.bullet") }
                } label: {
                    Image(systemName: layout == .grid ? "square.grid.2x2" : "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Change layout")
                .accessibilityLabel("Change layout")
            }
        }
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
            Text(pendingRemoval.count > 1
                 ? "Downloaded Workshop files are deleted and can be downloaded again."
                 : "You can download it again from the Workshop.")
        }
        .onAppear { reconcileSelection() }
        .onChange(of: filter) { _ in reconcileSelection() }
        .onChange(of: searchText) { _ in reconcileSelection() }
        .onChange(of: model.videos.map(\.id)) { _ in reconcileSelection() }
    }

    // MARK: Data

    private var state: LibraryState { model.snapshot }

    private var items: [VideoItem] {
        let state = state
        return model.videos.filter { item in
            filter.includes(item, selected: state.isSelected(item.id)) &&
            (searchText.isEmpty ||
             item.name.localizedCaseInsensitiveContains(searchText) ||
             (item.author ?? "").localizedCaseInsensitiveContains(searchText))
        }
    }

    private var focused: VideoItem? {
        items.first { $0.id == model.focusedID } ?? items.first
    }

    private var selectionCount: Int { selectedIDs.count }

    private var removalHelp: String {
        selectionCount > 1 ? "Remove \(selectionCount) wallpapers (⌘⌫)" : "Remove selected wallpaper (⌘⌫)"
    }

    /// Keeps the multi-selection inside what is visible after a filter, search or library change.
    private func reconcileSelection() {
        let visible = Set(items.map(\.id))
        selectedIDs.formIntersection(visible)

        if let focused = model.focusedID, visible.contains(focused) {
            if selectedIDs.isEmpty { selectedIDs.insert(focused) }
        } else if let firstSelected = items.first(where: { selectedIDs.contains($0.id) }) {
            model.focusedID = firstSelected.id
        } else {
            model.focusedID = items.first?.id
            if let first = items.first { selectedIDs.insert(first.id) }
        }

        if let anchorID, visible.contains(anchorID) {
            // Keep the range anchor while it is still on screen.
        } else {
            anchorID = model.focusedID
        }
    }

    private func select(_ item: VideoItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchorID,
           let from = items.firstIndex(where: { $0.id == anchorID }),
           let to = items.firstIndex(where: { $0.id == item.id }) {
            let range = min(from, to)...max(from, to)
            selectedIDs = Set(items[range].map(\.id))
            model.focusedID = item.id
        } else if selectionMode || flags.contains(.command) {
            toggleSelection(item.id)
        } else {
            selectedIDs = [item.id]
            model.focusedID = item.id
            anchorID = item.id
        }
    }

    private func toggleSelection(_ id: VideoItem.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if model.focusedID == id {
                model.focusedID = items.first(where: { selectedIDs.contains($0.id) })?.id ?? id
            }
        } else {
            selectedIDs.insert(id)
            model.focusedID = id
            anchorID = id
        }
    }

    private func removeSelection() {
        guard !selectedIDs.isEmpty else { return }
        remove(selectedIDs)
    }

    private func isBroken(_ item: VideoItem) -> Bool {
        model.failedIDs.contains(item.id) || !FileManager.default.fileExists(atPath: item.path)
    }

    // MARK: Content

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                heading
                if let item = focused {
                    LibraryHero(model: model, item: item, broken: isBroken(item),
                                playing: model.isPlaying(item.id),
                                openSteamSetup: openSteamSetup,
                                remove: { remove([item.id]) })
                        .transition(.opacity)
                }
                librarySection
            }
            .padding(LWTheme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .animation(LWMotion.hero, value: focused?.id)
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

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(filter.title)
                .font(.system(size: 30, weight: .bold))
                .kerning(-0.4)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        if selectionCount > 1 {
            return "\(selectionCount) selected · click checkmarks to adjust"
        }
        if selectionMode {
            return selectionCount == 0
                ? "Select wallpapers to remove."
                : "1 selected · click to add or remove"
        }
        if !searchText.isEmpty {
            return "\(items.count) \(items.count == 1 ? "result" : "results") for “\(searchText)”"
        }
        switch filter {
        case .all: return "\(items.count) \(items.count == 1 ? "wallpaper" : "wallpapers")"
        case .desktop: return "\(items.count) set for your desktop"
        case .scenes: return "\(items.count) Wallpaper Engine \(items.count == 1 ? "scene" : "scenes")"
        }
    }

    @ViewBuilder private var librarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(filter == .all ? "Your library" : "Wallpapers")
                    .font(.title3.weight(.semibold))
                Text("\(items.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    Button { importWallpapers() } label: {
                        Label("Import Wallpapers…", systemImage: "square.and.arrow.down.on.square")
                    }
                    Button { chooseVideos() } label: {
                        Label("Add Videos…", systemImage: "film")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import videos, Wallpaper Engine scene packages or scene folders (⌘O)")
                .accessibilityLabel("Add wallpapers")
            }

            switch layout {
            case .grid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: LWTheme.cardMinWidth, maximum: 340),
                                             spacing: LWTheme.gridSpacing)],
                          alignment: .leading, spacing: LWTheme.gridSpacing) {
                    ForEach(items) { item in
                        LibraryCard(item: item,
                                    broken: isBroken(item),
                                    isDesktop: state.isSelected(item.id),
                                    playing: model.isPlaying(item.id),
                                    paused: model.isPaused,
                                    focused: item.id == focused?.id,
                                    selected: selectedIDs.contains(item.id),
                                    selectionMode: selectionMode,
                                    onSelect: { select(item) },
                                    onToggleSelect: { toggleSelection(item.id) },
                                    onActivate: { model.play(item.id) },
                                    assign: { model.assign(item.id) },
                                    remove: { remove([item.id]) })
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            case .list:
                LazyVStack(spacing: 4) {
                    ForEach(items) { item in
                        LibraryListRow(item: item,
                                       broken: isBroken(item),
                                       isDesktop: state.isSelected(item.id),
                                       playing: model.isPlaying(item.id),
                                       paused: model.isPaused,
                                       focused: item.id == focused?.id,
                                       selected: selectedIDs.contains(item.id),
                                       selectionMode: selectionMode,
                                       onSelect: { select(item) },
                                       onToggleSelect: { toggleSelection(item.id) },
                                       onActivate: { model.play(item.id) },
                                       assign: { model.assign(item.id) },
                                       remove: { remove([item.id]) })
                    }
                }
            }
        }
        .animation(LWMotion.content, value: items.map(\.id))
    }

    private var emptyState: some View {
        LWEmptyState(icon: "play.rectangle.on.rectangle",
                     title: "Your wallpaper library is empty",
                     message: "Drop videos, Wallpaper Engine scene packages (.pkg) or scene folders here — or choose files from your Mac.",
                     actionTitle: "Import Wallpapers…", action: importWallpapers,
                     secondaryTitle: "Browse the Workshop", secondaryAction: openWorkshop,
                     targeted: isTargeted)
        .contentShape(Rectangle())
        .onTapGesture(perform: importWallpapers)
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text("No wallpapers match").font(.title3.weight(.semibold))
            Text(searchText.isEmpty ? "There is nothing in this collection yet." : "Try another search.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Removing and adding

    private var skippedTitle: String {
        skippedCount == 1 ? "Skipped 1 file that isn’t a wallpaper." : "Skipped \(skippedCount) files that aren’t wallpapers."
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
            reconcileSelection()
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

    private func remove(_ ids: Set<VideoItem.ID>) {
        guard !ids.isEmpty else { return }
        if model.videos.contains(where: { ids.contains($0.id) && $0.isWorkshop }) {
            pendingRemoval = ids
        } else {
            model.remove(ids: ids)
            reconcileSelection()
        }
    }

    private func finishRemoval() {
        model.remove(ids: pendingRemoval)
        pendingRemoval = []
        reconcileSelection()
    }

    private var confirmingRemoval: Binding<Bool> {
        Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
    }

    private var removalTitle: String {
        let names = model.videos.filter { pendingRemoval.contains($0.id) }.map(\.name)
        return names.count == 1 ? "Remove “\(names[0])” and delete its downloaded files?"
                                : "Remove \(names.count) wallpapers and delete the downloaded files of Workshop items?"
    }
}

// MARK: - Hero

@MainActor
private struct LibraryHero: View {
    @ObservedObject var model: SettingsModel
    let item: VideoItem
    let broken: Bool
    let playing: Bool
    let openSteamSetup: () -> Void
    let remove: () -> Void

    private var isDesktop: Bool { model.isSelected(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottom) {
                ItemPreviewPane(item: item, broken: broken, openSteamSetup: openSteamSetup, showsNotes: false)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: LWTheme.panelRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LWTheme.panelRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    }

                LinearGradient(colors: [.clear, .black.opacity(0.42)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: LWTheme.panelRadius, style: .continuous))

                HStack(alignment: .bottom, spacing: 10) {
                    if playing {
                        HStack(spacing: 6) {
                            ActivityBars(playing: true, paused: model.isPaused, tint: .white)
                            Text(model.isPaused ? "Paused" : "Playing")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    transport
                }
                .padding(12)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if playing {
                            LWChip(text: "Desktop", tint: .accentColor, filled: true, icon: "checkmark")
                        }
                        if item.isScene, let info = item.scene { SceneSupportBadge(info: info) }
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button {
                        model.assign(item.id)
                    } label: {
                        Label("Set as Desktop", systemImage: isDesktop ? "checkmark" : "display")
                    }
                    .disabled(isDesktop)
                    .fixedSize()

                    Button {
                        model.clearStatus()
                        if playing { model.stop() } else { model.play(item.id) }
                    } label: {
                        Label(playing ? "Stop" : "Play",
                              systemImage: playing ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(playing ? .red : nil)
                }
                .controlSize(.large)
            }
        }
    }

    private var transport: some View {
        GlassPanel(radius: 13) {
            HStack(spacing: 2) {
                iconButton(playing ? "stop.fill" : "play.fill",
                           help: playing ? "Stop wallpaper" : "Play wallpaper") {
                    model.clearStatus()
                    if playing { model.stop() } else { model.play(item.id) }
                }
                iconButton(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           help: model.muted ? "Unmute" : "Mute") {
                    model.muted.toggle()
                }
                iconButton("arrow.up.left.and.arrow.down.right", help: "Enter full screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                iconButton("folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                iconButton("trash", help: "Remove from library") { remove() }
            }
            .padding(4)
        }
        .fixedSize()
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var meta: String {
        if item.isWorkshop { return "Workshop" }
        return item.isScene ? "Scene" : "Video"
    }
}

// MARK: - Cards

@MainActor
private struct LibraryCard: View {
    let item: VideoItem
    let broken: Bool
    /// The selected desktop wallpaper.
    let isDesktop: Bool
    let playing: Bool
    let paused: Bool
    let focused: Bool
    let selected: Bool
    let selectionMode: Bool
    let onSelect: () -> Void
    let onToggleSelect: () -> Void
    let onActivate: () -> Void
    let assign: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    ItemThumbnail(item: item, broken: broken, cornerRadius: 12)
                        .aspectRatio(16 / 9, contentMode: .fit)

                    LinearGradient(colors: [.clear, .black.opacity(0.34)],
                                   startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 4) {
                        if isDesktop {
                            LWChip(text: "Desktop", tint: .accentColor, filled: playing,
                                   icon: playing ? "waveform" : nil)
                        }
                        if let info = item.scene { SceneSupportBadge(info: info) }
                    }
                    .padding(7)

                    if hovering && !broken && !selectionMode {
                        HStack(spacing: 5) {
                            Button {
                                onActivate()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .help("Play wallpaper")

                            Menu {
                                SetAsItems(isDesktop: isDesktop, assign: assign)
                                Divider()
                                Button("Remove…", role: .destructive, action: remove)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 26, height: 26)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                        .padding(4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(focused ? 1 : 0.72)
                                               : Color.primary.opacity(0.07),
                                      lineWidth: selected ? (focused ? 2.5 : 2) : 1)
                }
                .shadow(color: .black.opacity(hovering || selected ? 0.20 : 0), radius: 16, y: 8)
                .animation(LWMotion.hover, value: selected)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(broken ? 0.6 : 1)
                    Spacer(minLength: 0)
                    if playing {
                        ActivityBars(playing: true, paused: paused)
                    }
                }
                Text(cardMeta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onTapGesture(count: 2, perform: onActivate)

            if selected || hovering || selectionMode {
                selectionBadge
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .onHover { inside in
            withAnimation(LWMotion.hover) { hovering = inside }
        }
        .contextMenu {
            SetAsItems(isDesktop: isDesktop, assign: assign)
            Divider()
            Button("Remove…", role: .destructive, action: remove)
        }
        .help(broken ? "This file was moved, deleted, or can’t be played." : item.name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(cardMeta)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var selectionBadge: some View {
        Button(action: onToggleSelect) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.95),
                                 selected ? Color.accentColor : Color.white.opacity(0.55))
                .font(.system(size: 16, weight: .semibold))
                .padding(3)
                .background(Circle().fill(Color.black.opacity(0.36)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Deselect" : "Add to selection")
        .accessibilityLabel(selected ? "Deselect wallpaper" : "Select wallpaper")
    }

    private var cardMeta: String {
        if broken { return "Missing or unreadable" }
        if item.isWorkshop { return "Workshop" }
        return item.isScene ? "Scene" : "Video"
    }
}

@MainActor
private struct LibraryListRow: View {
    let item: VideoItem
    let broken: Bool
    /// The selected desktop wallpaper.
    let isDesktop: Bool
    let playing: Bool
    let paused: Bool
    let focused: Bool
    let selected: Bool
    let selectionMode: Bool
    let onSelect: () -> Void
    let onToggleSelect: () -> Void
    let onActivate: () -> Void
    let assign: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if selectionMode || selected || hovering {
                    Button(action: onToggleSelect) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(selected ? "Deselect" : "Add to selection")
                    .accessibilityLabel(selected ? "Deselect wallpaper" : "Select wallpaper")
                } else {
                    Color.clear.frame(width: 15, height: 15)
                }
            }
            .frame(width: 16, height: 16)

            HStack(spacing: 12) {
                ItemThumbnail(item: item, broken: broken, cornerRadius: 8)
                    .frame(width: 96, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 5) {
                        if isDesktop {
                            LWChip(text: "Desktop", tint: .accentColor, filled: playing)
                        }
                        if item.isScene, let info = item.scene { SceneSupportBadge(info: info) }
                    }
                }
                Spacer(minLength: 8)
                if playing { ActivityBars(playing: true, paused: paused) }
                Menu {
                    SetAsItems(isDesktop: isDesktop, assign: assign)
                    Divider()
                    Button("Remove…", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onTapGesture(count: 2, perform: onActivate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.045) : .clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(focused ? 0.45 : 0.25) : .clear,
                              lineWidth: 1)
        }
        .onHover { inside in withAnimation(LWMotion.hover) { hovering = inside } }
        .contextMenu {
            SetAsItems(isDesktop: isDesktop, assign: assign)
            Divider()
            Button("Remove…", role: .destructive, action: remove)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Inspector

@MainActor
struct LibraryInspectorView: View {
    @ObservedObject var model: SettingsModel
    let item: VideoItem?
    let openSteamSetup: () -> Void
    let remove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let item {
                    header(item)
                    setAsSection(item)
                    if item.isScene { SceneSettingsCard(model: model, item: item) }
                    LibrarySettingsCard(model: model)
                    removeSection(item)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "sidebar.right").font(.system(size: 22, weight: .light))
                        Text("Select a wallpaper").font(.callout.weight(.medium))
                        Text("Its settings and rotation options appear here.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.visible)
        .alert("Remove this wallpaper?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the downloaded files. You can download it again from the Workshop.")
        }
    }

    private func header(_ item: VideoItem) -> some View {
        HStack(spacing: 11) {
            ItemThumbnail(item: item, broken: !FileManager.default.fileExists(atPath: item.path),
                          showsHoverPreview: false, cornerRadius: 8)
                .frame(width: 76, height: 43)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                Text(item.isScene ? "Scene" : "Video")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func setAsSection(_ item: VideoItem) -> some View {
        let selected = model.isSelected(item.id)
        return InspectorSection(title: "Set as") {
            Button {
                model.assign(item.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "display").frame(width: 16)
                    Text("Desktop")
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func removeSection(_ item: VideoItem) -> some View {
        InspectorSection(title: "Danger zone") {
            Button(role: .destructive) {
                if item.isWorkshop { confirmingRemoval = true } else { remove() }
            } label: {
                Label("Remove from library", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        }
    }
}

// MARK: - Set as

@MainActor
fileprivate struct SetAsItems: View {
    let isDesktop: Bool
    let assign: () -> Void

    var body: some View {
        Button(action: assign) {
            if isDesktop { Label("Set as Desktop", systemImage: "checkmark") } else { Text("Set as Desktop") }
        }
    }
}

// MARK: - Badges

@MainActor
struct SceneSupportBadge: View {
    let info: SceneInfo

    private var title: String {
        switch info.support {
        case .full: return "Scene"
        case .partial: return "Partial"
        case .previewOnly: return "Preview"
        }
    }

    private var tint: Color { info.support == .previewOnly ? .orange : .secondary }

    var body: some View {
        LWChip(text: title, tint: tint, icon: "sparkles")
            .help(info.notes.joined(separator: "\n"))
    }
}

// MARK: - Settings card

/// Mute, rotation and the scene settings.
@MainActor
struct LibrarySettingsCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection(title: "Playback") {
                Toggle("Mute sound", isOn: $model.muted)
                    .help("Videos play silently.")
            }

            Divider()

            InspectorSection(title: "Rotation", subtitle: "Runs on a playlist you curate in Playlists.") {
                RotationBlock(model: model)
            }

            Divider()

            InspectorSection(title: "Scenes") {
                VStack(alignment: .leading, spacing: 14) {
                    LWSettingRow(title: "Frame rate",
                                 help: "Smoothness of scene wallpapers. Higher looks smoother but keeps the GPU busier.") {
                        Picker("Scene frame rate", selection: $model.sceneFPS) {
                            ForEach([20, 24, 30, 45, 60], id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    ScenePowerRows(model: model)
                }
            }
        }
    }
}

@MainActor
struct RotationBlock: View {
    @ObservedObject var model: SettingsModel
    @State private var intervalText: String
    @FocusState private var intervalFocused: Bool

    init(model: SettingsModel) {
        self._model = ObservedObject(wrappedValue: model)
        self._intervalText = State(initialValue: String(model.snapshot.desktop.intervalValue))
    }

    private var config: PlaybackConfig { model.snapshot.desktop }
    private var hasPlaylist: Bool { config.playlist != nil }
    private var canRotate: Bool { hasPlaylist && model.snapshot.hasMultipleItems }
    private var itemCount: Int { model.snapshot.items.count }
    private var enteredValue: Int? { Int(intervalText).flatMap { $0 > 0 ? min($0, 999) : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Rotate wallpaper")
                Spacer()
                Toggle("Rotate wallpaper", isOn: rotateBinding).labelsHidden().toggleStyle(.switch)
            }
            .disabled(!canRotate)
            .help("Automatically switch between your wallpapers, in list order.")
            if config.rotateEnabled && canRotate { intervalRow }
            if let helper {
                Text(helper.text)
                    .font(.caption)
                    .foregroundStyle(helper.warning ? Color.orange : Color.secondary)
            }
        }
        .animation(LWMotion.panel, value: config.rotateEnabled && canRotate)
        .onChange(of: config.intervalValue) { intervalText = String($0) }
    }

    private var intervalRow: some View {
        HStack(spacing: 8) {
            Text("Every").font(.callout)
            TextField("", text: $intervalText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($intervalFocused)
                .onSubmit(commitInterval)
                .onChange(of: intervalFocused) { if !$0 { commitInterval() } }
                .accessibilityLabel("Interval value")
            Picker("Interval unit", selection: unitBinding) {
                ForEach(IntervalUnit.allCases) { Text($0.label.lowercased()).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 104)
        }
    }

    private var helper: (text: String, warning: Bool)? {
        guard canRotate else {
            if !hasPlaylist {
                return ("Rotation cycles a playlist you choose. Set one up in Playlists.", false)
            }
            return ("Add at least two wallpapers to the playlist to rotate.", false)
        }
        guard config.rotateEnabled else { return nil }
        if enteredValue == nil { return ("Enter a number from 1 to 999.", true) }
        if config.intervalIsClamped { return ("Minimum is 5 seconds.", true) }
        return ("Cycles through \(itemCount) wallpapers in playlist order.", false)
    }

    private var rotateBinding: Binding<Bool> {
        Binding(get: { config.rotateEnabled && canRotate },
                set: { model.rotateEnabled = $0 })
    }

    private var unitBinding: Binding<IntervalUnit> {
        Binding(get: { config.intervalUnit },
                set: { model.intervalUnit = $0 })
    }

    private func commitInterval() {
        if let value = enteredValue { model.intervalValue = value }
        intervalText = String(config.intervalValue)
    }
}

// MARK: - Preview player

@MainActor
final class PreviewPlayer: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var url: URL?
    private var isActive = true

    func load(_ url: URL?) {
        guard url != self.url else {
            setActive(isActive)
            return
        }
        self.url = url
        player?.pause()
        looper = nil
        player = nil
        guard let url else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        setActive(isActive)
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { player?.play() } else { player?.pause() }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

struct ItemPreviewPane: View {
    let item: VideoItem?
    let broken: Bool
    let openSteamSetup: () -> Void
    var showsNotes = true
    @StateObject private var preview = PreviewPlayer()
    @State private var sceneImage: NSImage?

    init(item: VideoItem?, broken: Bool, openSteamSetup: @escaping () -> Void, showsNotes: Bool = true) {
        self.item = item
        self.broken = broken
        self.openSteamSetup = openSteamSetup
        self.showsNotes = showsNotes
    }

    private var playbackURL: URL? { broken || item?.isScene == true ? nil : item?.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            stage
            if showsNotes, let info = item?.scene { SceneNotes(info: info, openSteamSetup: openSteamSetup) }
        }
    }

    private var stage: some View {
        MediaStage(item: item, broken: broken, preview: preview, sceneImage: sceneImage)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .task(id: playbackURL) { preview.load(playbackURL) }
            .task(id: item?.previewPath) {
                sceneImage = item?.previewPath.flatMap { NSImage(contentsOfFile: $0) }
            }
            .onAppear { preview.setActive(true) }
            .onDisappear { preview.setActive(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                if let window = note.object as? NSWindow, window.styleMask.contains(.titled) {
                    preview.setActive(window.occlusionState.contains(.visible))
                }
            }
    }
}

private struct MediaStage: View {
    let item: VideoItem?
    let broken: Bool
    @ObservedObject var preview: PreviewPlayer
    let sceneImage: NSImage?

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .overlay(alignment: .topLeading) {
            if let info = item?.scene { SceneSupportBadge(info: info).padding(9) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.map { "Preview of \($0.name)" } ?? "No wallpaper selected")
    }

    @ViewBuilder private var content: some View {
        if broken {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30)).foregroundStyle(.orange)
                Text(item?.isScene == true ? "Can’t show this wallpaper" : "Can’t play this video")
                    .font(.headline)
                Text("The file may have been moved or deleted.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        } else if let item {
            if item.isScene {
                if let sceneImage {
                    AnimatedImageView(image: sceneImage)
                } else {
                    Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.tertiary)
                }
            } else {
                PlayerSurface(player: preview.player)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 30, weight: .light))
                Text("Select a wallpaper").font(.callout)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// What a scene cannot do yet, as a short list, plus the way to get Wallpaper Engine's shared files.
@MainActor
fileprivate struct SceneNotes: View {
    let info: SceneInfo
    let openSteamSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(info.notes.enumerated()), id: \.offset) { entry in
                Text("• " + entry.element).font(.callout).foregroundStyle(.secondary)
            }
            if !SceneImporter.hasSharedAssets {
                Text("• Scenes need Wallpaper Engine’s shared files to play.").font(.callout).foregroundStyle(.secondary)
            }
            if info.needsSharedAssets || !SceneImporter.hasSharedAssets {
                Button("Get Wallpaper Engine’s shared files", action: openSteamSetup).buttonStyle(.link)
            }
        }
    }
}
