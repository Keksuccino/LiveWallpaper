import SwiftUI
import AppKit
import Core
import UniformTypeIdentifiers

// The Playlists page: the ordered list of wallpapers a rotating display cycles. Rotation itself is turned on per
// display in the Home inspector. The storage is LibraryState.playlist in state.json (nil = no playlist); every edit
// goes through SettingsModel.setPlaylist, so the service stays the only writer.

@MainActor
struct PlaylistView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LWTheme.sectionSpacing) {
                LWPageHeader(title: "Playlists",
                             subtitle: "Choose the wallpapers that rotate, and in what order.")
                VStack(alignment: .leading, spacing: 18) {
                    PlaylistEditorCard(model: model)
                    rotationCard
                }
            }
            .padding(LWTheme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .background(LWBackground())
    }

    /// Where rotation is turned on.
    private var rotationCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(model.playlistIDs == nil
                 ? "Start a playlist above to rotate wallpapers."
                 : "To rotate, select a display in Home and turn on Rotate wallpaper in its settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
    }
}

// MARK: - Editor card

@MainActor
private struct PlaylistEditorCard: View {
    @ObservedObject var model: SettingsModel
    @State private var addSheet = false
    @State private var dragID: UUID?
    @State private var ids: [UUID] = []          // live copy, committed on drop

    private var storedIDs: [UUID]? { model.playlistIDs }
    private var isCustom: Bool { storedIDs != nil }
    private var items: [VideoItem] { model.playlistItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playlist")
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Custom order", isOn: customBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Choose wallpapers and the order they rotate in.")
                if isCustom {
                    Button { addSheet = true } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            }

            if isCustom {
                if items.isEmpty { emptyRow } else { rows }
            } else {
                Text("Start a playlist and add wallpapers to rotate them in your own order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
        .sheet(isPresented: $addSheet) {
            PlaylistAddSheet(model: model) { added in
                model.setPlaylist((storedIDs ?? []) + added)
            }
        }
        .onAppear { ids = storedIDs ?? [] }
        .onChange(of: storedIDs ?? []) { _, stored in ids = stored }
        .animation(LWMotion.content, value: isCustom)
    }

    private var subtitle: String {
        guard isCustom else { return "No playlist yet" }
        let count = items.count
        return count == 0 ? "Empty" : "\(count) \(count == 1 ? "wallpaper" : "wallpapers") · drag to reorder"
    }

    /// Turning custom order on starts from the whole library, in library order.
    private var customBinding: Binding<Bool> {
        Binding(
            get: { isCustom },
            set: { on in
                model.setPlaylist(on ? model.videos.map(\.id) : nil)
            })
    }

    // MARK Rows

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if let item = model.videos.first(where: { $0.id == id }) {
                    row(item, at: index)
                        .onDrag {
                            dragID = id
                            return NSItemProvider(object: id.uuidString as NSString)
                        }
                        .onDrop(of: [.text],
                                delegate: PlaylistDropDelegate(targetID: id, ids: $ids, dragID: $dragID) {
                                    model.setPlaylist($0)
                                })
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: ids)
    }

    private func row(_ item: VideoItem, at index: Int) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            ItemThumbnail(item: item,
                          broken: !FileManager.default.fileExists(atPath: item.path), cornerRadius: 6)
                .frame(width: 72, height: 41)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let info = item.scene {
                    SceneSupportBadge(info: info)
                } else {
                    LWChip(text: "Video")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            Button {
                model.setPlaylist(ids.filter { $0 != item.id })
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
                .fill(dragID == item.id ? Color.primary.opacity(0.07) : .clear)
        }
        .opacity(dragID == item.id ? 0.65 : 1)
    }

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Text("This playlist is empty — add some wallpapers.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Add Wallpapers…") { addSheet = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.22),
                              style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
    }
}

/// Moves the dragged row as the pointer crosses other rows; commits the new order once, on drop.
private struct PlaylistDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var ids: [UUID]
    @Binding var dragID: UUID?
    let commit: ([UUID]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = dragID, dragged != targetID,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: targetID) else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let settled = ids
        dragID = nil
        commit(settled)
        return true
    }
}

// MARK: - Add sheet

@MainActor
private struct PlaylistAddSheet: View {
    @ObservedObject var model: SettingsModel
    let onAdd: ([UUID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selected: Set<UUID> = []

    private var inPlaylist: Set<UUID> { Set(model.playlistIDs ?? []) }

    private var candidates: [VideoItem] {
        model.videos
            .filter { !inPlaylist.contains($0.id) }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add to Playlist")
                    .font(.headline)
                LWSearchField(prompt: "Search your library", text: $searchText)
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
                Text(selected.isEmpty ? "" : "\(selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(selected.isEmpty ? "" : "\(selected.count) ")Wallpaper\(selected.count == 1 ? "" : "s")") {
                    // Library order, so the appended order is stable.
                    let ordered = model.videos.filter { selected.contains($0.id) }.map(\.id)
                    onAdd(ordered)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 500, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func candidateRow(_ item: VideoItem) -> some View {
        let isSelected = selected.contains(item.id)
        return Button {
            if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 18)
                ItemThumbnail(item: item,
                              broken: !FileManager.default.fileExists(atPath: item.path), cornerRadius: 5)
                    .frame(width: 64, height: 36)
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let info = item.scene {
                    SceneSupportBadge(info: info)
                } else {
                    LWChip(text: "Video")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
