import SwiftUI
import AppKit
import Core
import UniformTypeIdentifiers

// The playlist editor, shown on Home in place of the library while SettingsModel.playlistEdit is set: the playlist's
// name, picture, timing and transition, and its wallpapers in order. The inspector beside it holds the settings of the
// wallpaper selected in the list, which belong to the playlist (Playlist.wallpaperOptions). Every edit is committed at
// once through SettingsModel, so a display that plays the playlist follows it live; Done keeps the edit, Cancel and
// every other way out undo it (SettingsModel.leaveEditor), after the question this view shows.

@MainActor
struct PlaylistEditorView: View {
    @ObservedObject var model: SettingsModel
    let playlistID: Playlist.ID
    /// The wallpaper whose settings the inspector shows.
    @State private var selectedItemID: VideoItem.ID?
    @State private var confirmingDelete = false

    var body: some View {
        if let playlist = model.playlist(playlistID) {
            page(playlist)
                .wmInspectorPanel {
                    PlaylistItemInspector(model: model, playlist: playlist, itemID: selectedItemID)
                }
                .alert(leaveTitle(playlist), isPresented: leaving) {
                    Button(isNew ? "Discard Playlist" : "Discard Changes", role: .destructive) {
                        model.answerLeaveRequest(discard: true)
                    }
                    Button("Keep Editing", role: .cancel) { model.answerLeaveRequest(discard: false) }
                } message: {
                    Text(isNew ? "The new playlist is deleted. Its wallpapers stay in your library."
                               : "The playlist goes back to how it was when you started editing it.")
                }
        }
    }

    private var isNew: Bool { model.playlistEdit?.isNew ?? false }

    private func leaveTitle(_ playlist: Playlist) -> LocalizedStringKey {
        isNew ? "Discard the new playlist “\(playlist.name)”?" : "Discard your changes to “\(playlist.name)”?"
    }

    /// Shown while a way out of the editor waits for an answer. Only the buttons answer it, so the setter does nothing.
    private var leaving: Binding<Bool> {
        Binding(get: { model.leaveRequest != nil }, set: { _ in })
    }

    private func page(_ playlist: Playlist) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WMTheme.sectionSpacing) {
                WMPageHeader(title: "Edit Playlist") {
                    HStack(spacing: 8) {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                        Button("Cancel") { model.leaveEditor(then: {}) }
                            .keyboardShortcut(.cancelAction)
                            .help("Undo every change since you opened this playlist and go back to your library.")
                        Button("Done") { model.finishEditing() }
                            .buttonStyle(.borderedProminent)
                            .help("Keep your changes and go back to your library.")
                    }
                }
                PlaylistDetailsCard(model: model, playlist: playlist)
                PlaylistItemsCard(model: model, playlist: playlist, selection: $selectedItemID)
            }
            .padding([.horizontal, .bottom], WMTheme.contentPadding)
            .padding(.top, WMTheme.pageTopPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .alert("Delete the playlist “\(playlist.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.deletePlaylist(playlist.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its wallpapers stay in your library.")
        }
    }
}

/// The words for a playlist's settings, shared by the editor and the Home inspector.
enum PlaylistText {
    static func name(of transition: PlaylistTransition) -> String {
        switch transition {
        case .cut: return String(localized: "Hard switch")
        case .fade: return String(localized: "Fade")
        case .fadeThroughBlack: return String(localized: "Fade through black")
        case .blur: return String(localized: "Blur")
        case .zoom: return String(localized: "Zoom")
        case .slide: return String(localized: "Slide")
        }
    }

    /// How long a transition takes, e.g. "0.5 s".
    static func transitionLength(_ seconds: Double) -> String {
        String(localized: "\(seconds.formatted(.number.precision(.fractionLength(0...2)))) s")
    }
}

// MARK: - Details

/// Name, picture, timing and transition.
@MainActor
private struct PlaylistDetailsCard: View {
    @ObservedObject var model: SettingsModel
    let playlist: Playlist
    // The two fields commit as they are typed in; an empty name or an invalid interval waits for a valid one.
    @State private var name: String
    @State private var intervalText: String
    @State private var imageFailed = false

    init(model: SettingsModel, playlist: Playlist) {
        self._model = ObservedObject(wrappedValue: model)
        self.playlist = playlist
        self._name = State(initialValue: playlist.name)
        self._intervalText = State(initialValue: String(playlist.intervalValue))
    }

