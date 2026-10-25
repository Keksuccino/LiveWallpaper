import SwiftUI
import AppKit
import Core

enum SettingsTab: Hashable {
    case general, steam
}

/// Opens Settings at a tab from anywhere in the app (the sidebar's ⚙, ⌘, and the Workshop's "Open Steam Settings").
@MainActor final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    @Published var tab: SettingsTab = .general
    /// Settings is shown as a sheet on the main window (RootView).
    @Published var isPresented = false

    /// Opens Settings at `tab`, or at the tab it showed last.
    func open(_ tab: SettingsTab? = nil) {
        if let tab { self.tab = tab }
        isPresented = true
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
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 14)

            Divider()

            Group {
                switch navigator.tab {
                case .general:
                    ScrollView { GeneralSettingsView(model: model) }
                case .steam:
                    SteamSetupView(workshop: workshop, setup: SteamSetupModel.shared)
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
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { navigator.isPresented = false }
    }
}

@MainActor
private struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            sound
            lockScreen
            about
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Toggle("Mute all wallpapers", isOn: Binding(get: { model.muted }, set: { model.setMuted($0) }))
                    .padding(.top, 6)
                Text("Silences every wallpaper, like Mute Sound in the menu bar.")
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

    private var about: some View {
        InspectorSection(title: "About") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppIdentity.name).font(.callout.weight(.semibold))
                        Text("Version \(version)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Videos and Wallpaper Engine scenes for your desktop. Settings never plays a wallpaper; the background service does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Link("Project page", destination: URL(string: "https://github.com/NOOB-3301/LiveWallpaper")!)
                    Link("Wallpaper Settings", destination: URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                }
                .font(.caption)
            }
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
