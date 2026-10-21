import Foundation

/// Bundle identifiers and the Info.plist role key, shared by the settings app and the background service.
public enum AppIdentity {
    public static let settingsBundleID = "com.noob3301.LiveWallpaper"
    public static let serviceBundleID = "com.noob3301.LiveWallpaper.service"
    /// Info.plist key that tells the two apps apart: "settings" or "service".
    public static let roleKey = "LWRole"
}
