import Foundation

/// The app's name, version, bundle identifiers and the Info.plist role key, shared by the settings app and the
/// background service.
public enum AppIdentity {
    /// The app's name, the same in every language: never put it through localization on its own.
    public static let name = "Wallpaper Mage"
    /// The running bundle's version, e.g. "3.0 (3)". build.sh gives both bundles the same version.
    public static let version: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }()
    public static let settingsBundleID = "com.noob3301.WallpaperMage"
    public static let serviceBundleID = "com.noob3301.WallpaperMage.service"
    /// Info.plist key that tells the two apps apart: "settings" or "service".
    public static let roleKey = "WMRole"
    /// Distributed notification from the service's Quit menu item that asks the settings app to quit.
    public static let quitRequest = Notification.Name("com.noob3301.WallpaperMage.quitRequest")
}
