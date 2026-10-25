import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers
import Core

// Home: the connected displays (DisplayArrangementView) above the wallpaper library. Clicking a wallpaper puts it on
// the selected display at once; the inspector holds that display's settings.

enum LibraryLayout: String, CaseIterable {
    case grid, list
}

@MainActor
struct HomeView: View {
    @ObservedObject var model: SettingsModel
    let openWorkshop: () -> Void

    @State private var searchText = ""
    @State private var layout: LibraryLayout = .grid
    @State private var isTargeted = false
    @State private var skippedCount = 0
    @State private var showSkipped = false
    @State private var importFailures: [String] = []
    @State private var showFailures = false
    @State private var pendingRemoval: Set<VideoItem.ID> = []
    /// Selecting several wallpapers (to remove them) instead of putting the clicked one on the display.
    @State private var selectionMode = false
    @State private var selectedIDs: Set<VideoItem.ID> = []
    @State private var anchorID: VideoItem.ID?
    /// Ringed for a moment after Show in Library scrolled to it.
    @State private var highlightedID: VideoItem.ID?

    var body: some View {
        Group {
            if model.videos.isEmpty {
                emptyState
            } else {
                gallery
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { isTargeted = $0 }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search wallpapers")
        // Standard toolbar controls with fixed labels: a toggle shows the selection mode by its own on state, so
        // nothing in the toolbar swaps its image while the page animates.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { selectionMode }, set: { setSelectionMode($0) })) {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .toggleStyle(.button)
                .help(selectionMode ? "Stop selecting" : "Select wallpapers to remove")
                .redrawnOnWindowActivation()
                Button(action: removeSelection) {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(!selectionMode || selectedIDs.isEmpty)
                .help(removalHelp)
                .keyboardShortcut(.delete, modifiers: .command)
                .redrawnOnWindowActivation()
                Picker("Layout", selection: $layout) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                }
                .pickerStyle(.segmented)
                .help("Show the library as a grid or a list")
                .redrawnOnWindowActivation()
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
        .onChange(of: model.videos.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
    }

    // MARK: Data

    private var items: [VideoItem] {
        model.videos.filter { item in
            searchText.isEmpty ||
            item.name.localizedCaseInsensitiveContains(searchText) ||
            (item.author ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    /// What the selected display shows; its card is ringed.
    private var currentID: VideoItem.ID? {
        model.selectedDisplayID.flatMap { model.shownItem(on: $0)?.id }
    }

    private var removalHelp: LocalizedStringKey {
        selectedIDs.count > 1 ? "Remove \(selectedIDs.count) wallpapers (⌘⌫)" : "Remove selected wallpaper (⌘⌫)"
    }

    private func isBroken(_ item: VideoItem) -> Bool {
        !FileManager.default.fileExists(atPath: item.path)
    }

    // MARK: Clicks

    /// A click puts the wallpaper on the selected display. While selecting, it adds or removes the wallpaper from
    /// the selection instead (Shift extends it from the last click); ⌘ or Shift starts selecting.
    private func click(_ item: VideoItem) {
        let flags = NSEvent.modifierFlags
        if !selectionMode, flags.contains(.command) || flags.contains(.shift) {
            setSelectionMode(true)
        }
        if selectionMode {
            if flags.contains(.shift), let anchorID,
               let from = items.firstIndex(where: { $0.id == anchorID }),
               let to = items.firstIndex(where: { $0.id == item.id }) {
                selectedIDs.formUnion(items[min(from, to)...max(from, to)].map(\.id))
            } else {
                toggleSelection(item.id)
            }
            anchorID = item.id
        } else if let display = model.selectedDisplayID {
            model.setWallpaper(item.id, on: display)
        }
    }

    private func toggleSelection(_ id: VideoItem.ID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func setSelectionMode(_ on: Bool) {
        selectionMode = on
        selectedIDs = []
        anchorID = nil
    }

    private func removeSelection() {
        guard selectionMode, !selectedIDs.isEmpty else { return }
        remove(selectedIDs)
    }

    // MARK: Content

    /// The page header, the display picker and the library's title row stay put; only the wallpapers below them
    /// scroll.
    private var gallery: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                WMPageHeader(title: "Home", subtitle: subtitle)
                DisplayPicker(model: model)
                libraryHeader
            }
            .padding([.horizontal, .top], WMTheme.contentPadding)
            .padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    libraryItems
                        .padding([.horizontal, .bottom], WMTheme.contentPadding)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onAppear { reveal(with: proxy) }
                .onChange(of: model.focusedID) { reveal(with: proxy) }
            }
        }
        .animation(WMMotion.panel, value: selectionMode)
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

    /// Scrolls to the wallpaper Show in Library asked for and rings it for a moment.
    private func reveal(with proxy: ScrollViewProxy) {
        guard let id = model.focusedID else { return }
        model.focusedID = nil
        searchText = ""
        Task { @MainActor in
            await Task.yield()  // the cards exist after this layout pass
            withAnimation(WMMotion.content) { proxy.scrollTo(id, anchor: .center) }
            withAnimation(WMMotion.select) { highlightedID = id }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(WMMotion.content) { if highlightedID == id { highlightedID = nil } }
        }
    }

    /// Only selection mode has a subtitle; the library's count sits beside its title.
    private var subtitle: LocalizedStringKey? {
        guard selectionMode else { return nil }
        return selectedIDs.isEmpty ? "Select wallpapers to remove." : "\(selectedIDs.count) selected"
    }

    private var libraryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Your library")
                .font(.title3.weight(.semibold))
            Text(items.count, format: .number)
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
    }

    private var libraryItems: some View {
        Group {
            if items.isEmpty {
                noResults
            } else {
                switch layout {
                case .grid:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: WMTheme.cardMinWidth, maximum: 340),
                                                 spacing: WMTheme.gridSpacing)],
                              alignment: .leading, spacing: WMTheme.gridSpacing) {
                        ForEach(items) { item in
                            LibraryCard(item: item, broken: isBroken(item), state: cardState(item),
                                        actions: actions(item))
                                .id(item.id)
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                case .list:
                    LazyVStack(spacing: 4) {
                        ForEach(items) { item in
                            LibraryListRow(item: item, broken: isBroken(item), state: cardState(item),
                                           actions: actions(item))
                                .id(item.id)
                        }
                    }
                }
            }
        }
        .animation(WMMotion.content, value: items.map(\.id))
        .animation(WMMotion.select, value: currentID)
    }

    private func cardState(_ item: VideoItem) -> CardState {
        CardState(current: !selectionMode && item.id == currentID,
                  highlighted: item.id == highlightedID,
                  selectionMode: selectionMode,
                  selected: selectedIDs.contains(item.id))
    }

    private func actions(_ item: VideoItem) -> CardActions {
        CardActions(click: { click(item) },
                    toggleSelection: { toggleSelection(item.id) },
                    useOnAllDisplays: model.screens.count > 1 ? { model.setWallpaperOnAllDisplays(item.id) } : nil,
                    showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) },
                    remove: { remove([item.id]) })
    }

    private var emptyState: some View {
        WMEmptyState(icon: "play.rectangle.on.rectangle",
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
            Text("Try another search.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Removing and adding

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

    private func remove(_ ids: Set<VideoItem.ID>) {
        guard !ids.isEmpty else { return }
        if model.videos.contains(where: { ids.contains($0.id) && $0.isWorkshop }) {
            pendingRemoval = ids
        } else {
            model.remove(ids: ids)
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
        let names = model.videos.filter { pendingRemoval.contains($0.id) }.map(\.name)
        return names.count == 1 ? "Remove “\(names[0])” and delete its downloaded files?"
                                : "Remove \(names.count) wallpapers and delete the downloaded files of Workshop items?"
    }
}

// MARK: - Cards

/// How a library card looks.
struct CardState: Equatable {
    /// The selected display shows this wallpaper.
    var current: Bool
    /// Show in Library pointed here a moment ago.
    var highlighted: Bool
    var selectionMode: Bool
    var selected: Bool

    var ringColor: Color {
        if selected || current { return .accentColor }
        return highlighted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.07)
    }

    var ringWidth: CGFloat { selected || current ? 2.5 : (highlighted ? 2 : 1) }
}

/// What a library card can do.
struct CardActions {
    /// Puts the wallpaper on the selected display, or selects it while selecting.
    let click: () -> Void
    let toggleSelection: () -> Void
    /// nil with a single display.
    let useOnAllDisplays: (() -> Void)?
    let showInFinder: () -> Void
    let remove: () -> Void
}

/// The menu of a library card (its context menu and the … button).
@MainActor
private struct CardMenu: View {
    let actions: CardActions

    var body: some View {
        if let useOnAllDisplays = actions.useOnAllDisplays {
            Button("Use on All Displays", action: useOnAllDisplays)
        }
        Button("Show in Finder", action: actions.showInFinder)
        Divider()
        Button("Remove…", role: .destructive, action: actions.remove)
    }
}

@MainActor
private struct LibraryCard: View {
    let item: VideoItem
    let broken: Bool
    let state: CardState
    let actions: CardActions
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
                        if let info = item.scene { SceneSupportBadge(info: info) }
                    }
                    .padding(7)

                    if hovering && !state.selectionMode {
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
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(state.ringColor, lineWidth: state.ringWidth)
                }
                .shadow(color: .black.opacity(hovering || state.current ? 0.20 : 0), radius: 16, y: 8)
                .animation(WMMotion.hover, value: state)

                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(broken ? 0.6 : 1)
                Text(cardMeta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: actions.click)

            if state.selectionMode {
                selectionBadge
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .onHover { inside in
            withAnimation(WMMotion.hover) { hovering = inside }
        }
        .contextMenu { CardMenu(actions: actions) }
        .help(broken ? String(localized: "This file was moved, deleted, or can’t be played.") : item.name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(cardMeta)")
        .accessibilityAddTraits(state.current || state.selected ? .isSelected : [])
    }

    private var selectionBadge: some View {
        Button(action: actions.toggleSelection) {
            Image(systemName: state.selected ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(state.selected ? Color.white : Color.white.opacity(0.95),
                                 state.selected ? Color.accentColor : Color.white.opacity(0.55))
                .font(.system(size: 16, weight: .semibold))
                .padding(3)
                .background(Circle().fill(Color.black.opacity(0.36)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(state.selected ? "Deselect" : "Select")
        .accessibilityLabel(state.selected ? "Deselect wallpaper" : "Select wallpaper")
    }

    private var cardMeta: String {
        if broken { return String(localized: "Missing or unreadable") }
        if item.isWorkshop { return String(localized: "Workshop") }
        return item.isScene ? String(localized: "Scene") : String(localized: "Video")
    }
}

@MainActor
private struct LibraryListRow: View {
    let item: VideoItem
    let broken: Bool
    let state: CardState
    let actions: CardActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if state.selectionMode {
                Button(action: actions.toggleSelection) {
                    Image(systemName: state.selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(state.selected ? Color.accentColor : Color.secondary.opacity(0.55))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .help(state.selected ? "Deselect" : "Select")
                .accessibilityLabel(state.selected ? "Deselect wallpaper" : "Select wallpaper")
            }

            HStack(spacing: 12) {
                ItemThumbnail(item: item, broken: broken, cornerRadius: 8)
                    .frame(width: 96, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if let info = item.scene { SceneSupportBadge(info: info) }
                }
                Spacer(minLength: 8)
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(state.current || state.selected ? Color.accentColor.opacity(0.12)
                                                      : (hovering ? Color.primary.opacity(0.045) : .clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state.current || state.selected || state.highlighted ? state.ringColor.opacity(0.5)
                                                                                    : .clear,
                              lineWidth: 1)
        }
        .onHover { inside in withAnimation(WMMotion.hover) { hovering = inside } }
        .contextMenu { CardMenu(actions: actions) }
        .accessibilityAddTraits(state.current || state.selected ? .isSelected : [])
    }
}

// MARK: - Inspector

/// The selected display's wallpaper and that display's settings.
@MainActor
struct DisplayInspectorView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            if let screen = model.selectedScreen {
                content(screen)
                    .id(screen.id)  // a display's own state (the interval being typed) never carries over
                    .transition(.opacity)
            }
        }
        .scrollIndicators(.visible)
        .animation(WMMotion.content, value: model.selectedDisplayID)
    }

    private func content(_ screen: ScreenInfo) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.wallpaper(on: screen.id) != nil, let item = model.shownItem(on: screen.id) {
                header(item, on: screen)
                if let error = model.error(on: screen.id) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WallpaperSettingsCard(model: model, display: screen.id, item: item)
                DisplaySettingsCard(model: model, display: screen.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "display").font(.system(size: 22, weight: .light))
                    Text(screen.name).font(.callout.weight(.medium))
                    Text("This display has no live wallpaper. Click one in your library to use it here.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
        }
        .padding(18)
        // The panel starts at the window's top edge, in the toolbar strip (see `wmInspectorPanel`).
        .padding(.top, 22)
    }

    private func header(_ item: VideoItem, on screen: ScreenInfo) -> some View {
        HStack(spacing: 11) {
            // ItemThumbnail takes the size of its scaled-to-fill image, so a frame alone does not bound it (a square
            // preview would spill over the rows below). It is laid over a fixed square and clipped to it instead, which
            // keeps the header the same height for every wallpaper.
            Color.clear
                .frame(width: 76, height: 76)
                .overlay {
                    ItemThumbnail(item: item, broken: !FileManager.default.fileExists(atPath: item.path),
                                  cornerRadius: 8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                Text(item.isScene ? "Scene · \(screen.name)" : "Video · \(screen.name)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Badges

@MainActor
struct SceneSupportBadge: View {
    let info: SceneInfo

    private var title: String {
        switch info.support {
        case .full: return String(localized: "Scene")
        case .partial: return String(localized: "Partial")
        case .previewOnly: return String(localized: "Preview")
        }
    }

    private var tint: Color { info.support == .previewOnly ? .orange : .secondary }

    var body: some View {
        WMChip(text: title, tint: tint, icon: "sparkles")
            .help(info.localizedNotes.joined(separator: "\n"))
    }
}

// MARK: - Display settings

/// Rotation and scene settings of one display.
@MainActor
struct DisplaySettingsCard: View {
    @ObservedObject var model: SettingsModel
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection(title: "Rotation", subtitle: "Runs on a playlist you curate in Playlists.") {
                RotationBlock(model: model, display: display)
            }

            Divider()

            InspectorSection(title: "Energy") {
                ScenePowerRows(model: model, display: display)
            }
        }
    }
}

@MainActor
struct RotationBlock: View {
    @ObservedObject var model: SettingsModel
    let display: String
    @State private var intervalText: String
    @FocusState private var intervalFocused: Bool

    init(model: SettingsModel, display: String) {
        self._model = ObservedObject(wrappedValue: model)
        self.display = display
        self._intervalText = State(initialValue: String(model.config(for: display).intervalValue))
    }

    private var config: DisplayConfig { model.config(for: display) }
    private var hasPlaylist: Bool { model.playlistIDs != nil }
    private var canRotate: Bool { hasPlaylist && model.canRotate }
    private var itemCount: Int { model.playlistItems.count }
    private var enteredValue: Int? { Int(intervalText).flatMap { $0 > 0 ? min($0, 999) : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            WMSwitchRow("Rotate wallpaper", isOn: rotateBinding)
                .disabled(!canRotate)
                .help("Automatically switch this display between the wallpapers of your playlist, in playlist order.")
            if config.rotateEnabled && canRotate { intervalRow }
            if let helper {
                Text(helper.text)
                    .font(.caption)
                    .foregroundStyle(helper.warning ? Color.orange : Color.secondary)
            }
        }
        .animation(WMMotion.panel, value: config.rotateEnabled && canRotate)
        .onChange(of: config.intervalValue) { _, value in intervalText = String(value) }
    }

    private var intervalRow: some View {
        HStack(spacing: 8) {
            Text("Every").font(.callout)
            TextField(text: $intervalText) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($intervalFocused)
                .onSubmit(commitInterval)
                .onChange(of: intervalFocused) { _, focused in if !focused { commitInterval() } }
                .accessibilityLabel("Interval value")
            Picker("Interval unit", selection: unitBinding) {
                Text("seconds").tag(IntervalUnit.seconds)
                Text("minutes").tag(IntervalUnit.minutes)
                Text("hours").tag(IntervalUnit.hours)
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 104)
        }
    }

    private var helper: (text: LocalizedStringKey, warning: Bool)? {
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
                set: { on in model.updateDisplay(display) { $0.rotateEnabled = on } })
    }

    private var unitBinding: Binding<IntervalUnit> {
        Binding(get: { config.intervalUnit },
                set: { unit in model.updateDisplay(display) { $0.intervalUnit = unit } })
    }

    private func commitInterval() {
        if let value = enteredValue { model.updateDisplay(display) { $0.intervalValue = value } }
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
        .accessibilityLabel(item.map { Text("Preview of \($0.name)") } ?? Text("No wallpaper selected"))
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
            ForEach(Array(info.localizedNotes.enumerated()), id: \.offset) { entry in
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