    private var enteredInterval: Int? { Int(intervalText).flatMap { $0 > 0 ? min($0, 999) : nil } }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(spacing: 10) {
                PlaylistArtwork(playlist: playlist, items: model.items(of: playlist), cornerRadius: 12)
                    .frame(width: 240, height: 135)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                HStack(spacing: 8) {
                    Button("Choose Picture", action: chooseImage)
                        .help("Use a picture of your own for this playlist.")
                    if playlist.image != nil {
                        Button("Use Previews") { model.clearPlaylistImage(playlist.id) }
                            .help("Show the previews of the playlist’s first wallpapers instead of your picture.")
                    }
                }
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField(text: $name) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .accessibilityLabel("Name")
                }
                Divider()
                WMSettingRow(title: "Show each wallpaper for") {
                    HStack(spacing: 6) {
                        TextField(text: $intervalText) { EmptyView() }
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            .accessibilityLabel("Interval value")
                        Picker("Interval unit", selection: binding(\.intervalUnit)) {
                            Text("seconds").tag(IntervalUnit.seconds)
                            Text("minutes").tag(IntervalUnit.minutes)
                            Text("hours").tag(IntervalUnit.hours)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 104)
                    }
                }
                WMSettingRow(title: "Transition", help: "How the next wallpaper replaces the one on screen.") {
                    Picker("Transition", selection: binding(\.transition)) {
                        ForEach(PlaylistTransition.allCases, id: \.self) {
                            Text(PlaylistText.name(of: $0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if playlist.transition != .cut {
                    WMSettingRow(title: "Transition length") {
                        HStack(spacing: 8) {
                            Slider(value: durationBinding, in: Playlist.transitionDurations)
                                .controlSize(.small)
                                .frame(width: 150)
                                .accessibilityLabel("Transition length")
                            Text(PlaylistText.transitionLength(playlist.transitionDuration))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .transition(.opacity)
                }
                if let warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
        .wmGlassCard(padding: 18)
        .animation(WMMotion.panel, value: playlist.transition == .cut)
        .alert("This file can’t be used as a picture.", isPresented: $imageFailed) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: name) { _, typed in commitName(typed) }
        .onChange(of: intervalText) { commitInterval() }
        .onChange(of: playlist.intervalValue) { _, stored in
            if enteredInterval != stored { intervalText = String(stored) }
        }
    }

    private var warning: LocalizedStringKey? {
        if enteredInterval == nil { return "Enter a number from 1 to 999." }
        if playlist.intervalIsClamped { return "Minimum is 5 seconds." }
        return nil
    }

    private func binding<T>(_ path: WritableKeyPath<Playlist, T>) -> Binding<T> {
        Binding(get: { playlist[keyPath: path] },
                set: { value in model.updatePlaylist(playlist.id) { $0[keyPath: path] = value } })
    }

    /// Quarter seconds.
    private var durationBinding: Binding<Double> {
        Binding(get: { playlist.transitionDuration },
                set: { value in model.updatePlaylist(playlist.id) { $0.transitionDuration = (value * 4).rounded() / 4 } })
    }

    /// An empty name keeps the old one.
    private func commitName(_ typed: String) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.name else { return }
        model.updatePlaylist(playlist.id) { $0.name = trimmed }
    }

    private func commitInterval() {
        guard let value = enteredInterval, value != playlist.intervalValue else { return }
        model.updatePlaylist(playlist.id) { $0.intervalValue = value }
    }

    private func chooseImage() {
        guard let url = PlaylistImagePicker.choose() else { return }
        Task { @MainActor in
            if !(await model.setPlaylistImage(playlist.id, from: url)) { imageFailed = true }
        }
    }
}

// MARK: - Wallpapers

/// The playlist's wallpapers in order: drag to reorder, click one to edit its settings in the inspector.
@MainActor
private struct PlaylistItemsCard: View {
    @ObservedObject var model: SettingsModel
    let playlist: Playlist
    @Binding var selection: VideoItem.ID?
    @State private var addSheet = false
    @State private var dragID: UUID?
    @State private var ids: [UUID] = []  // live order while dragging, committed on drop

    var body: some View {
        let library = Dictionary(model.videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let count = playlist.items.filter { library[$0] != nil }.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Wallpapers")
                    .font(.title3.weight(.semibold))
                Text(count, format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button { addSheet = true } label: {
                    Label("Add Wallpapers", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if count == 0 {
                emptyRow
            } else {
                rows(library)
                Text("Drag wallpapers to change their order. Click one to change how it looks and sounds in this playlist.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .wmGlassCard(padding: 18)
        .sheet(isPresented: $addSheet) {
            PlaylistAddSheet(model: model, excluded: Set(playlist.items)) { added in
                model.addToPlaylist(playlist.id, items: added)
                if selection == nil { selection = added.first }
            }
        }
        .onAppear {
            ids = playlist.items
            if selection == nil { selection = playlist.items.first }
        }
        .onChange(of: playlist.items) { _, items in
            ids = items
            if let selected = selection, !items.contains(selected) { selection = items.first }
        }
    }

    private func rows(_ library: [UUID: VideoItem]) -> some View {
        let shown = ids.compactMap { library[$0] }
        return VStack(spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                row(item, at: index)
                    .onDrag {
                        dragID = item.id
                        return NSItemProvider(object: item.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: dropDelegate(target: item.id))
            }
        }
        // Between rows the list itself takes the drop, so the dragged row never slides back as if refused.
        .onDrop(of: [.text], delegate: dropDelegate(target: nil))
        .animation(.easeOut(duration: 0.2), value: ids)
    }

    private func dropDelegate(target: UUID?) -> PlaylistDropDelegate {
        PlaylistDropDelegate(targetID: target, ids: $ids, dragID: $dragID) { order in
            model.updatePlaylist(playlist.id) { $0.items = order }
        }
    }

    private func row(_ item: VideoItem, at index: Int) -> some View {
        let selected = selection == item.id
        return HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            ItemThumbnail(item: item, broken: !FileManager.default.fileExists(atPath: item.path), cornerRadius: 6)
                .frame(width: 72, height: 41)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ItemKindChip(item: item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            Button {
                model.updatePlaylist(playlist.id) { $0.items.removeAll { $0 == item.id } }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from playlist")
            .accessibilityLabel("Remove \(item.name) from playlist")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? WMTheme.accent.opacity(0.14) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? WMTheme.accent.opacity(0.5) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(WMMotion.select) { selection = item.id } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Text("This playlist is empty — add some wallpapers.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
    }
}

/// Moves the dragged row as the pointer crosses other rows and commits each new order at once: a drop is not reported
/// when the pointer is let go outside the list, so waiting for it could lose the order.
private struct PlaylistDropDelegate: DropDelegate {
    /// The row under the pointer; nil for the list around the rows.
    let targetID: UUID?
    @Binding var ids: [UUID]
    @Binding var dragID: UUID?
    let commit: ([UUID]) -> Void

    func dropEntered(info: DropInfo) {
        guard let targetID, let dragged = dragID, dragged != targetID,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: targetID) else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        commit(ids)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragID = nil
        return true
    }
}

// MARK: - Inspector

/// The settings of the wallpaper selected in the editor, as the playlist plays it.
@MainActor
private struct PlaylistItemInspector: View {
    @ObservedObject var model: SettingsModel
    let playlist: Playlist
    let itemID: VideoItem.ID?

    private var item: VideoItem? {
        guard let itemID, playlist.items.contains(itemID) else { return nil }
        return model.videos.first { $0.id == itemID }
    }

    var body: some View {
        ScrollView {
            Group {
                if let item {
                    VStack(alignment: .leading, spacing: 20) {
                        InspectorHeader(title: item.name,
                                        steamPage: item.workshopID.flatMap(WorkshopItem.pageURL(id:))) {
                            ItemThumbnail(item: item, broken: !FileManager.default.fileExists(atPath: item.path),
                                          cornerRadius: 8)
                        }
                        WallpaperInfoSection(item: item)
                        WallpaperSettingsCard(model: model, scope: .playlist(playlist.id), item: item)
                    }
                    .id(item.id)  // folded groups and dialogs of one wallpaper never carry over
                    .transition(.opacity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 22, weight: .light))
                        Text("Select a wallpaper in the playlist to change how it looks and sounds there.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(18)
            // The panel starts at the window's top edge (see `wmInspectorPanel`).
            .padding(.top, WMTheme.toolbarStripPadding)
        }
        .scrollIndicators(.visible)
        .animation(WMMotion.content, value: itemID)
    }
}

/// A wallpaper's type as a chip: Scene or Video.
private struct ItemKindChip: View {
    let item: VideoItem

    var body: some View {
        if item.isScene {
            WMChip(text: String(localized: "Scene"), icon: "sparkles")
        } else {
            WMChip(text: String(localized: "Video"))
        }
    }
}

// MARK: - Add sheet

/// Picks wallpapers of the library to add to a playlist.
@MainActor
private struct PlaylistAddSheet: View {
    @ObservedObject var model: SettingsModel
    /// Already in the playlist: not offered.
    let excluded: Set<VideoItem.ID>
    let onAdd: ([UUID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selected: Set<UUID> = []

    private var candidates: [VideoItem] {
        model.videos
            .filter { !excluded.contains($0.id) }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add to Playlist")
                    .font(.headline)
                WMSearchField(prompt: "Search your library", text: $searchText)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    if candidates.isEmpty {
                        Text(searchText.isEmpty
                             ? "Every wallpaper in your library is already in this playlist."
                             : "Nothing in your library matches “\(searchText)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                    ForEach(candidates) { item in
                        candidateRow(item)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.visible)

            Divider()

            HStack(spacing: 12) {
                if !selected.isEmpty {
                    Text("\(selected.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Add Wallpapers" : "Add \(selected.count) Wallpapers") {
                    // Library order, so the appended order is stable.
                    onAdd(model.videos.filter { selected.contains($0.id) }.map(\.id))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 500, height: 540)
        .background(WMBackground())
    }

    private func candidateRow(_ item: VideoItem) -> some View {
        let isSelected = selected.contains(item.id)
        return Button {
            if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? WMTheme.accent : Color.secondary.opacity(0.5))
                    .frame(width: 18)
                ItemThumbnail(item: item, broken: !FileManager.default.fileExists(atPath: item.path), cornerRadius: 5)
                    .frame(width: 64, height: 36)
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                ItemKindChip(item: item)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
