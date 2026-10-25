import Foundation

// Owner: SCENEPARSE (produces) / SCENERENDER (consumes). The document model of a parsed `scene.json`.
// This file is the CONTRACT between the two workers: existing declarations keep their names and types; add new
// members only with default values so the other side keeps compiling. Everything is a plain value (Sendable);
// resolution of model/material/texture paths has already happened, so the renderer never parses JSON.

public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double = 0, _ y: Double = 0) {
        self.x = x
        self.y = y
    }
    public static let zero = Vec2(0, 0)
    public static let one = Vec2(1, 1)
}

public struct Vec3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
    public static let zero = Vec3(0, 0, 0)
    public static let one = Vec3(1, 1, 1)
}

/// How a layer is composited onto what is below it. Parsed from the material pass `blending` string.
public enum BlendMode: String, Equatable, Sendable {
    case normal        // source over, alpha from the texture ("translucent" and "normal" in material files, UNVERIFIED)
    case opaque        // no blending ("opaque" / "disabled", UNVERIFIED)
    case additive
    case multiply
    case screen
    case unknown       // a string the parser does not know; rendered as .normal and reported as partial
}

public struct SceneCamera: Equatable, Sendable {
    public var center: Vec3
    public var eye: Vec3
    public var up: Vec3

    public init(center: Vec3 = .zero, eye: Vec3 = Vec3(0, 0, 1), up: Vec3 = Vec3(0, 1, 0)) {
        self.center = center
        self.eye = eye
        self.up = up
    }
}

public struct SceneGeneral: Equatable, Sendable {
    public var clearColor: Vec3                 // 0...1 per channel
    public var designWidth: Double              // general.orthogonalprojection
    public var designHeight: Double
    public var cameraParallax: Bool
    public var parallaxAmount: Double           // general.cameraparallaxamount (default 1)
    public var parallaxDelay: Double            // general.cameraparallaxdelay (smoothing, seconds)
    public var parallaxMouseInfluence: Double   // general.cameraparallaxmouseinfluence (default 1)
    public var hasBloom: Bool                   // post effect, ignored in M0
    public var hasHDR: Bool

    public init(clearColor: Vec3 = Vec3(0, 0, 0), designWidth: Double = 1920, designHeight: Double = 1080,
                cameraParallax: Bool = false, parallaxAmount: Double = 1, parallaxDelay: Double = 0.1,
                parallaxMouseInfluence: Double = 1, hasBloom: Bool = false, hasHDR: Bool = false) {
        self.clearColor = clearColor
        self.designWidth = designWidth
        self.designHeight = designHeight
        self.cameraParallax = cameraParallax
        self.parallaxAmount = parallaxAmount
        self.parallaxDelay = parallaxDelay
        self.parallaxMouseInfluence = parallaxMouseInfluence
        self.hasBloom = hasBloom
        self.hasHDR = hasHDR
    }
}

/// An effect attached to an image layer (shader passes over the layer). Parsed so M1 can use it; M0 ignores it.
public struct EffectInstance: Equatable, Sendable {
    public var file: String                     // "effects/waterripple/effect.json"
    public var name: String
    public var visible: Bool

    public init(file: String, name: String = "", visible: Bool = true) {
        self.file = file
        self.name = name
        self.visible = visible
    }
}

/// A textured quad. The path fields are already resolved against the scene files.
public struct ImageLayer: Equatable, Sendable {
    public var modelPath: String?               // "models/foo.json"
    public var materialPath: String?            // "materials/foo.json"
    public var texturePath: String?             // first texture of the first pass, e.g. "materials/foo.tex"
    public var extraTexturePaths: [String]      // other textures of the first pass (masks, noise): ignored in M0
    public var shader: String?                  // first pass shader name, e.g. "genericimage2"
    public var blend: BlendMode
    public var sourceSize: Vec2?                // the model's own width/height if it declares them
    public var effects: [EffectInstance]
    public var passCount: Int
    public var usesPuppet: Bool                 // skeletal animation (M3)

    public init(modelPath: String? = nil, materialPath: String? = nil, texturePath: String? = nil,
                extraTexturePaths: [String] = [], shader: String? = nil, blend: BlendMode = .normal,
                sourceSize: Vec2? = nil, effects: [EffectInstance] = [], passCount: Int = 1, usesPuppet: Bool = false) {
        self.modelPath = modelPath
        self.materialPath = materialPath
        self.texturePath = texturePath
        self.extraTexturePaths = extraTexturePaths
        self.shader = shader
        self.blend = blend
        self.sourceSize = sourceSize
        self.effects = effects
        self.passCount = passCount
        self.usesPuppet = usesPuppet
    }
}

public enum SceneObjectKind: Equatable, Sendable {
    case image(ImageLayer)
    case particle(path: String)                 // "particles/foo.json" (M2)
    case sound(paths: [String])                 // (M3)
    case text                                   // dynamic text (later)
    case light                                  // (later)
    case model3D(path: String)                  // not planned
    case group                                  // transform-only parent
    case other(String)                          // anything unrecognised, with the key that identified it
}

public struct SceneObject: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var kind: SceneObjectKind
    public var origin: Vec3                     // scene units, y up, (designWidth/2, designHeight/2) = centre
    public var angles: Vec3                     // degrees; z rotates in the image plane
    public var scale: Vec3
    public var size: Vec2?                      // object size in scene units; nil = take it from the texture
    public var visible: Bool
    public var parentID: Int?
    public var parallaxDepth: Vec2              // 0 = fixed to the camera, 1 = moves with the world
    public var alpha: Double                    // 0...1
    public var color: Vec3                      // tint, 0...1
    public var brightness: Double
    public var hasScripts: Bool                 // any property was bound to a SceneScript
    public var hasUserProperties: Bool          // any property was bound to a user property

    public init(id: Int, name: String = "", kind: SceneObjectKind, origin: Vec3 = .zero, angles: Vec3 = .zero,
                scale: Vec3 = .one, size: Vec2? = nil, visible: Bool = true, parentID: Int? = nil,
                parallaxDepth: Vec2 = .zero, alpha: Double = 1, color: Vec3 = .one, brightness: Double = 1,
                hasScripts: Bool = false, hasUserProperties: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.origin = origin
        self.angles = angles
        self.scale = scale
        self.size = size
        self.visible = visible
        self.parentID = parentID
        self.parallaxDepth = parallaxDepth
        self.alpha = alpha
        self.color = color
        self.brightness = brightness
        self.hasScripts = hasScripts
        self.hasUserProperties = hasUserProperties
    }
}

public struct SceneDocument: Equatable, Sendable {
    public var version: Int
    public var general: SceneGeneral
    public var camera: SceneCamera
    public var objects: [SceneObject]           // file order = draw order, back to front

    public init(version: Int = 1, general: SceneGeneral = SceneGeneral(), camera: SceneCamera = SceneCamera(),
                objects: [SceneObject] = []) {
        self.version = version
        self.general = general
        self.camera = camera
        self.objects = objects
    }
}
