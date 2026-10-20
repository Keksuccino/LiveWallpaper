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

/// Normalises an observed path the way the lookups need it: no leading or trailing "/", no "." segments.
/// The source keys its lookup table by this form, lowercased.
func normalizedPath(_ raw: String) -> String {
    var parts: [String] = []
    for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." { continue }
        parts.append(String(part))
    }
    return parts.joined(separator: "/")
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

    private let data: Data
    private let dataSectionStart: Int
    // path (normalised, lowercased) -> data range
    private let lookup: [String: Range<Int>]
    // path (normalised) -> path as written (for allPaths)
    private let displayPaths: [String]

    /// Parses the header and entry table; throws truncated/badMagic/invalid (counts and offsets are range checked).
    /// Duplicate paths: the last entry wins. The data section starts right after the entry table; `offset` is
    /// relative to it. Limits (hostile input): magic at most 32 bytes, paths at most 255 bytes, at most
    /// 100 000 entries, every `offset + length` inside the file, no integer overflow.
    public init(data: Data, displayName: String = "pkg") throws {
        self.data = data
        self.displayName = displayName

        var reader = DataReader(data)
        guard let magicBytes = reader.readBytes(max: 32) else {
            throw SceneFormatError.truncated("the magic is missing")
        }
        guard stringFromBytes(magicBytes).hasPrefix("PKGV") else {
            throw SceneFormatError.badMagic("the .pkg magic is missing")
        }
        self.magic = stringFromBytes(magicBytes)

        guard let entryCount = reader.readInt32(), entryCount >= 0 else {
            throw SceneFormatError.truncated("the entry count is missing")
        }
        guard entryCount <= 100_000 else {
            throw SceneFormatError.invalid("too many entries (\(entryCount))")
        }

        var parsed: [Entry] = []
        parsed.reserveCapacity(Int(entryCount))
        for index in 0..<entryCount {
            guard let pathBytes = reader.readBytes(max: 255) else {
                throw SceneFormatError.truncated("entry \(index): the path is missing")
            }
            let path = stringFromBytes(pathBytes)
            guard !path.isEmpty else { throw SceneFormatError.invalid("entry \(index): an empty path") }
            guard let offset = reader.readInt32(), offset >= 0 else {
                throw SceneFormatError.invalid("entry \(index): a negative or missing offset")
            }
            guard let length = reader.readInt32(), length >= 0 else {
                throw SceneFormatError.invalid("entry \(index): a negative or missing length")
            }
            parsed.append(Entry(path: path, offset: Int(offset), length: Int(length)))
        }
        guard !reader.isGoneWrong else { throw SceneFormatError.truncated("the entry table is cut off") }
        self.entries = parsed

        let sectionStart = reader.position
        self.dataSectionStart = sectionStart
        let sectionSize = data.count - sectionStart
        guard sectionSize >= 0 else { throw SceneFormatError.truncated("the entry table overruns the file") }

        var table: [String: Range<Int>] = [:]
        var paths: [String] = []
        paths.reserveCapacity(parsed.count)
        for entry in parsed {
            guard Int(entry.offset) <= Int.max - entry.length, entry.offset + entry.length <= sectionSize else {
                throw SceneFormatError.invalid("entry '\(entry.path)' points past the end of the file")
            }
            let key = normalizedPath(entry.path).lowercased()
            if table[key] == nil { paths.append(normalizedPath(entry.path)) }
            table[key] = (sectionStart + entry.offset)..<(sectionStart + entry.offset + entry.length)
        }
        self.lookup = table
        self.displayPaths = paths
    }

    /// Memory-mapped (`Data.ReadingOptions.alwaysMapped`).
    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try self.init(data: data, displayName: url.lastPathComponent)
    }

    public func fileExists(_ path: String) -> Bool {
        lookup[normalizedPath(path).lowercased()] != nil
    }

    public func data(at path: String) throws -> Data {
        guard let range = lookup[normalizedPath(path).lowercased()] else {
            throw SceneFormatError.missingFile(path)
        }
        return data.subdata(in: range)
    }

    public func allPaths() -> [String] { displayPaths }
}

/// A folder on disk (an unpacked scene, or the shared assets folder).
public final class DirectorySource: SceneFileSource {
    public let root: URL
    public var displayName: String { root.lastPathComponent }
    private let lookup: [String: URL]    // normalised lowercase path -> file URL

    public init(root: URL) {
        self.root = root
        self.lookup = DirectorySource.enumerate(root)
    }

    private static func enumerate(_ root: URL) -> [String: URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [:] }
        var table: [String: URL] = [:]
        for url in contents {
            let relative = root.path == url.path ? "" : String(url.path.dropFirst(root.path.count + 1))
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                for (key, file) in enumerate(url) {
                    let joined = normalizedPath(relative).isEmpty ? key : normalizedPath(relative) + "/" + key
                    table[joined.lowercased()] = file
                }
            } else {
                table[normalizedPath(relative).lowercased()] = url
            }
        }
        return table
    }

    public func fileExists(_ path: String) -> Bool {
        lookup[normalizedPath(path).lowercased()] != nil
    }

    public func data(at path: String) throws -> Data {
        guard let url = lookup[normalizedPath(path).lowercased()] else {
            throw SceneFormatError.missingFile(path)
        }
        return try Data(contentsOf: url)
    }

    public func allPaths() -> [String] { Array(lookup.keys) }
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

// MARK: - Small helpers

struct DataReader {
    let data: Data
    var position = 0
    var isGoneWrong = false

    init(_ data: Data) { self.data = data }

    /// One little-endian int32, nil (and stops the reader) when fewer than 4 bytes are left.
    mutating func readInt32() -> Int32? {
        guard position + 4 <= data.count else { isGoneWrong = true; return nil }
        let value = Int32(data[position]) | Int32(data[position + 1]) << 8
            | Int32(data[position + 2]) << 16 | Int32(data[position + 3]) << 24
        position += 4
        return value
    }

    /// One little-endian float32.
    mutating func readFloat32() -> Float? {
        guard position + 4 <= data.count else { isGoneWrong = true; return nil }
        let bits = UInt32(data[position]) | UInt32(data[position + 1]) << 8
            | UInt32(data[position + 2]) << 16 | UInt32(data[position + 3]) << 24
        position += 4
        return Float(bitPattern: bits)
    }

    /// A single byte, nil at the end of the data (used for C strings that have no length prefix).
    mutating func readSingleByte() -> Int? {
        guard position < data.count else { isGoneWrong = true; return nil }
        let value = Int(data[position])
        position += 1
        return value
    }

    var remaining: Int { data.count - position }

    /// A length-prefixed string field; at most `max` bytes.
    mutating func readBytes(max: Int) -> Data? {
        guard let length = readInt32(), length >= 0, length <= max else { isGoneWrong = true; return nil }
        guard position + Int(length) <= data.count else { isGoneWrong = true; return nil }
        let slice = data.subdata(in: position..<(position + Int(length)))
        position += Int(length)
        return slice
    }
}

func stringFromBytes(_ bytes: Data) -> String {
    String(decoding: bytes, as: UTF8.self)
}
