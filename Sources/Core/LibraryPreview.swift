import Foundation
import CryptoKit

// A library wallpaper's preview: a still of it, drawn by the service like a display's system wallpaper and kept in
// AppPaths.libraryPreviewsDirectory until the wallpaper leaves the library or its file changes. Both processes name
// the files the same way, so Settings knows which previews are missing without asking the service.

public enum LibraryPreview {
    /// Every preview's pixels: 16:9 like the library's cards, a little over twice the widest card's points.
    public static let width = 768
    public static let height = 432
    /// HEIC at this quality keeps a preview around 40 KB with no visible loss at card size; higher qualities only grow
    /// the file.
    public static let quality = 0.5
    /// Bump when the preview of an unchanged wallpaper would come out differently; every preview is made again.
    private static let revision = 1
    private static let fileExtension = "heic"

    /// `<item id>_<digest>.heic`, the digest covering the wallpaper's file and its content (VideoItem.contentStamp),
    /// so a wallpaper whose file changes is missing its preview again. Reads the file's attributes.
    public static func fileName(for item: VideoItem) -> String {
        let key = Data("\(revision)\n\(item.path)\n\(item.contentStamp)".utf8)
        let digest = SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(item.id.uuidString)_\(digest).\(fileExtension)"
    }

    /// The wallpaper a file in the previews directory belongs to; nil for any other file (a preview still being
    /// written ends in `.partial`).
    public static func itemID(ofFile name: String) -> UUID? {
        guard name.hasSuffix("." + fileExtension), let separator = name.firstIndex(of: "_") else { return nil }
        return UUID(uuidString: String(name[..<separator]))
    }
}
