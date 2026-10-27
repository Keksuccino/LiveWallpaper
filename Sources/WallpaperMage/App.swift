import SwiftUI
import AppKit
import Combine
import Core

// The Settings app: a normal Dock app with one window. It plays nothing; the wallpaper agent (nested helper
// app) does. Closing the window quits this app and the agent keeps running, except while a Workshop download
// is active. There is no menu bar extra here; the agent owns the status item.

@main
struct WallpaperMageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SettingsModel.shared
    @StateObject private var workshop = WorkshopModel.shared

    var body: some Scene {
        Window(AppIdentity.name, id: "main") {
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

    /// The app is always dark, whatever the Mac's appearance: the theme (WMTheme) is made for it. Set before the first
    /// window opens, and for the whole app, so menus, sheets and alerts are dark too.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if yieldToRunningSettings() { return }
        OutsideClickEditing.install()
        WorkshopModel.shared.connect(
            onImport: { SettingsModel.shared.addImported($0) },
            isInLibrary: { SettingsModel.shared.hasWorkshopItem($0) })
        SettingsModel.shared.bootstrap()
        AppLanguage.shareWithService()
        if CommandLine.arguments.contains(AppLanguage.reopenSettingsArgument) { SettingsNavigator.shared.open(.general) }
        // The menu bar item's Quit. Delivered at once: an inactive app would otherwise only get it when activated.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(quitRequested),
                                                            name: AppIdentity.quitRequest, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
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

    /// Quitting leaves an open playlist editor too: like every way out of it, it undoes the edit, after asking when
    /// there is something to undo, and the app quits once the undone playlist has reached the service.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = SettingsModel.shared
        guard model.editingPlaylistID != nil else { return .terminateNow }
        NSApp.activate()
        NSApp.windows.filter(\.isMiniaturized).forEach { $0.deminiaturize(nil) }
        model.leaveEditor(then: {
            Task { @MainActor in
                await model.commitsSettled()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }, otherwise: {
            NSApp.reply(toApplicationShouldTerminate: false)
        })
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkshopModel.shared.cancelAll()
        SteamSetupModel.shared.cancelSignIn()   // never leave a steamcmd sign-in waiting on a prompt
        SteamSetupModel.shared.cancelInstall()
        SettingsModel.shared.shutdown()
    }

    @objc private func quitRequested() {
        SettingsNavigator.shared.quitApp()
    }

    /// A second copy hands over to the first (lowest process id wins, as with the agent) and quits.
    private func yieldToRunningSettings() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let first = SettingsModel.otherInstances().min(by: { $0.processIdentifier < $1.processIdentifier }),
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
    case home, workshop, downloads

    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .workshop: return String(localized: "Workshop")
        case .downloads: return String(localized: "Downloads")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
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
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 208, ideal: WMTheme.sidebarWidth, max: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        // The playlist editor is left through Done or Cancel (or another page, which asks too); closing the window
        // would quit the app with the alert that asks about the edit nowhere to show.
        .windowDismissBehavior(model.editingPlaylistID == nil ? .automatic : .disabled)
        .frame(minWidth: 980, minHeight: 640)
        .containerBackground(WMTheme.background, for: .window)
        .sheet(isPresented: $settings.isPresented, onDismiss: settings.didClose) {
            AppSettingsView(model: model, workshop: workshop)
        }
        // After the sheet, so Settings gets the theme's control tint too.
        .tint(WMTheme.controlTint)
    }

    // MARK: Sidebar

    // The footer sits below the list, not in its safe-area inset: over the list's scroll view its buttons get no
    // hover and no tooltips.
    // The rows are buttons that draw the selection themselves: a List's own selection always takes the system accent
    // colour, which no tint reaches. The arrow keys move it while the sidebar has focus, as in a native sidebar.
    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                sidebarRow(.home)
                sidebarRow(.workshop)
                sidebarRow(.downloads, count: workshop.downloadEntries.isEmpty ? nil : workshop.downloadEntries.count,
                           live: workshop.hasActiveDownloads)
            }
            .listStyle(.sidebar)
            .focusable()
            .focused($sidebarFocused)
            .focusEffectDisabled()
            .onMoveCommand(perform: moveSelection)
            SidebarFooter(model: model)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    private func sidebarRow(_ item: SidebarSelection, count: Int? = nil, live: Bool = false) -> some View {
        let selected = selection == item
        return Button {
            select(item)
            sidebarFocused = true
        } label: {
            HStack(spacing: 0) {
                Label(item.title, systemImage: item.symbol)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 4)
                if live {
                    StatusDot(color: WMTheme.accent, pulsing: true)
                        .padding(.trailing, 5)
                        .help("Downloads in progress")
                        .accessibilityLabel("Downloads in progress")
                } else if let count, count > 0 {
                    Text(count, format: .number)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listItemTint(.monochrome)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? WMTheme.selectionFill : .clear)
                .padding(.horizontal, 10)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let all = SidebarSelection.allCases
        guard let index = all.firstIndex(of: selection) else { return }
        switch direction {
        case .up where index > 0: select(all[index - 1])
        case .down where index < all.count - 1: select(all[index + 1])
        default: break
        }
    }

    /// Shows a page. Any page, Home included, leaves an open playlist editor, which undoes the edit (asking first when
    /// there is something to undo).
    private func select(_ item: SidebarSelection) {
        model.leaveEditor { selection = item }
    }

    // MARK: Detail

    // Pages switch without a transition: toolbar items a page adds would fade with it, and AppKit can leave them half
    // transparent, looking disabled, until the pointer passes over them.
    // No page shows the toolbar's background: side panels (Home's inspector, the Workshop's detail pane) reach up into
    // the toolbar strip, where it would blur them. Page headers are pinned above what scrolls; the playlist editor's
    // page fades out under the strip.
    private var detail: some View {
        content
            .background(WMBackground())
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .home:
            Group {
                if let id = model.editingPlaylistID, model.playlist(id) != nil {
                    PlaylistEditorView(model: model, playlistID: id)
                        .id(id)  // another playlist's editor starts afresh
                } else {
                    HomeView(model: model, openWorkshop: { selection = .workshop })
                        .wmInspectorPanel {
                            DisplayInspectorView(model: model)
                        }
                }
            }
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
        .animation(WMMotion.content, value: warning?.title)
        .animation(WMMotion.content, value: model.client.isRestarting)
    }

    /// What is wrong, in the user's words, and what fixes it. Nothing while a restart is under way.
    private var warning: Warning? {
        guard !model.client.isRestarting else { return nil }
        let restart = Image(systemName: "arrow.clockwise")
        switch model.client.problem {
        case .missing:
            return Warning(title: String(localized: "Wallpaper service missing"),
                           message: Text("This copy of Wallpaper Mage is incomplete, so your live wallpapers can’t be shown. Reinstall Wallpaper Mage to fix it."))
        case .didNotStart:
            return Warning(title: String(localized: "Wallpaper service didn’t start"),
                           message: Text("Your live wallpapers can’t be shown right now. Press \(restart) below to try again. If that doesn’t help, reinstall Wallpaper Mage."))
        case .noAnswer:
            return Warning(title: String(localized: "Wallpaper service not responding"),
                           message: Text("Your live wallpapers may have stopped, and changes you make here can’t reach them. Press \(restart) below to fix it."))
        case nil:
            break
        }
        guard model.client.state == .connected, let message = model.statusMessage, !message.isEmpty else { return nil }
        return Warning(title: String(localized: "Wallpaper service problem"), message: Text(message),
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
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        configuration.label
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(isEnabled ? Color.primary.opacity(0.8) : Color.secondary)
            .frame(width: 36, height: 36)
            .background(shape.fill(Color.primary.opacity(highlight)))
            .contentShape(shape)
            .onHover { inside in withAnimation(WMMotion.hover) { hovering = inside } }
    }

    private var highlight: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.16 }
        return hovering ? 0.08 : 0
    }
}
