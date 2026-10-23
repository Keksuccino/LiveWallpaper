import SwiftUI
import AppKit
import Combine
import Core

// The Settings app: a normal Dock app with one window. It plays nothing; the wallpaper agent (nested helper
// app) does. Closing the window quits this app and the agent keeps running, except while a Workshop download
// is active. There is no menu bar extra here; the agent owns the status item.

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SettingsModel.shared
    @StateObject private var workshop = WorkshopModel.shared

    var body: some Scene {
        Window("Live Wallpaper", id: "main") {
            RootView(model: model, workshop: workshop)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize) // the content's minimum frame is the window minimum
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: model) }

        Settings {
            PlaybackSettingsView(model: model)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var downloadWatch: AnyCancellable?
    private var lingering = false   // the last window closed while a download was still running

    func applicationDidFinishLaunching(_ notification: Notification) {
        if yieldToRunningSettings() { return }
        WorkshopModel.shared.connect(
            onImport: { SettingsModel.shared.addImported($0) },
            isInLibrary: { SettingsModel.shared.hasWorkshopItem($0) })
        SettingsModel.shared.bootstrap()
        // `$downloads` fires before the value changes; the hop reads the settled state.
        downloadWatch = WorkshopModel.shared.$downloads.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.quitWhenDownloadsEnd() }
        }
    }

    // Closing the window quits Settings; the wallpaper service is a separate process and keeps playing.
    // While a Workshop download runs, Settings stays alive without a window and quits when the queue is empty.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lingering = WorkshopModel.shared.hasActiveDownloads
        return !lingering
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkshopModel.shared.cancelAll()
        SteamSetupModel.shared.cancelSignIn()   // never leave a steamcmd sign-in waiting on a prompt
        SteamSetupModel.shared.cancelInstall()
        SettingsModel.shared.shutdown()
    }

    /// A second copy hands over to the first (lowest process id wins, as with the agent) and quits.
    private func yieldToRunningSettings() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let peers = SettingsModel.otherInstances().filter { !$0.legacy }.map { $0.app }
        guard let first = peers.min(by: { $0.processIdentifier < $1.processIdentifier }),
              first.processIdentifier < me else { return false }
        first.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    private func quitWhenDownloadsEnd() {
        let hasWindow = NSApp.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled) }
        if lingering, !WorkshopModel.shared.hasActiveDownloads, !hasWindow { NSApp.terminate(nil) }
    }
}

// MARK: - Navigation

enum SidebarSelection: Hashable {
    case all, desktop, lockScreen, scenes, workshop, steamSetup

    var isLibrary: Bool {
        switch self {
        case .all, .desktop, .lockScreen, .scenes: return true
        default: return false
        }
    }

    var libraryFilter: LibraryFilter {
        switch self {
        case .desktop: return .desktop
        case .lockScreen: return .lock
        case .scenes: return .scenes
        default: return .all
        }
    }

    var title: String {
        switch self {
        case .all: return "All Wallpapers"
        case .desktop: return "Desktop"
        case .lockScreen: return "Lock Screen"
        case .scenes: return "Scenes"
        case .workshop: return "Workshop"
        case .steamSetup: return "Steam Setup"
        }
    }
}

