import SwiftUI
import AppKit
import Core

enum SettingsTab: Hashable {
    case general, steam, about
}

/// Opens Settings at a tab from anywhere in the app (the sidebar's ⚙, ⌘, and the Workshop's "Open Steam Settings").
@MainActor final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    @Published var tab: SettingsTab = .general
    /// Settings is shown as a sheet on the main window (RootView).
    @Published var isPresented = false

    /// Set while Settings closes on the way to quitting the app.
    private var quitsWhenClosed = false

    /// Opens Settings at `tab`, or at the tab it showed last. An open playlist editor is left first, which undoes the
    /// edit (asking when there is something to undo).
    func open(_ tab: SettingsTab? = nil) {
        SettingsModel.shared.leaveEditor { [weak self] in
            if let tab { self?.tab = tab }
            self?.isPresented = true
        }
    }

    /// Quits the app, closing Settings first: macOS refuses to quit an app while it shows a sheet.
    func quitApp() {
        guard isPresented else { return NSApp.terminate(nil) }
        quitsWhenClosed = true
        isPresented = false
    }

    /// Called by the sheet once Settings has closed.
    func didClose() {
        if quitsWhenClosed { NSApp.terminate(nil) }
    }
}

/// Settings about the app as a whole, as a sheet on the main window: it opens centred on the window and keeps it
/// blocked until it is closed. Everything about a display's wallpaper lives in the Home inspector
/// (DisplayInspectorView).
@MainActor
struct AppSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    @ObservedObject private var navigator = SettingsNavigator.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $navigator.tab) {
                Text("General").tag(SettingsTab.general)
                Text("Steam").tag(SettingsTab.steam)
                Text("About").tag(SettingsTab.about)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 14)

            Divider()

            Group {
                switch navigator.tab {
                case .general:
                    ScrollView { GeneralSettingsView(model: model, workshop: workshop) }
                case .steam:
                    SteamSetupView(workshop: workshop, setup: SteamSetupModel.shared)
                case .about:
                    AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            // Not the default button: Return belongs to the text fields of the Steam sign-in. Escape closes too.
            HStack {
                Spacer()
                Button("Done") { navigator.isPresented = false }
                    .controlSize(.large)
            }
            .padding(14)
        }
        .frame(width: 660, height: 640)
        .background(WMBackground())
        .onExitCommand { navigator.isPresented = false }
    }
}

@MainActor
private struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    let workshop: WorkshopModel
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            startup
            languageSection
            sound
            lockScreen
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Start on Launch can change in System Settings while the app is open.
        .onAppear { model.refreshStartsAtLogin() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshStartsAtLogin()
        }
    }

    private var startup: some View {
        InspectorSection(title: "Startup") {
            VStack(alignment: .leading, spacing: 6) {
                WMSwitchRow("Start on launch",
                            isOn: Binding(get: { model.startsAtLogin }, set: { model.setStartsAtLogin($0) }))
                Text("Opens Wallpaper Mage when you log in to your Mac, so your live wallpapers are back right away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var languageSection: some View {
        InspectorSection(title: "Language") {
            VStack(alignment: .leading, spacing: 6) {
                WMSettingRow(title: "App language") {
                    Picker("App language", selection: $language.selection) {
                        Text("System Default (\(language.name(of: language.system)))").tag(String?.none)
                        Divider()
                        ForEach(language.available, id: \.self) { code in
                            Text(verbatim: language.name(of: code)).tag(String?.some(code))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                Text("System Default follows the order of your languages in System Settings > General > Language & Region.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if language.needsRestart {
                    LanguageRestartNotice(language: language, workshop: workshop)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(WMMotion.content, value: language.needsRestart)
        }
    }

    private var sound: some View {
        InspectorSection(title: "Sound") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Master volume")
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $model.masterVolume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    Text(model.masterVolume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Text("Scales the sound of every wallpaper on every display. Each wallpaper has its own volume too, in its settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                WMSwitchRow("Mute all wallpapers", isOn: Binding(get: { model.muted }, set: { model.setMuted($0) }))
                    .padding(.top, 6)
                Text("Silences every wallpaper, like Mute Sound in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                WMSwitchRow("Wallpapers react to system audio", isOn: $model.audioResponse)
                    .padding(.top, 6)
                Text("Lets audio visualisers in scene wallpapers follow what your Mac plays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lockScreen: some View {
        InspectorSection(title: "Lock Screen & Menu Bar") {
            VStack(alignment: .leading, spacing: 6) {
                WMSettingRow(title: "Update delay") {
                    Picker("Update delay", selection: $model.stillDelay) {
                        ForEach(LibraryState.stillDelayOptions, id: \.self) { Text(Self.delayTitle($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Text("How long to wait before the picture on your lock screen and behind the menu bar is updated after you change your wallpaper or its settings. A short wait keeps your Mac smooth while a new wallpaper starts and while you adjust settings. Choose a shorter delay to see the change sooner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func delayTitle(_ seconds: Double) -> LocalizedStringKey {
        seconds == 0 ? "No delay" : "\(seconds.formatted()) s"
    }
}

/// Shown once a language other than the one on screen is picked: the app switches when it restarts.
/// Its own view, so download progress redraws only this notice.
@MainActor
private struct LanguageRestartNotice: View {
    @ObservedObject var language: AppLanguage
    @ObservedObject var workshop: WorkshopModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.title3)
                .foregroundStyle(WMTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart Wallpaper Mage to switch to the new language.")
                    .font(.callout)
                if workshop.hasActiveDownloads {
                    Text("Restarting cancels the downloads in progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // The label stays in place under the spinner, so the button keeps its size.
            Button { language.restart() } label: {
                Text("Restart Now")
                    .opacity(language.isRestarting ? 0 : 1)
                    .overlay { if language.isRestarting { ProgressView().controlSize(.small) } }
            }
            .disabled(language.isRestarting)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(WMTheme.accent.opacity(0.1))
        }
    }
}

/// The About tab: what the app is, its version and where to find the project.
@MainActor
private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                Text(AppIdentity.name).font(.title2.weight(.semibold))
                Text("Version \(AppIdentity.version)").font(.callout).foregroundStyle(.secondary)
            }
            Text("Videos and Wallpaper Engine scenes for your desktop.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Link("Project page", destination: URL(string: "https://github.com/NOOB-3301/LiveWallpaper")!)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
