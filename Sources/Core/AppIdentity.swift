import Foundation

/// The app's name, bundle identifiers and the Info.plist role key, shared by the settings app and the background
/// service.
public enum AppIdentity {
    /// The app's name, the same in every language: never put it through localization on its own.
    public static let name = "Wallpaper Mage"
    public static let settingsBundleID = "com.noob3301.WallpaperMage"
    public static let serviceBundleID = "com.noob3301.WallpaperMage.service"
    /// Info.plist key that tells the two apps apart: "settings" or "service".
    public static let roleKey = "WMRole"
}
