import Foundation

// Where the pre-rendered lock screen video of a scene lives and when it is still valid. Pure file logic in Core so
// the agent can check the cache without linking the scene engine. Layout (SPEC3.md section 1.5):
//   Library/<id>/lock-<W>x<H>.mov       the finished loop (HEVC, no audio)
//   Library/<id>/lock-<W>x<H>.json      LockRenderCache.Meta, written after the .mov is complete
//   Library/<id>/lock-<W>x<H>.partial.mov   the writer's output until it is finished (deleted on cancel or crash)

public enum LockRenderCache {
    /// Bump when the renderer's output for an unchanged scene changes (new effects, fixed parallax, ...).
    /// SceneEngine reads this constant; a bump makes every cached lock video stale.
    public static let engineRevision = 1

    public struct Meta: Codable, Equatable, Sendable {
        public var engineRevision: Int
        public var width: Int
        public var height: Int
        public var fps: Int
        public var loopSeconds: Double
        public var sourceStamp: String     // sourceStamp(for:) when the render started
        public var createdAt: Double       // seconds since 1970

        public init(engineRevision: Int = LockRenderCache.engineRevision, width: Int, height: Int, fps: Int,
                    loopSeconds: Double, sourceStamp: String, createdAt: Double = Date().timeIntervalSince1970) {
            self.engineRevision = engineRevision
            self.width = width
            self.height = height
            self.fps = fps
            self.loopSeconds = loopSeconds
            self.sourceStamp = sourceStamp
            self.createdAt = createdAt
        }
    }

    /// The item's own folder (Library/<id>/).
    public static func folder(for item: VideoItem) -> URL {
        item.url.deletingLastPathComponent()
    }

    public static func videoURL(for item: VideoItem, width: Int, height: Int) -> URL {
        folder(for: item).appendingPathComponent("lock-\(width)x\(height).mov")
    }

    public static func partialURL(for item: VideoItem, width: Int, height: Int) -> URL {
        folder(for: item).appendingPathComponent("lock-\(width)x\(height).partial.mov")
    }

    public static func metaURL(for item: VideoItem, width: Int, height: Int) -> URL {
        folder(for: item).appendingPathComponent("lock-\(width)x\(height).json")
    }

    /// Identifies the scene content: size and modification time of `item.path`. Changes when the Workshop item
    /// is re-downloaded with new content.
    public static func sourceStamp(for item: VideoItem) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: item.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(Int(modified))"
    }

    public static func readMeta(for item: VideoItem, width: Int, height: Int) -> Meta? {
        guard let data = try? Data(contentsOf: metaURL(for: item, width: width, height: height)) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    public static func writeMeta(_ meta: Meta, for item: VideoItem) throws {
        let data = try JSONEncoder().encode(meta)
        try data.write(to: metaURL(for: item, width: meta.width, height: meta.height), options: .atomic)
    }

    /// True when a finished video exists for exactly this size, was made by this engine revision from this
    /// scene content, and is not empty.
    public static func isValid(for item: VideoItem, width: Int, height: Int) -> Bool {
        let video = videoURL(for: item, width: width, height: height)
        let attributes = try? FileManager.default.attributesOfItem(atPath: video.path)
        guard let bytes = (attributes?[.size] as? NSNumber)?.int64Value, bytes > 0,
              let meta = readMeta(for: item, width: width, height: height) else { return false }
        return meta.engineRevision == engineRevision && meta.width == width && meta.height == height
            && meta.sourceStamp == sourceStamp(for: item)
    }

    /// Deletes lock videos (and metadata, and leftover partial files) of every size except the given one.
    public static func removeStale(for item: VideoItem, keepingWidth width: Int, height: Int) {
        let keep = "lock-\(width)x\(height)."
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder(for: item), includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("lock-") && !file.lastPathComponent.hasPrefix(keep) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
