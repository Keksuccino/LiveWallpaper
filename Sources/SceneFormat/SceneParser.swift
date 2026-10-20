import Foundation

// Owner: SCENEPARSE. `scene.json` parsing and the support analysis (badge). Foundation only.
// The rules are in SPEC3.md sections 5.3 (document) and 5.5 (badge). The parser is TOLERANT: a missing or oddly
// typed field falls back to its default and never throws; only an unreadable file or a missing/empty object list
// throws. Anything it cannot map is kept as `.other(key)` and shows up in the analysis, not as an error.

/// What the engine can render today. SceneAnalyzer compares a scene against this; each renderer milestone flips
/// flags here (owner of this file: SCENEPARSE; SCENERENDER asks for the flip in its report).
public struct EngineCapabilities: Equatable, Sendable {
    public var blendModes: Set<BlendMode>
    public var cameraParallax: Bool
    public var effects: Bool
    public var particles: Bool
    public var sound: Bool
    public var scripts: Bool
    public var puppet: Bool
    public var animatedTextures: Bool       // sprite sheets and video textures
    public var userProperties: Bool

    public init(blendModes: Set<BlendMode>, cameraParallax: Bool, effects: Bool = false, particles: Bool = false,
                sound: Bool = false, scripts: Bool = false, puppet: Bool = false, animatedTextures: Bool = false,
                userProperties: Bool = false) {
        self.blendModes = blendModes
        self.cameraParallax = cameraParallax
        self.effects = effects
        self.particles = particles
        self.sound = sound
        self.scripts = scripts
        self.puppet = puppet
        self.animatedTextures = animatedTextures
        self.userProperties = userProperties
    }

    /// Milestone 0: image layers, normal/opaque/additive/multiply/screen blending, camera parallax.
    public static let milestone0 = EngineCapabilities(
        blendModes: [.normal, .opaque, .additive, .multiply, .screen], cameraParallax: true)

    /// What the shipped renderer supports. The importer, the host and the unit tests all read this one value.
    public static let current = EngineCapabilities.milestone0
}

public enum SceneSupportLevel: String, Equatable, Sendable {
    case full, partial, previewOnly
}

/// A feature a scene uses. `unsupported` in SceneAnalysis lists the ones the engine ignores.
public enum SceneFeature: String, CaseIterable, Equatable, Hashable, Sendable {
    case imageLayers, cameraParallax, blendModes
    case effects, particles, sound, scripts, puppet, text, lights, model3D
    case userProperties, animatedTextures, unknownBlendMode, unknownObject
    case missingTexture, undecodableTexture, sharedAssetsNeeded, noRenderableLayer
}

public struct SceneAnalysis: Equatable, Sendable {
    public static let revision = 1               // stored in SceneInfo.analysisRevision

    public var support: SceneSupportLevel
    public var notes: [String]                   // user-facing, one short sentence each (SPEC3.md 5.5 has the wording)
    public var used: Set<SceneFeature>
    public var unsupported: Set<SceneFeature>
    public var designWidth: Int
    public var designHeight: Int
    public var loopSeconds: Double?              // nil = no known period (M0 never finds one: parallax-only scenes are static)
    public var needsSharedAssets: Bool

    public init(support: SceneSupportLevel, notes: [String] = [], used: Set<SceneFeature> = [],
                unsupported: Set<SceneFeature> = [], designWidth: Int = 1920, designHeight: Int = 1080,
                loopSeconds: Double? = nil, needsSharedAssets: Bool = false) {
        self.support = support
        self.notes = notes
        self.used = used
        self.unsupported = unsupported
        self.designWidth = designWidth
        self.designHeight = designHeight
        self.loopSeconds = loopSeconds
        self.needsSharedAssets = needsSharedAssets
    }
}

public struct LoadedScene: Sendable {
    public let files: SceneFileSource            // the scene's files, layered over the shared assets if given
    public let document: SceneDocument
    public let analysis: SceneAnalysis

    public init(files: SceneFileSource, document: SceneDocument, analysis: SceneAnalysis) {
        self.files = files
        self.document = document
        self.analysis = analysis
    }
}

public enum SceneLoader {
    /// Opens `scene.pkg` (or any `.pkg`), parses `scene.json` inside and analyses it. `sharedAssets` is the folder
    /// of Wallpaper Engine's shared assets (AppPaths.sharedAssetsDirectory) when present.
    public static func load(packageAt url: URL, sharedAssets: URL?,
                            capabilities: EngineCapabilities = .current) throws -> LoadedScene {
        throw SceneFormatError.notImplemented("SceneLoader.load(packageAt:)")
    }

    /// Same for an unpacked folder that contains `scene.json`.
    public static func load(directory url: URL, sharedAssets: URL?,
                            capabilities: EngineCapabilities = .current) throws -> LoadedScene {
        throw SceneFormatError.notImplemented("SceneLoader.load(directory:)")
    }

    /// Parses `scene.json` bytes (UTF-8, BOM tolerated) against `files` (used to resolve model -> material ->
    /// texture paths and to check that referenced files exist).
    public static func parseDocument(sceneJSON: Data, files: SceneFileSource) throws -> SceneDocument {
        throw SceneFormatError.notImplemented("SceneLoader.parseDocument")
    }
}

public enum SceneAnalyzer {
    /// Decides the badge. Pure: no rendering, no GPU. It decodes texture HEADERS only (to find out whether every
    /// first-pass texture exists and parses), never the pixel data.
    public static func analyze(document: SceneDocument, files: SceneFileSource,
                               capabilities: EngineCapabilities = .current) -> SceneAnalysis {
        SceneAnalysis(support: .previewOnly, notes: ["Scene analysis is not implemented yet."],
                      designWidth: Int(document.general.designWidth), designHeight: Int(document.general.designHeight))
    }
}
