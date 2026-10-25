import SwiftUI
import AppKit
import Core

enum SettingsTab: Hashable {
    case general, steam
}

/// Opens the Settings window at a tab from anywhere in the app (the Workshop's "Open Steam Settings", for one).
@MainActor final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    @Published var tab: SettingsTab = .general
    /// SwiftUI's openSettings action, installed by SettingsOpenerInstaller on macOS 14 and later.
    fileprivate var openSettings: (() -> Void)?

    func open(_ tab: SettingsTab) {
        self.tab = tab
        if let openSettings {
            openSettings()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

/// Hands SwiftUI's openSettings action to SettingsNavigator. Since macOS 14 the Settings window opens only through
/// it (the old showSettingsWindow: action is ignored), and it is only readable from inside a view.
@available(macOS 14.0, *)
struct SettingsOpenerInstaller: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear { SettingsNavigator.shared.openSettings = { openSettings() } }
    }
}

/// The standard macOS Settings window (⌘,): settings about the app as a whole. Playback, rotation and the scene
/// settings live in the Library inspector (LibrarySettingsCard).
@MainActor
struct AppSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    @ObservedObject private var navigator = SettingsNavigator.shared

    var body: some View {
        TabView(selection: $navigator.tab) {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SteamSetupView(workshop: workshop, setup: SteamSetupModel.shared)
                .frame(width: 640, height: 620)
                .tabItem { Label("Steam", systemImage: "key.horizontal") }
                .tag(SettingsTab.steam)
        }
    }
}

@MainActor
private struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            lockScreen
            about
        }
        .padding(24)
        .frame(width: 640, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var lockScreen: some View {
        InspectorSection(title: "Lock Screen & Menu Bar") {
            VStack(alignment: .leading, spacing: 6) {
                LWSettingRow(title: "Update delay") {
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

    private static func delayTitle(_ seconds: Double) -> String {
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
                        Text("Live Wallpaper").font(.callout.weight(.semibold))
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
