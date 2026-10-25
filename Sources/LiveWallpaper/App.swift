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
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize) // the content's minimum frame is the window minimum
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: model) }
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

enum SidebarSelection: Hashable, CaseIterable {
    case home, playlists, workshop, downloads

    var title: String {
        switch self {
        case .home: return "Home"
        case .playlists: return "Playlists"
        case .workshop: return "Workshop"
        case .downloads: return "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .playlists: return "list.bullet.rectangle"
        case .workshop: return "square.grid.2x2"
        case .downloads: return "arrow.down.circle"
        }
    }
}

/// Window content: native sidebar, gallery and inspector.
@MainActor
struct RootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    @ObservedObject private var settings = SettingsNavigator.shared
    @State private var selection: SidebarSelection = .home

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 208, ideal: LWTheme.sidebarWidth, max: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 640)
        .sheet(isPresented: $settings.isPresented) {
            AppSettingsView(model: model, workshop: workshop)
        }
    }

    // MARK: Sidebar

    // The footer sits below the list, not in its safe-area inset: over the list's scroll view its buttons get no
    // hover and no tooltips.
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                sidebarRow(.home)
                sidebarRow(.playlists)
                sidebarRow(.workshop)
                sidebarRow(.downloads, count: workshop.downloadEntries.isEmpty ? nil : workshop.downloadEntries.count,
                           live: workshop.hasActiveDownloads)
            }
            .listStyle(.sidebar)
            SidebarFooter(model: model)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    private func sidebarRow(_ item: SidebarSelection, count: Int? = nil, live: Bool = false) -> some View {
        HStack(spacing: 0) {
            Label(item.title, systemImage: item.symbol)
                .font(.callout.weight(.medium))
            Spacer(minLength: 4)
            if live {
                ProgressRing(progress: workshop.overallDownloadProgress ?? 0,
                             size: 16, lineWidth: 2)
                    .opacity(workshop.overallDownloadProgress == nil ? 0.4 : 1)
            } else if let count, count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
        .padding(.vertical, 1)
        .tag(item)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            if let banner = banner {
                BannerBar(banner: banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Pages switch without a transition: a page's toolbar items (Home's) would fade with it, and AppKit
            // can leave them half transparent, looking disabled, until the pointer passes over them.
            content
        }
        .background(LWBackground())
        .animation(LWMotion.content, value: banner?.text)
        .toolbar {
            if workshop.hasActiveDownloads {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        selection = .downloads
                    } label: {
                        HStack(spacing: 6) {
                            ProgressRing(progress: workshop.overallDownloadProgress ?? 0,
                                         size: 16, lineWidth: 2)
                                .opacity(workshop.overallDownloadProgress == nil ? 0.4 : 1)
                            Text("\(workshop.activeDownloadCount)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            Capsule()
                                .fill(.regularMaterial)
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Downloads in progress")
                    .accessibilityLabel("Downloads in progress")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .home:
            HomeView(model: model, openWorkshop: { selection = .workshop })
                .lwInspectorPanel {
                    DisplayInspectorView(model: model)
                }
        case .playlists:
            PlaylistView(model: model)
        case .workshop:
            WorkshopView(model: model, workshop: workshop,
                         openSteamSetup: openSteamSettings,
                         openLibrary: { selection = .home },
                         openDownloads: { selection = .downloads })
        case .downloads:
            DownloadsView(model: model, workshop: workshop,
                          openLibrary: { selection = .home },
                          openWorkshop: { selection = .workshop })
        }
    }

    private func openSteamSettings() {
        SettingsNavigator.shared.open(.steam)
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

/// The bottom of the sidebar: restart the wallpaper service on the left, open Settings on the right, and above them a
/// warning while the service is not running or reports a problem.
@MainActor
private struct SidebarFooter: View {
    @ObservedObject var model: SettingsModel

    private struct Warning {
        let title: String
        let message: Text
        /// Set for a message the user can close; problems of the service itself go away when it answers again.
        var dismiss: (() -> Void)? = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning {
                warningCard(warning)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack {
                Button { model.restartService() } label: {
                    if model.client.isRestarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.client.isRestarting)
                .help("Restart the wallpaper service")
                .accessibilityLabel("Restart the wallpaper service")
                Spacer()
                Button { SettingsNavigator.shared.open() } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .buttonStyle(SidebarIconButtonStyle())
        }
        .animation(LWMotion.content, value: warning?.title)
        .animation(LWMotion.content, value: model.client.isRestarting)
    }

    /// What is wrong, in the user's words, and what fixes it. Nothing while a restart is under way.
    private var warning: Warning? {
        guard !model.client.isRestarting else { return nil }
        let restart = Image(systemName: "arrow.clockwise")
        switch model.client.problem {
        case .missing:
            return Warning(title: "Wallpaper service missing",
                           message: Text("This copy of Live Wallpaper is incomplete, so your live wallpapers can’t be shown. Reinstall Live Wallpaper to fix it."))
        case .didNotStart:
            return Warning(title: "Wallpaper service didn’t start",
                           message: Text("Your live wallpapers can’t be shown right now. Press \(restart) below to try again. If that doesn’t help, reinstall Live Wallpaper."))
        case .noAnswer:
            return Warning(title: "Wallpaper service not responding",
                           message: Text("Your live wallpapers may have stopped, and changes you make here can’t reach them. Press \(restart) below to fix it."))
        case nil:
            break
        }
        guard model.client.state == .connected, let message = model.statusMessage, !message.isEmpty else { return nil }
        return Warning(title: "Wallpaper service problem", message: Text(message),
                       dismiss: model.localMessage == nil ? nil : { model.clearStatus() })
    }

    private func warningCard(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(warning.title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if let dismiss = warning.dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .font(.caption2.weight(.semibold))
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss")
                }
            }
            warning.message
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        // The window's minimum size is worked out from its content: without a minimum width the wrapped text would
        // be measured one word per line, and the window would demand a height no screen has.
        .frame(minWidth: 188, maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
    }

}

/// An icon button without a border that still looks and feels pressable: a soft highlight under the pointer and a
/// stronger one while pressed.
private struct SidebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarIconButton(configuration: configuration)
    }
}

private struct SidebarIconButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isEnabled ? Color.primary.opacity(0.8) : Color.secondary)
            .frame(width: 28, height: 28)
            .background(shape.fill(Color.primary.opacity(highlight)))
            .contentShape(shape)
            .onHover { inside in withAnimation(LWMotion.hover) { hovering = inside } }
    }

    private var highlight: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.16 }
        return hovering ? 0.08 : 0
    }
}