/// Window content: native sidebar, gallery, inspector and a toolbar status pill.
@MainActor
struct RootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    @State private var selection: SidebarSelection = .all
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 196, ideal: LWTheme.sidebarWidth, max: 280)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 960, minHeight: 620)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                sidebarRow(.all, icon: "rectangle.on.rectangle", count: model.videos.count)
                sidebarRow(.desktop, icon: "display", count: count(for: .desktop))
                sidebarRow(.lockScreen, icon: "lock.display", count: count(for: .lock))
                sidebarRow(.scenes, icon: "sparkles.rectangle.stack", count: model.videos.filter(\.isScene).count)
            }
            Section("Discover") {
                sidebarRow(.workshop, icon: "square.grid.2x2", count: workshop.results.isEmpty ? nil : workshop.results.count)
                sidebarRow(.steamSetup, icon: "key.horizontal", count: nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            ServiceFooter(model: model)
                .padding(10)
        }
    }

    private func sidebarRow(_ item: SidebarSelection, icon: String, count: Int?) -> some View {
        HStack(spacing: 8) {
            Label(item.title, systemImage: icon)
            Spacer(minLength: 6)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .tag(item)
    }

    private func count(for target: WallpaperTarget) -> Int {
        let state = model.snapshot
        return model.videos.filter { !state.targets(of: $0.id).isEmpty && state.targets(of: $0.id).contains(target) }.count
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            if let banner = banner {
                BannerBar(banner: banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
                .transition(.opacity)
        }
        .animation(LWMotion.content, value: selection)
        .animation(LWMotion.content, value: banner?.text)
        .toolbar {
            if selection.isLibrary {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(LWMotion.panel) { showInspector.toggle() }
                    } label: {
                        Image(systemName: showInspector ? "sidebar.right" : "sidebar.right")
                    }
                    .help(showInspector ? "Hide Inspector" : "Show Inspector")
                    .accessibilityLabel(showInspector ? "Hide Inspector" : "Show Inspector")
                    .keyboardShortcut("i", modifiers: [.command, .option])
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ServiceStatusPill(model: model)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .all, .desktop, .lockScreen, .scenes:
            LibraryView(model: model,
                        filter: selection.libraryFilter,
                        showInspector: $showInspector,
                        openWorkshop: { selection = .workshop },
                        openSteamSetup: { selection = .steamSetup })
                .lwInspector(isPresented: $showInspector) {
                    LibraryInspectorView(model: model,
                                         item: focusedLibraryItem,
                                         openSteamSetup: { selection = .steamSetup },
                                         remove: removeFocused)
                }
        case .workshop:
            WorkshopView(model: model, workshop: workshop,
                         openSteamSetup: { selection = .steamSetup },
                         openLibrary: { selection = .all })
        case .steamSetup:
            SteamSetupView(workshop: workshop, setup: SteamSetupModel.shared)
        }
    }

    private var focusedLibraryItem: VideoItem? {
        let state = model.snapshot
        let visible = model.videos.filter {
            selection.libraryFilter.includes($0, targets: state.targets(of: $0.id))
        }
        return visible.first { $0.id == model.focusedID } ?? visible.first
    }

    private func removeFocused() {
        guard let id = focusedLibraryItem?.id else { return }
        model.remove(ids: [id])
    }

    /// One banner at a time, in priority order.
    private var banner: Banner? {
        if model.legacyAppRunning {
            return Banner(text: "An older copy of Live Wallpaper is still running. Quit it so the two don’t fight over your wallpaper.")
        }
        if model.importedFromPhase1 > 0 {
            let count = model.importedFromPhase1
            return Banner(text: "Imported \(count) \(count == 1 ? "video" : "videos") from the previous version.",
                          warning: false, dismiss: { model.dismissImportNotice() })
        }
        return nil
    }
}

fileprivate struct Banner {
    let text: String
    var warning = true
    var action: (title: String, run: () -> Void)? = nil
    var dismiss: (() -> Void)? = nil
}

@MainActor
fileprivate struct BannerBar: View {
    let banner: Banner

    private var tint: Color { banner.warning ? .orange : .accentColor }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(tint)
            Text(banner.text)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let action = banner.action {
                Button(action.title, action: action.run).buttonStyle(.link)
            }
            if let dismiss = banner.dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.25), lineWidth: 1)
                }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }
}

// MARK: - Service status

