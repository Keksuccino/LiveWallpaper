import Foundation

// Owner: SCENEPARSE. Foundation only (no AppKit, CoreGraphics, Metal, AVFoundation, Core): this target is built and
// tested on Linux too. File containers: Wallpaper Engine's `.pkg` (SPEC3.md section 5.1) and plain folders.
// Format facts: SPEC3.md section 5 (RePKG, MIT, read for the layout; no code copied).

public enum SceneFormatError: Error, Equatable, LocalizedError {
    case notImplemented(String)
    case truncated(String)          // the data ends before a field it announces
    case badMagic(String)           // unknown container or texture signature
    case invalid(String)            // a value outside the sane range (counts, sizes, offsets)
    case missingFile(String)        // path not present in the source
    case unsupported(String)        // valid but outside what the engine can show

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let what): return "Not implemented yet: \(what)."
        case .truncated(let what): return "The file is cut off (\(what))."
        case .badMagic(let what): return "Unknown file format (\(what))."
        case .invalid(let what): return "The file is damaged (\(what))."
        case .missingFile(let path): return "Missing file: \(path)."
        case .unsupported(let what): return "Not supported: \(what)."
        }
    }
}

/// Read-only view of the files of one scene (a `.pkg`, a folder, or a layered pair with the shared assets).
/// Paths are relative, use "/" and are matched case-insensitively with any leading "/" ignored.
public protocol SceneFileSource: AnyObject, Sendable {
    var displayName: String { get }
    func fileExists(_ path: String) -> Bool
    func data(at path: String) throws -> Data
    func allPaths() -> [String]
}

/// A `.pkg` container, held in memory (memory-mapped when opened from a URL).
public final class PKGArchive: SceneFileSource {
    public struct Entry: Equatable, Sendable {
        public let path: String
        public let offset: Int       // relative to the start of the data section
        public let length: Int

        public init(path: String, offset: Int, length: Int) {
            self.path = path
            self.offset = offset
            self.length = length
        }
    }

    public let magic: String         // e.g. "PKGV0001"
    public let entries: [Entry]
    public let displayName: String

    /// Parses the header and entry table; throws truncated/badMagic/invalid (counts and offsets are range checked).
    public init(data: Data, displayName: String = "pkg") throws {
        self.magic = ""
        self.entries = []
        self.displayName = displayName
        throw SceneFormatError.notImplemented("PKGArchive.init(data:)")
    }

    /// Memory-mapped (`Data.ReadingOptions.alwaysMapped`).
    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data, displayName: url.lastPathComponent)
    }

    public func fileExists(_ path: String) -> Bool { false }
    public func data(at path: String) throws -> Data { throw SceneFormatError.missingFile(path) }
    public func allPaths() -> [String] { entries.map(\.path) }
}

/// A folder on disk (an unpacked scene, or the shared assets folder).
public final class DirectorySource: SceneFileSource {
    public let root: URL
    public var displayName: String { root.lastPathComponent }

    public init(root: URL) {
        self.root = root
    }

    public func fileExists(_ path: String) -> Bool { false }
    public func data(at path: String) throws -> Data { throw SceneFormatError.missingFile(path) }
    public func allPaths() -> [String] { [] }
}

/// `primary` first, then `fallback` (the scene's own files shadow the shared assets).
public final class LayeredSource: SceneFileSource {
    public let primary: SceneFileSource
    public let fallback: SceneFileSource?
    public var displayName: String { primary.displayName }

    public init(primary: SceneFileSource, fallback: SceneFileSource?) {
        self.primary = primary
        self.fallback = fallback
    }

    public func fileExists(_ path: String) -> Bool {
        primary.fileExists(path) || (fallback?.fileExists(path) ?? false)
    }

    public func data(at path: String) throws -> Data {
        if primary.fileExists(path) { return try primary.data(at: path) }
        if let fallback, fallback.fileExists(path) { return try fallback.data(at: path) }
        throw SceneFormatError.missingFile(path)
    }

    public func allPaths() -> [String] {
        var seen = Set(primary.allPaths().map { $0.lowercased() })
        var all = primary.allPaths()
        for path in fallback?.allPaths() ?? [] where seen.insert(path.lowercased()).inserted { all.append(path) }
        return all
    }
}
