import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers
import Core

// The Library tab (SPEC3.md 6.2): the list with role and scene badges, the "Set as" actions, the preview pane,
// the per-target rotation settings and Start/Stop. Driven by SettingsModel and the agent's status.
@MainActor
struct LibraryView: View {
    @ObservedObject var model: SettingsModel
    let openWorkshop: () -> Void
    let openSteamSetup: () -> Void
    @State private var isTargeted = false
    @State private var skippedCount = 0
    @State private var showSkipped = false
    @State private var pendingRemoval: Set<VideoItem.ID> = []   // Workshop items awaiting the delete confirmation

    init(model: SettingsModel, openWorkshop: @escaping () -> Void = {}, openSteamSetup: @escaping () -> Void = {}) {
        self._model = ObservedObject(wrappedValue: model)
        self.openWorkshop = openWorkshop
        self.openSteamSetup = openSteamSetup
    }

    var body: some View {
        Group {
            if model.videos.isEmpty { emptyState } else { HStack(spacing: 0) { sidebar; Divider(); detail } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { isTargeted = $0 }
        .alert(skippedTitle, isPresented: $showSkipped) { Button("OK", role: .cancel) {} }
    }

    private var focused: VideoItem? { model.videos.first { $0.id == model.focusedID } ?? model.selectedItem }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 56))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text(isTargeted ? "Release to add" : "Drop videos here").font(.title2.weight(.semibold))
            Text("or choose files from your Mac. MP4, MOV and M4V work best.").font(.callout).foregroundStyle(.secondary)
            Button("Choose Videos…", action: chooseVideos).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("o")
            Button("Browse the Steam Workshop", action: openWorkshop).buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary))
        .background(Color.accentColor.opacity(isTargeted ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
            isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
            style: StrokeStyle(lineWidth: isTargeted ? 3 : 2, dash: isTargeted ? [] : [8, 6])))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: chooseVideos)
        .padding(32)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let state = model.snapshot
        return VStack(spacing: 0) {
            List(model.videos, selection: $model.focusedID) { item in row(item, state) }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onDeleteCommand(perform: removeFocused)
                .contextMenu(forSelectionType: VideoItem.ID.self) { ids in
                    contextItems(ids)
                } primaryAction: { ids in
                    if let id = ids.first { model.play(id) }   // double click: Set as Both and play
                }
            Divider()
            footer
        }
        .frame(width: 296)
        .background(.regularMaterial)
        .alert(removalTitle, isPresented: confirmingRemoval) {
            Button("Remove", role: .destructive) { finishRemoval() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can download it again from the Workshop.")
        }
    }

    private func row(_ item: VideoItem, _ state: LibraryState) -> some View {
        LibraryRow(item: item, broken: isBroken(item), roles: state.targets(of: item.id),
                   playing: playingTargets(of: item), isPaused: model.isPaused, render: renderStatus(of: item),
                   assign: { model.assign(item.id, to: $0) })
    }

    @ViewBuilder private func contextItems(_ ids: Set<VideoItem.ID>) -> some View {
        if ids.count == 1, let id = ids.first {
            SetAsItems(roles: model.roles(of: id), assign: { model.assign(id, to: $0) })
            Divider()
        }
        if !ids.isEmpty { Button("Remove") { remove(ids) } }
    }

    private var footer: some View {
        HStack {
            Button(action: chooseVideos) { Label("Add Videos…", systemImage: "plus") }
                .keyboardShortcut("o").help("Add videos (⌘O)")
            Button(action: removeFocused) { Image(systemName: "minus") }
                .keyboardShortcut(.delete, modifiers: .command).disabled(focused == nil)
                .help("Remove selected wallpaper (⌘⌫)").accessibilityLabel("Remove selected wallpaper")
            Spacer()
            Text(model.videos.count == 1 ? "1 item" : "\(model.videos.count) items").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(spacing: 16) {
                    ItemPreviewPane(item: focused, broken: focused.map { isBroken($0) } ?? false, openSteamSetup: openSteamSetup)
                    selectionBar
                    if let item = focused, item.isScene { SceneSettingsCard(model: model, item: item) }
                    LibrarySettingsCard(model: model)
                }
            }
            actionBar
        }
        .padding(24)
    }

    @ViewBuilder private var selectionBar: some View {
        if let item = focused {
            HStack(spacing: 8) {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu("Set as") {
                    SetAsItems(roles: model.roles(of: item.id), isScene: item.isScene,
                               assign: { model.assign(item.id, to: $0) })
                }
                .fixedSize()
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            statusLine
            Spacer()
            Button {
                model.clearStatus()
                model.toggleRunning()
            } label: {
                Label(model.isRunning ? "Stop Wallpaper" : "Start Wallpaper", systemImage: model.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(model.isRunning ? Color.red : nil)
            .frame(width: 168)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.isRunning && !model.canStart)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Text(status.text).font(.subheadline).foregroundStyle(status.warning ? Color.orange : Color.secondary)
                .lineLimit(1).truncationMode(.middle)
            if model.client.state == .unavailable {
                Button("Retry") { model.startService() }.buttonStyle(.link).font(.subheadline)
            }
        }
    }

    private var status: (text: String, warning: Bool) {
        if let message = model.localMessage { return (message, true) }
        if model.client.state == .connecting { return ("Starting the wallpaper service…", false) }
        if model.client.state == .needsApproval { return ("Allow the wallpaper service in Login Items.", true) }
        if model.client.state == .unavailable { return (model.client.connectionError ?? "The wallpaper service isn’t responding.", true) }
        if let message = model.statusMessage { return (message, true) }
        if model.isRunning { return (runningSummary, false) }
        if !model.canStart { return ("Turn on Desktop or Lock Screen to start.", true) }
        if model.videos.allSatisfy({ isBroken($0) }) { return ("None of your wallpapers can be played.", true) }
        return ("Stopped", false)
    }

    // "Playing “X”" while both targets share a wallpaper, else "Desktop: … · Lock Screen: …".
    private var runningSummary: String {
        let state = model.snapshot
        if state.sameForBoth {
            let desktop = playbackText(.desktop)
            let lock = lockRenderText(state).map { "Lock Screen: " + $0 }
            return [desktop, lock].compactMap { $0 }.joined(separator: " · ")
        }
        return WallpaperTarget.allCases.map { "\($0.label): \(targetText($0, state))" }.joined(separator: " · ")
    }

    private func targetText(_ target: WallpaperTarget, _ state: LibraryState) -> String {
        guard state.isEnabled(target) else { return "Off" }
        if target == .lock, let rendering = lockRenderText(state) { return rendering }
        return playbackText(target)
    }

    private func playbackText(_ target: WallpaperTarget) -> String {
        let id = model.currentID(for: target)
        let name = model.videos.first { $0.id == id }.map { "“\($0.name)”" } ?? ""
        return model.isPaused ? "Paused · \(name)" : "Playing \(name)"
    }

    // The lock screen part of the summary while a scene is being rendered (or a video converted).
    private func lockRenderText(_ state: LibraryState) -> String? {
        guard state.isEnabled(.lock) else { return nil }
        if let render = model.lockRender, render.state == .rendering || render.state == .queued {
            return "Rendering \(Int((min(max(render.progress, 0), 1) * 100).rounded()))%…"
        }
        return model.lockBusy ? "Preparing…" : nil
    }

    // MARK: Per-item state

    private func playingTargets(of item: VideoItem) -> Set<WallpaperTarget> {
        guard model.isRunning else { return [] }
        return Set(WallpaperTarget.allCases.filter { model.currentID(for: $0) == item.id })
    }

    private func renderStatus(of item: VideoItem) -> LockRenderStatus? {
        guard let render = model.lockRender, render.itemID == item.id, render.state != .finished else { return nil }
        return render
    }

    private var skippedTitle: String {
        skippedCount == 1 ? "Skipped 1 file that isn’t a video." : "Skipped \(skippedCount) files that aren’t videos."
    }

    private func isBroken(_ item: VideoItem) -> Bool {
        model.failedIDs.contains(item.id) || !FileManager.default.fileExists(atPath: item.path)
    }

    private func add(_ urls: [URL]) {
        skippedCount = urls.filter { !VideoItem.isVideo($0) }.count
        showSkipped = skippedCount > 0
        model.addVideos(urls: urls)
    }

    private func chooseVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie]
        panel.message = "Choose videos to use as your wallpaper."
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func removeFocused() { if let id = focused?.id { remove([id]) } }

    // Local videos are removed at once (the file is never touched); Workshop items ask first because their
    // downloaded files are deleted.
    private func remove(_ ids: Set<VideoItem.ID>) {
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

    private var removalTitle: String {
        let names = model.videos.filter { pendingRemoval.contains($0.id) }.map(\.name)
        return names.count == 1 ? "Remove “\(names[0])” and delete its downloaded files?"
                                : "Remove \(names.count) wallpapers and delete the downloaded files of Workshop items?"
    }
}

// MARK: - Set as

/// "Set as Desktop / Lock Screen / Both"; the check mark shows the current role.
@MainActor
fileprivate struct SetAsItems: View {
    let roles: Set<WallpaperTarget>
    /// Scenes are live-rendered, so they can only be the desktop wallpaper; the lock screen needs a video.
    var isScene = false
    let assign: (Set<WallpaperTarget>) -> Void

    var body: some View {
        entry("Set as Desktop", [.desktop], checked: roles.contains(.desktop), enabled: true)
        entry("Set as Lock Screen", [.lock], checked: roles.contains(.lock), enabled: !isScene)
        entry("Set as Both", [.desktop, .lock], checked: roles.count == WallpaperTarget.allCases.count, enabled: !isScene)
        if isScene {
            Divider()
            Text("Scenes can’t be used on the lock screen.\nUse a video for it.")
        }
    }

    @ViewBuilder private func entry(_ title: String, _ targets: Set<WallpaperTarget>, checked: Bool, enabled: Bool) -> some View {
        Button { assign(targets) } label: {
            if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .disabled(!enabled)
    }
}

// MARK: - Rows and badges

fileprivate let thumbnailCache = NSCache<NSString, NSImage>()

@MainActor
fileprivate struct LibraryRow: View {
    let item: VideoItem
    let broken: Bool
    let roles: Set<WallpaperTarget>
    let playing: Set<WallpaperTarget>
    let isPaused: Bool
    let render: LockRenderStatus?
    let assign: (Set<WallpaperTarget>) -> Void
    @State private var image: NSImage?
    @State private var meta = ""

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle).opacity(broken ? 0.6 : 1)
                subtitle
                badges
            }
            Spacer(minLength: 0)
            if !playing.isEmpty { Image(systemName: isPaused ? "pause.fill" : "play.fill").foregroundStyle(.tint).opacity(isPaused ? 0.5 : 1) }
            setAsMenu
        }
        .frame(minHeight: 52)
        .help(broken ? "This file was moved, deleted, or can’t be played. Remove it or add it again." : "")
        .task(id: [item.path, item.previewPath ?? ""]) {
            let bytes = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            meta = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            image = await Self.loadThumbnail(for: item)
        }
    }

    @ViewBuilder private var subtitle: some View {
        if broken {
            Text("Missing or unreadable").font(.caption).foregroundStyle(.orange)
        } else if let render {
            LockRenderLine(status: render)
        } else {
            metaLine
        }
    }

    // Workshop items carry a download badge and "Workshop · size".
    private var metaLine: some View {
        HStack(spacing: 4) {
            if item.isWorkshop { Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary) }
            Text(item.isWorkshop ? "Workshop · \(meta)" : meta).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var badges: some View {
        if !roles.isEmpty || item.scene != nil {
            HStack(spacing: 4) {
                ForEach(WallpaperTarget.allCases) { target in
                    if roles.contains(target) { RoleBadge(title: target.label, filled: playing.contains(target)) }
                }
                if let info = item.scene { SceneSupportBadge(info: info) }
            }
        }
    }

    private var setAsMenu: some View {
        Menu {
            SetAsItems(roles: roles, isScene: item.isScene, assign: assign)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(item.isScene ? "Set as Desktop (scenes can’t be used on the lock screen)"
                           : "Set as Desktop, Lock Screen or Both")
        .accessibilityLabel("Set as")
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if broken {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.isScene ? "photo" : "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // A Workshop item's downloaded preview image when it has one, else a frame of the video (never for scenes).
    private static func loadThumbnail(for item: VideoItem) async -> NSImage? {
        let key = (item.previewPath ?? item.path) as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let image: NSImage
        if let preview = item.previewPath, let downloaded = NSImage(contentsOfFile: preview) {
            image = downloaded
        } else if !item.isScene, let cgImage = await VideoStills.cgImage(for: item.url, maxPixelSize: CGSize(width: 320, height: 180)) {
            image = NSImage(cgImage: cgImage, size: .zero)
        } else {
            return nil
        }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }
}

/// Capsule saying which target an item is set for: filled while the agent shows it there, outlined otherwise.
@MainActor
fileprivate struct RoleBadge: View {
    let title: String
    let filled: Bool

    var body: some View {
        Text(title).font(.caption2.weight(.medium))
            .foregroundStyle(filled ? Color.white : Color.accentColor)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(filled ? Color.accentColor : Color.clear))
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1))
    }
}

