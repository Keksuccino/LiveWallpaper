import Foundation
import CoreGraphics
import Metal
import AVFoundation
import Core
import SceneFormat

// Owner: SCENERENDER. The offline lock screen render: drives a SceneRenderer frame by frame (no display link, no
// window), blends the loop seam with LoopPlan, and writes an HEVC .mov with AVAssetWriter. Runs inside the scene
// host at low priority. Contract: SPEC3.md sections 1.5 and 3.4.

public struct LockRenderRequest: Sendable {
    public var scenePath: URL                 // VideoItem.path (scene.pkg or scene.json); ignored when scenePath is a still
    public var previewPath: URL?              // used for previewOnly scenes: encoded as a static loop
    public var assetsPath: URL?               // shared assets folder if present
    public var outputURL: URL                 // the final .mov; the writer first writes <name>.partial.mov next to it
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fps: Int
    public var loopSeconds: Double?           // nil = LoopPlan.choose(scenePeriod:)

    public init(scenePath: URL, previewPath: URL? = nil, assetsPath: URL? = nil, outputURL: URL,
                pixelWidth: Int, pixelHeight: Int, fps: Int = 30, loopSeconds: Double? = nil) {
        self.scenePath = scenePath
        self.previewPath = previewPath
        self.assetsPath = assetsPath
        self.outputURL = outputURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.loopSeconds = loopSeconds
    }
}

public enum LockRenderError: Error, Equatable, LocalizedError {
    case notImplemented
    case cancelled
    case sceneUnreadable(String)
    case noGPU
    case writerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented: return "The lock screen renderer is not implemented yet."
        case .cancelled: return "Rendering was cancelled."
        case .sceneUnreadable(let why): return "The scene could not be read (\(why))."
        case .noGPU: return "No Metal GPU is available."
        case .writerFailed(let why): return "The video could not be written (\(why))."
        }
    }
}

public enum LockVideoRenderer {
    /// Renders the loop and returns the loop length in seconds on success. Progress is 0...1 and is reported at least
    /// every 0.5 s of wall time. `isCancelled` is polled between frames; on cancel the partial file is deleted and
    /// `LockRenderError.cancelled` is thrown. On success the file at `outputURL` is complete (partial file renamed);
    /// writing the cache metadata (LockRenderCache.writeMeta) is the caller's job. Uses SceneRenderer at pixel size
    /// request.pixelWidth x pixelHeight, `.fill` fit, parallax `.zero` (a lock screen has no pointer), and no audio.
    public static func render(_ request: LockRenderRequest,
                              progress: @escaping @Sendable (Double) -> Void,
                              isCancelled: @escaping @Sendable () -> Bool) async throws -> Double {
        throw LockRenderError.notImplemented
    }
}
