import SwiftUI
import AppKit
import Core

/// The standard macOS Settings window (⌘,): settings about the app as a whole. Playback, rotation and the scene
/// settings live in the Library inspector (LibrarySettingsCard).
@MainActor
struct AppSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("General").font(.system(size: 24, weight: .semibold))

                lockScreen

                about
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 326)
        .background(Color(nsColor: .windowBackgroundColor))
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
