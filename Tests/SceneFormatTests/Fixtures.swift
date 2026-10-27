import Foundation
@testable import SceneFormat

/// Fixture builders for the container tests. Everything is a valid little-endian byte stream built by hand so the
/// tests state exactly what the format is, and stay independent of Wallpaper Engine content.

struct DataWriter {
    private(set) var data = Data()

    mutating func int32(_ value: Int32) {
        var stored = value.littleEndian
        withUnsafeBytes(of: &stored) { data.append(contentsOf: $0) }
    }

    /// Length-prefixed string (Int32 count + bytes, no terminator) — the .pkg layout (Reader.readBytes).
    mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        int32(Int32(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func bytes(_ value: Data) {
        data.append(value)
    }
}

// MARK: - .pkg

/// Builds a `.pkg`: length-prefixed magic, entry count, per entry (length-prefixed path, offset, length
/// relative to the data section), then the concatenated payload.
func pkgBytes(magic: String = "PKGV0001", entries: [(path: String, body: Data)]) -> Data {
    var writer = DataWriter()
    writer.string(magic)
    writer.int32(Int32(entries.count))
    var offset = 0
    for entry in entries {
        writer.string(entry.path)
        writer.int32(Int32(offset))
        writer.int32(Int32(entry.body.count))
        offset += entry.body.count
    }
    for entry in entries { writer.bytes(entry.body) }
    return writer.data
}

func jsonBytes(_ value: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: value)
}