@MainActor
private struct ServiceFooter: View {
    @ObservedObject var model: SettingsModel
    @State private var showingMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                StatusDot(color: dot, pulsing: model.client.state == .connecting)
                Text(shortText)
                    .font(.caption)
                    .foregroundStyle(model.client.state == .connected ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("Connect to Service") { model.startService() }
                        .disabled(model.client.state == .connected)
                    Button("Restart Service") { model.restartService() }
                        .disabled(model.client.state != .connected)
                    Button("Quit Service") { model.quitService() }
                        .disabled(model.client.state != .connected)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Service options")
                .accessibilityLabel("Service options")
            }
            HStack(spacing: 6) {
                Button(model.isRunning ? "Stop" : "Start") {
                    model.clearStatus()
                    if model.isRunning { model.stop() } else { model.start() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.isRunning && !model.canStart)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
        }
    }

    private var dot: Color {
        switch model.client.state {
        case .connected: return model.isRunning ? .green : .secondary
        case .connecting: return .orange
        case .needsApproval, .unavailable: return .orange
        case .unknown: return .secondary
        }
    }

    private var shortText: String {
        switch model.client.state {
        case .connected: return model.isRunning ? "Wallpaper service · running" : "Wallpaper service · ready"
        case .connecting: return "Starting service…"
        case .needsApproval: return "Service needs approval"
        case .unavailable: return "Service not responding"
        case .unknown: return "Service not running"
        }
    }
}

@MainActor
struct ServiceStatusPill: View {
    @ObservedObject var model: SettingsModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                StatusDot(color: dot, pulsing: model.client.state == .connecting)
                Text(pillText)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(Color.primary.opacity(0.055))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .help("Wallpaper service status and controls")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ServicePopover(model: model)
                .frame(width: 320)
        }
    }

    private var dot: Color {
        switch model.client.state {
        case .connected: return model.isRunning ? .green : .secondary
        case .connecting: return .orange
        case .needsApproval, .unavailable: return .orange
        case .unknown: return .secondary
        }
    }

    private var pillText: String {
        if model.client.state == .connecting { return "Starting…" }
        if model.client.state == .unavailable { return "Service offline" }
        if model.client.state == .needsApproval { return "Needs approval" }
        if model.isRunning { return model.isPaused ? "Paused" : "Live" }
        return "Ready"
    }
}

@MainActor
private struct ServicePopover: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Wallpaper Service").font(.headline)
                Spacer()
                StatusDot(color: model.client.state == .connected ? .green : .orange)
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                targetRow(.desktop)
                Divider()
                targetRow(.lock)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }

            HStack(spacing: 8) {
                Button(model.isRunning ? "Stop Wallpaper" : "Start Wallpaper") {
                    model.clearStatus()
                    model.isRunning ? model.stop() : model.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isRunning && !model.canStart)

                Toggle("Mute", isOn: $model.muted)
                    .toggleStyle(.checkbox)
                Spacer()
            }

            if let message = model.statusMessage, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }

            HStack(spacing: 10) {
                if model.client.state == .unavailable {
                    Button("Reconnect") { model.startService() }.buttonStyle(.link)
                }
                Button("Restart") { model.restartService() }.buttonStyle(.link)
                    .disabled(model.client.state != .connected)
                Button("Quit") { model.quitService() }.buttonStyle(.link)
                    .disabled(model.client.state != .connected)
            }
            .font(.caption)
        }
        .padding(16)
    }

    private var stateText: String {
        switch model.client.state {
        case .connected: return model.isRunning ? "running" : "ready"
        case .connecting: return "starting"
        case .needsApproval: return "needs approval"
        case .unavailable: return "offline"
        case .unknown: return "not running"
        }
    }

    private func targetRow(_ target: WallpaperTarget) -> some View {
        let id = model.currentID(for: target)
        let item = model.videos.first { $0.id == id }
        return HStack(spacing: 9) {
            Image(systemName: target == .desktop ? "display" : "lock.display")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.label).font(.caption).foregroundStyle(.secondary)
                Text(item?.name ?? "Off")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            ActivityBars(playing: id != nil && model.isRunning, paused: model.isPaused)
        }
    }
}