/// `Scene`, `Scene · Partial` or `Scene · Preview only`; the help text lists what is not supported.
@MainActor
struct SceneSupportBadge: View {
    let info: SceneInfo

    private var title: String {
        switch info.support {
        case .full: return "Scene"
        case .partial: return "Scene · Partial"
        case .previewOnly: return "Scene · Preview only"
        }
    }

    var body: some View {
        Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.2)))
            .help(info.notes.joined(separator: "\n"))
    }
}

/// The subtitle of a scene that is being turned into a lock screen video.
@MainActor
fileprivate struct LockRenderLine: View {
    let status: LockRenderStatus

    var body: some View {
        switch status.state {
        case .rendering:
            VStack(alignment: .leading, spacing: 2) {
                Text("Rendering for lock screen… \(Int((min(max(status.progress, 0), 1) * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(max(status.progress, 0), 1)).controlSize(.small)
            }
        case .queued:
            Text("Waiting to render for lock screen…").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text("Couldn’t render this for the lock screen.").font(.caption).foregroundStyle(.orange)
                .help(status.message ?? "")
        case .finished:
            EmptyView()
        }
    }
}

// MARK: - Settings card

/// Same-for-both switch, the rotation settings per target, and mute.
@MainActor
fileprivate struct LibrarySettingsCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.selectedItem?.isScene == true {
                Label("Scenes can’t be used on the lock screen. Use a video for it.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
            }
            if model.sameForBoth {
                RotationBlock(model: model, target: .desktop, title: nil)
            } else {
                if model.applyToDesktop { RotationBlock(model: model, target: .desktop, title: "Desktop") }
                if model.applyToDesktop && model.applyToLockScreen { Divider().padding(.vertical, 4) }
                if model.applyToLockScreen { RotationBlock(model: model, target: .lock, title: "Lock Screen") }
            }
            Divider().padding(.vertical, 4)
            HStack {
                Text("Scene frame rate")
                Spacer()
                Picker("Scene frame rate", selection: $model.sceneFPS) {
                    ForEach([20, 24, 30, 45, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            .help("Smoothness of scene wallpapers. Higher looks smoother but keeps the GPU busier, which can make the whole Mac lag. Videos play at their own frame rate. On battery it is limited to 24.")
            Divider().padding(.vertical, 4)
            ScenePowerRows(model: model)
            Divider().padding(.vertical, 4)
            Toggle("Mute sound", isOn: $model.muted)
                .help("Videos play silently. The lock screen never has sound.")
            lockNote
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
        .animation(.default, value: model.sameForBoth)
    }

    private var lockNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Lock Screen plays your wallpaper through an Apple Aerial wallpaper (macOS 26+; older versions get a still frame). Download and select any Aerial in Wallpaper settings once, and turn on “Show as screen saver” there so an automatic lock uses it too.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            Link("Open Wallpaper Settings", destination: URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                .font(.caption)
        }
    }
}

/// One target's switch, rotation toggle, interval and "Playing now" line. The desktop block edits the desktop
/// config (which the lock screen follows while "same for both" is on); the lock block edits `lockConfig`.
@MainActor
fileprivate struct RotationBlock: View {
    @ObservedObject var model: SettingsModel
    let target: WallpaperTarget
    let title: String?
    @State private var intervalText: String
    @FocusState private var intervalFocused: Bool

    init(model: SettingsModel, target: WallpaperTarget, title: String?) {
        self._model = ObservedObject(wrappedValue: model)
        self.target = target
        self.title = title
        self._intervalText = State(initialValue: String(model.snapshot.config(for: target).intervalValue))
    }

    private var config: TargetConfig { model.snapshot.config(for: target) }
    private var canRotate: Bool { model.snapshot.hasMultipleItems(target) }
    private var itemCount: Int { model.snapshot.items(for: target).count }
    private var enteredValue: Int? { Int(intervalText).flatMap { $0 > 0 ? min($0, 999) : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            HStack {
                Text("Rotate wallpaper")
                Spacer()
                Toggle("Rotate wallpaper", isOn: rotateBinding).labelsHidden().toggleStyle(.switch)
            }
            .disabled(!canRotate)
            .help("Automatically switch between your wallpapers, in list order.")
            if config.rotateEnabled && canRotate { intervalRow }
            if let helper { Text(helper.text).font(.caption).foregroundStyle(helper.warning ? Color.orange : Color.secondary) }
            if title != nil, let name = playingName {
                Text("Playing now: “\(name)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .animation(.default, value: config.rotateEnabled && canRotate)
        .onChange(of: config.intervalValue) { intervalText = String($0) }
    }

    private var intervalRow: some View {
        HStack(spacing: 8) {
            Text("Every")
            TextField("", text: $intervalText)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 56)
                .focused($intervalFocused)
                .onSubmit(commitInterval)
                .onChange(of: intervalFocused) { if !$0 { commitInterval() } }
                .accessibilityLabel("Interval value")
            Picker("Interval unit", selection: unitBinding) {
                ForEach(IntervalUnit.allCases) { Text($0.label.lowercased()).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 104)
        }
        .help("How long each wallpaper plays before the next one. Minimum 5 seconds.")
    }

    private var helper: (text: String, warning: Bool)? {
        guard canRotate else { return ("Add at least two wallpapers to rotate.", false) }
        guard config.rotateEnabled else { return nil }
        if enteredValue == nil { return ("Enter a number from 1 to 999.", true) }
        if config.intervalIsClamped { return ("Minimum is 5 seconds.", true) }
        return ("Cycles through \(itemCount) wallpapers in list order.", false)
    }

    private var playingName: String? {
        guard model.isRunning, let id = model.currentID(for: target) else { return nil }
        return model.videos.first { $0.id == id }?.name
    }

    private var rotateBinding: Binding<Bool> {
        Binding(get: { config.rotateEnabled && canRotate },
                set: { if target == .desktop { model.rotateEnabled = $0 } else { model.lockConfig.rotateEnabled = $0 } })
    }

    private var unitBinding: Binding<IntervalUnit> {
        Binding(get: { config.intervalUnit },
                set: { if target == .desktop { model.intervalUnit = $0 } else { model.lockConfig.intervalUnit = $0 } })
    }

    private func commitInterval() {
        if let value = enteredValue {
            if target == .desktop { model.intervalValue = value } else { model.lockConfig.intervalValue = value }
        }
        intervalText = String(config.intervalValue)
    }
}

// MARK: - Preview pane

@MainActor
fileprivate final class PreviewPlayer: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var url: URL?
    private var isActive = true

    func load(_ url: URL?) {
        guard url != self.url else { return }
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

fileprivate struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

/// The preview of a library item: a muted looping video (the only playback in this process), or a scene's preview
/// image with its support badge, the notes and a link to the shared files when the scene needs them.
@MainActor
struct ItemPreviewPane: View {
    let item: VideoItem?
    let broken: Bool
    let openSteamSetup: () -> Void
    @StateObject private var preview = PreviewPlayer()
    @State private var sceneImage: NSImage?

    init(item: VideoItem?, broken: Bool, openSteamSetup: @escaping () -> Void) {
        self.item = item
        self.broken = broken
        self.openSteamSetup = openSteamSetup
    }

    private var playbackURL: URL? { broken || item?.isScene == true ? nil : item?.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            stage
            if let info = item?.scene { SceneNotes(info: info, openSteamSetup: openSteamSetup) }
        }
    }

    private var stage: some View {
        ZStack {
            Color.black
            stageContent
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxHeight: 340)
        .overlay(alignment: .topLeading) {
            if let info = item?.scene { SceneSupportBadge(info: info).padding(8) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: playbackURL) { preview.load(playbackURL) }
        .task(id: item?.previewPath) { sceneImage = item?.previewPath.flatMap { NSImage(contentsOfFile: $0) } }
        .onAppear { preview.setActive(true) }
        .onDisappear { preview.setActive(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let window = note.object as? NSWindow, window.styleMask.contains(.titled) {
                preview.setActive(window.occlusionState.contains(.visible))
            }
        }
    }

    @ViewBuilder private var stageContent: some View {
        if broken {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(.orange)
                Text(item?.isScene == true ? "Can’t show this wallpaper" : "Can’t play this video").font(.headline)
                Text("The file may have been moved or deleted.").font(.callout).foregroundStyle(.secondary)
            }
            .environment(\.colorScheme, .dark)
        } else if let item {
            if item.isScene {
                if sceneImage != nil {
                    AnimatedImageView(image: sceneImage).accessibilityLabel("Preview of \(item.name)")
                } else {
                    Image(systemName: "photo").font(.system(size: 32)).foregroundStyle(.secondary)
                }
            } else {
                PlayerSurface(player: preview.player).accessibilityLabel("Video preview of \(item.name), muted, looping")
            }
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
