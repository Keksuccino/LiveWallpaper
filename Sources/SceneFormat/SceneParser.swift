import Foundation

// Owner: SCENEPARSE. `scene.json` parsing and the support analysis (badge). Foundation only.
// The rules are in SPEC3.md sections 5.3 (document) and 5.5 (badge). The parser is TOLERANT: a missing or oddly
// typed field falls back to its default and never throws; only an unreadable file or a missing object list
// throws. Anything it cannot map is kept as `.other(key)` and shows up in the analysis, not as an error.
// Coordinate convention (UNVERIFIED, SPEC3.md 9.2 T10): Wallpaper Engine files keep origin at the TOP-LEFT with
// y down; the document model converts to the contract's space (bottom-left origin, y up, so
// (designWidth/2, designHeight/2) is the centre) by mirroring y.

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
    case missingTexture, undecodableTexture, sharedAssetsNeeded, noRenderableLayer, bloomOrHDR
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
    /// Opens the `.pkg`, parses `scene.json` inside and analyses it. `sharedAssets` is the folder of Wallpaper
    /// Engine's shared assets (AppPaths.sharedAssetsDirectory) when present.
    public static func load(packageAt url: URL, sharedAssets: URL?,
                            capabilities: EngineCapabilities = .current) throws -> LoadedScene {
        let archive = try PKGArchive(contentsOf: url)
        let files = LayeredSource(primary: archive, fallback: sharedAssets.map { DirectorySource(root: $0) })
        let json = try archive.data(at: try pathForSceneJSON(in: archive))
        let document = try parseDocument(sceneJSON: json, files: files)
        let analysis = SceneAnalyzer.analyze(document: document, files: files, capabilities: capabilities)
        return LoadedScene(files: files, document: document, analysis: analysis)
    }

    /// Same for an unpacked folder that contains `scene.json`.
    public static func load(directory url: URL, sharedAssets: URL?,
                            capabilities: EngineCapabilities = .current) throws -> LoadedScene {
        let source = DirectorySource(root: url)
        let files = LayeredSource(primary: source, fallback: sharedAssets.map { DirectorySource(root: $0) })
        guard source.fileExists("scene.json") else { throw SceneFormatError.missingFile("scene.json") }
        let json = try source.data(at: "scene.json")
        let document = try parseDocument(sceneJSON: json, files: files)
        let analysis = SceneAnalyzer.analyze(document: document, files: files, capabilities: capabilities)
        return LoadedScene(files: files, document: document, analysis: analysis)
    }

    /// Parses `scene.json` bytes (UTF-8, BOM tolerated) against `files` (used to resolve model -> material ->
    /// texture paths and to check that referenced files exist).
    public static func parseDocument(sceneJSON: Data, files: SceneFileSource) throws -> SceneDocument {
        try SceneDocumentParser.parse(json: withoutBOM(sceneJSON), files: files)
    }

    /// `scene.json`; some scenes pack it under a different case or inside a folder prefix.
    public static func pathForSceneJSON(in files: SceneFileSource) throws -> String {
        for candidate in ["scene.json", "Scene.json", "SCENE.JSON"] where files.fileExists(candidate) {
            return candidate
        }
        for path in files.allPaths() where path.lowercased().hasSuffix("scene.json") { return path }
        throw SceneFormatError.missingFile("scene.json")
    }
}

public enum SceneAnalyzer {
    /// Decides the badge. Pure: no rendering, no GPU. It decodes texture HEADERS only (sizes and payload kind, to
    /// find out whether every first-pass texture exists and can decode), never the pixel data.
    public static func analyze(document: SceneDocument, files: SceneFileSource,
                               capabilities: EngineCapabilities = .current) -> SceneAnalysis {
        var used: Set<SceneFeature> = []
        var unsupported: Set<SceneFeature> = []
        var needsSharedAssets = false
        var renderableLayer = false
        var textureMissing = false
        var textureUndecodable = false

        for object in document.objects where object.visible && object.alpha > 0 {
            if case .image(let layer) = object.kind {
                used.insert(.imageLayers)
                if layer.hasVisibleEffect, !capabilities.effects { unsupported.insert(.effects) }
                if let texturePath = layer.texturePath {
                    if let data = try? files.data(at: texturePath),
                       case let header = try? TexDecoder.header(for: data), let header {
                        switch header.payload {
                        case .pixels, .image:
                            renderableLayer = true
                            if header.flags.contains(.isGif) || header.flags.contains(.isVideoTexture),
                               !capabilities.animatedTextures {
                                unsupported.insert(.animatedTextures)
                            }
                        case .video:
                            textureUndecodable = true
                        }
                    } else {
                        textureUndecodable = true
                    }
                    if !LayeredPathProbe.inPrimary(files, path: texturePath) {
                        needsSharedAssets = true
                    }
                } else {
                    textureMissing = true
                    needsSharedAssets = true
                }
                if object.hasScripts, !capabilities.scripts { unsupported.insert(.scripts) }
                if object.hasUserProperties, !capabilities.userProperties { unsupported.insert(.userProperties) }
                if layer.usesPuppet, !capabilities.puppet { unsupported.insert(.puppet) }
                if !capabilities.blendModes.contains(layer.blend) {
                    unsupported.insert(.unknownBlendMode)
                }
            } else if case .particle = object.kind {
                unsupported.insert(.particles)
            } else if case .sound = object.kind {
                unsupported.insert(.sound)
            } else if case .text = object.kind {
                unsupported.insert(.text)
            } else if case .light = object.kind {
                unsupported.insert(.lights)
            } else if case .model3D = object.kind {
                unsupported.insert(.model3D)
            }
        }

        if document.general.cameraParallax && capabilities.cameraParallax { used.insert(.cameraParallax) }
        if document.general.hasBloom || document.general.hasHDR { unsupported.insert(.bloomOrHDR) }
        if textureMissing { unsupported.insert(.missingTexture) }
        if textureUndecodable { unsupported.insert(.undecodableTexture) }

        let support: SceneSupportLevel
        if !renderableLayer {
            support = .previewOnly
            unsupported.insert(.noRenderableLayer)
        } else if unsupported.isEmpty {
            support = .full
        } else {
            support = .partial
        }
        if needsSharedAssets && !renderableLayer { needsSharedAssets = true }   // any missing texture
        if !needsSharedAssets { needsSharedAssets = LayeredPathProbe.foundOnlyInFallback(files, document: document) }

        return SceneAnalysis(
            support: support, notes: notes(for: support, unsupported: unsupported), used: used,
            unsupported: unsupported, designWidth: Int(document.general.designWidth),
            designHeight: Int(document.general.designHeight), loopSeconds: nil,
            needsSharedAssets: needsSharedAssets)
    }

    /// One sentence per distinct reason, in the fixed order of SPEC3.md 5.5, at most 5 notes and 80 characters.
    public static func notes(for support: SceneSupportLevel, unsupported: Set<SceneFeature>) -> [String] {
        var notes: [String] = []
        func collect(_ feature: SceneFeature, _ text: String) {
            guard unsupported.contains(feature), !notes.contains(text) else { return }
            notes.append(text)
        }
        collect(.effects, "Effects (water, glow, …) are not supported yet and are skipped.")
        collect(.particles, "Particles are not supported yet.")
        collect(.sound, "Sound isn’t supported yet.")
        collect(.scripts, "Scripted behaviour isn’t supported yet.")
        collect(.puppet, "Character animation isn’t supported yet.")
        collect(.text, "Some objects (text, lights, 3D) are skipped.")
        collect(.lights, "Some objects (text, lights, 3D) are skipped.")
        collect(.model3D, "Some objects (text, lights, 3D) are skipped.")
        collect(.userProperties, "User settings of this wallpaper aren’t supported yet.")
        collect(.animatedTextures, "Animated textures show their first frame only.")
        collect(.unknownBlendMode, "A blend mode isn’t supported and is drawn as normal.")
        collect(.missingTexture, "Some images are missing or unreadable.")
        collect(.undecodableTexture, "Some images are missing or unreadable.")
        collect(.bloomOrHDR, "Glow and colour post-processing are skipped.")
        collect(.noRenderableLayer, "Only the preview image is shown.")
        return notes.prefix(5).map { String($0.prefix(80)) }
    }
}

/// Distinguishes "the scene has its own copy" from "it references the shared assets".
enum LayeredPathProbe {
    static func inPrimary(_ source: SceneFileSource, path: String) -> Bool {
        if let layered = source as? LayeredSource { return layered.primary.fileExists(path) }
        return source.fileExists(path)
    }

    static func foundOnlyInFallback(_ source: SceneFileSource, document: SceneDocument) -> Bool {
        guard let layered = source as? LayeredSource, layered.fallback != nil else { return false }
        for object in document.objects {
            if case .image(let layer) = object.kind, let path = layer.texturePath,
               layered.fallback?.fileExists(path) == true, !layered.primary.fileExists(path) {
                return true
            }
        }
        return false
    }
}

// MARK: - The document parser (tolerant JSON)

private enum SceneDocumentParser {
    static let maxObjects = 20_000

    static func parse(json original: Data, files: SceneFileSource) throws -> SceneDocument {
        let json = withoutBOM(original)
        guard let rootAny = try? JSONSerialization.jsonObject(with: json, options: [.allowFragments]),
              let root = rootAny as? [String: Any] else {
            throw SceneFormatError.invalid("scene.json is not valid JSON")
        }
        guard let objectsValue = root["objects"] as? [Any] else {
            throw SceneFormatError.invalid("scene.json has no object list")
        }
        guard objectsValue.count <= maxObjects else {
            throw SceneFormatError.invalid("too many objects (\(objectsValue.count))")
        }

        var document = SceneDocument()
        document.version = plainInt(root["version"]) ?? 1

        if let general = root["general"] as? [String: Any] {
            document.general.clearColor = asColor(general["clearcolor"]) ?? .zero
            if let projection = general["orthogonalprojection"] as? [String: Any] {
                document.general.designWidth = plainDouble(projection["width"]) ?? document.general.designWidth
                document.general.designHeight = plainDouble(projection["height"]) ?? document.general.designHeight
            }
            document.general.cameraParallax = plainBool(general["cameraparallax"]) ?? false
            document.general.parallaxAmount = plainDouble(general["cameraparallaxamount"]) ?? 1
            document.general.parallaxDelay = plainDouble(general["cameraparallaxdelay"]) ?? 0.1
            document.general.parallaxMouseInfluence = plainDouble(general["cameraparallaxmouseinfluence"]) ?? 1
            document.general.hasBloom = plainBool(general["bloom"]) ?? false
            document.general.hasHDR = plainBool(general["hdr"]) ?? false
        }
        var cameraCentreSeen = false
        if let camera = root["camera"] as? [String: Any] {
            // The camera centre is a FILE value (y down). A zero centre means "no camera offset" and has to
            // fall back to the design centre; the check must happen before the y flip, because (0, 0) mirrors
            // to (0, designHeight) and would no longer look like zero.
            if let raw = asVec3(camera["center"]) {
                cameraCentreSeen = true
                // Also outside the design area: ortho scenes carry a look-at direction here (e.g. -46 -29 -1), not a
                // position; honouring it throws the whole scene out of frame.
                if (raw.x == 0 && raw.y == 0) || raw.x < 0 || raw.y < 0
                    || raw.x > document.general.designWidth || raw.y > document.general.designHeight {
                    document.camera.center = Vec3(document.general.designWidth / 2,
                                                  document.general.designHeight / 2, 0)
                } else {
                    document.camera.center = asVec3(camera["center"], height: document.general.designHeight) ?? raw
                }
            }
            if let eye = asVec3(camera["eye"]) { document.camera.eye = eye }
            if let up = asVec3(camera["up"]) { document.camera.up = up }
        }
        if !cameraCentreSeen {
            document.camera.center = Vec3(document.general.designWidth / 2, document.general.designHeight / 2, 0)
        }

        var objects: [SceneObject] = []
        for (index, anyObject) in objectsValue.enumerated() {
            guard let dict = anyObject as? [String: Any] else { continue }
            if let object = parseObject(dict, fallbackID: index, files: files,
                                        designHeight: document.general.designHeight) {
                objects.append(object)
            }
        }
        document.objects = breakParentCycles(objects)
        return document
    }

    // MARK: one object

    private static func parseObject(_ raw: [String: Any], fallbackID: Int, files: SceneFileSource,
                                    designHeight: Double) -> SceneObject? {
        let kind: SceneObjectKind
        if let _ = raw["image"] {
            kind = .image(parseImageLayer(raw["image"], object: raw, files: files))
        } else if let particle = plainString(raw["particle"]) {
            kind = .particle(path: cleanPath(particle) ?? "")
        } else if let _ = raw["sound"] {
            kind = .sound(paths: parseSoundPaths(raw["sound"]))
        } else if raw["text"] != nil {
            kind = .text
        } else if raw["light"] != nil {
            kind = .light
        } else if let model = plainString(raw["model"]) {
            kind = .model3D(path: cleanPath(model) ?? "")
        } else {
            kind = .group
        }

        let bound = boundValues(in: raw)
        return SceneObject(
            id: plainInt(raw["id"]) ?? fallbackID,
            name: plainString(raw["name"]) ?? "",
            kind: kind,
            origin: asVec3(raw["origin"], height: designHeight) ?? .zero,
            angles: asVec3(raw["angles"]) ?? .zero,
            scale: asVec3(raw["scale"]) ?? .one,
            size: asVec2(raw["size"]),
            visible: plainBool(raw["visible"]) ?? true,
            parentID: plainInt(raw["parent"]),
            parallaxDepth: asVec2(raw["parallaxdepth"]) ?? .one,
            alpha: plainDouble(raw["alpha"]) ?? 1,
            color: asColor(raw["color"]) ?? .one,
            brightness: plainDouble(raw["brightness"]) ?? 1,
            hasScripts: bound.scripts,
            hasUserProperties: bound.userProperties)
    }

    private static func parseImageLayer(_ imageValue: Any?, object raw: [String: Any],
                                        files: SceneFileSource) -> ImageLayer {
        var layer = ImageLayer()
        guard let modelPath = cleanPath(plainString(imageValue)) else { return layer }
        layer.modelPath = modelPath
        guard files.fileExists(modelPath), let model = json(at: modelPath, files: files) else {
            return layer          // the analyzer reports the missing textures / preview fallback
        }

        layer.usesPuppet = plainString(model["puppet"]) != nil
        let width = plainDouble(model["width"]), height = plainDouble(model["height"])
        if width != nil || height != nil {
            layer.sourceSize = Vec2(width ?? 0, height ?? 0)
        }

        guard let materialPath = cleanPath(plainString(model["material"])) else { return layer }
        layer.materialPath = materialPath
        guard files.fileExists(materialPath),
              let material = json(at: materialPath, files: files),
              let passes = material["passes"] as? [Any], !passes.isEmpty,
              let firstPass = passes.first as? [String: Any] else { return layer }
        layer.passCount = passes.count
        layer.shader = plainString(firstPass["shader"])
        layer.blend = blendMode(for: (plainString(firstPass["blending"]) ?? "").lowercased())

        if let textures = firstPass["textures"] as? [Any], !textures.isEmpty {
            for extra in textures.dropFirst() {
                if let resolved = resolveTexture(plainString(extra), files: files) {
                    layer.extraTexturePaths.append(resolved)
                }
            }
            layer.texturePath = resolveTexture(plainString(textures.first), files: files)
        }

        let effectsAny = firstPass["effects"] as? [Any] ?? raw["effects"] as? [Any]
        if let effectsList = effectsAny {
            layer.effects = effectsList.compactMap { value -> EffectInstance? in
                guard let effect = value as? [String: Any], let file = plainString(effect["file"]) else { return nil }
                return EffectInstance(file: file, name: plainString(effect["name"]) ?? "",
                                      visible: plainBool(effect["visible"]) ?? true)
            }
        }
        return layer
    }

    static func json(at path: String, files: SceneFileSource) -> [String: Any]? {
        guard let data = try? files.data(at: path),
              let object = try? JSONSerialization.jsonObject(with: withoutBOM(data), options: [.allowFragments])
        else { return nil }
        return object as? [String: Any]
    }

    private static func blendMode(for raw: String) -> BlendMode {
        switch raw {
        case "translucent", "normal": return .normal
        case "additive": return .additive
        case "opaque", "disabled": return .opaque
        case "multiply": return .multiply
        case "screen": return .screen
        default: return raw.isEmpty ? .normal : .unknown
        }
    }

    /// A texture entry ("foo") maps to `materials/foo.tex`; a path already given is kept if it exists.
    static func resolveTexture(_ raw: String?, files: SceneFileSource) -> String? {
        guard let path = cleanPath(raw) else { return nil }
        let stem = (path as NSString).deletingPathExtension
        let candidates = [path, "materials/\(path)", "materials/\(stem).tex"]
        return candidates.first { files.fileExists($0) }
    }

    private static func parseSoundPaths(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list.compactMap { cleanPath(plainString($0)) }
        }
        if let dict = value as? [String: Any], let list = dict["sounds"] as? [Any] {
            return list.compactMap { cleanPath(plainString($0)) }
        }
        return cleanPath(plainString(value)).map { [$0] } ?? []
    }

    /// Detects `parent` cycles (a -> b -> a and longer): the object inside the cycle keeps its own transform but
    /// the link that closes the cycle is removed, so every chain terminates.
    static func breakParentCycles(_ objects: [SceneObject]) -> [SceneObject] {
        var indexByID: [Int: Int] = [:]
        for (index, object) in objects.enumerated() { indexByID[object.id] = index }
        var result = objects
        for start in objects.indices {
            var visited: Set<Int> = [start]
            var cursor = start
            while let parentID = objects[cursor].parentID, let parentIndex = indexByID[parentID] {
                if visited.contains(parentIndex) {
                    result[cursor].parentID = nil
                    break
                }
                visited.insert(parentIndex)
                cursor = parentIndex
                if cursor == start { break }
            }
        }
        return result
    }
}

// MARK: scalar and vector reading

/// Extracts plain values out of Wallpaper Engine's bound-value wrappers: a scalar may arrive as
/// `{ "value": v, "user": "..." }`, `{ "value": v, "script": "..." }` (with or without "animation"); the
/// `value` is used and the binding is reported in the document flags.
private func plainValue(_ value: Any?) -> (plain: Any?, script: Bool, userProperty: Bool)? {
    guard let dict = value as? [String: Any], dict["value"] != nil else { return nil }
    return (dict["value"], plainString(dict["script"]) != nil, plainString(dict["user"]) != nil)
}

private func unwrap(_ value: Any?) -> Any? {
    plainValue(value)?.plain ?? value
}

private func plainDouble(_ value: Any?) -> Double? {
    switch unwrap(value) {
    case let int as Int: return Double(int)
    case let double as Double: return double
    case let float as Float: return Double(float)
    case let bool as Bool: return bool ? 1 : 0
    case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
}

private func plainInt(_ value: Any?) -> Int? {
    switch unwrap(value) {
    case let int as Int: return int
    case let double as Double: return Int(double)
    case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
}

private func plainString(_ value: Any?) -> String? {
    unwrap(value) as? String
}

private func plainBool(_ value: Any?) -> Bool? {
    switch unwrap(value) {
    case let bool as Bool: return bool
    case let int as Int: return int != 0
    case let double as Double: return double != 0
    default: return nil
    }
}

/// Scripts and user-property bindings anywhere inside the object's own values (shallow: SceneScript lives on the
/// object's keys in Wallpaper Engine scenes; nested model values are attached transforms).
private func boundValues(in raw: [String: Any]) -> (scripts: Bool, userProperties: Bool) {
    var scripts = false
    var userProperties = false
    for (_, value) in raw {
        if let dict = value as? [String: Any] {
            if plainString(dict["script"]) != nil { scripts = true }
            if plainString(dict["user"]) != nil { userProperties = true }
        }
        if scripts && userProperties { break }
    }
    return (scripts, userProperties)
}

// MARK: vectors

/// "x y z" strings, arrays, or a single number meaning all components.
private func asVec3(_ value: Any?, height: Double? = nil, clamped: Bool = false) -> Vec3? {
    var x = 0.0, y = 0.0, z = 0.0
    var seen = false
    switch unwrap(value) {
    case let list as [Any]:
        seen = !list.isEmpty
        if list.count > 0 { x = plainDouble(list[0]) ?? 0 }
        if list.count > 1 { y = plainDouble(list[1]) ?? 0 }
        if list.count > 2 { z = plainDouble(list[2]) ?? 0 }
    case let single as String:
        let parts = single.split(separator: " ", omittingEmptySubsequences: true).compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        seen = !parts.isEmpty
        if parts.count > 0 { x = parts[0] }
        if parts.count > 1 { y = parts[1] }
        if parts.count > 2 { z = parts[2] }
    case let number as Double:
        seen = true
        x = number; y = number; z = number
    case let number as Int:
        seen = true
        x = Double(number); y = Double(number); z = Double(number)
    default: return nil
    }
    guard seen else { return nil }
    if clamped {
        let clamp = { (value: Double) in min(1, max(0, value)) }
        x = clamp(x); y = clamp(y); z = clamp(z)
    }
    if let height { y = height - y }
    return Vec3(x, y, z)
}

/// "w h" sizes and "x y" depths. No y flip: a size is a size.
private func asVec2(_ value: Any?) -> Vec2? {
    switch unwrap(value) {
    case let list as [Any]:
        guard let x = plainDouble(list.first) else { return nil }
        let y = list.count > 1 ? plainDouble(list[1]) : x
        return Vec2(x, y ?? x)
    case let single as String:
        let parts = single.split(separator: " ", omittingEmptySubsequences: true).compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard !parts.isEmpty else { return nil }
        return Vec2(parts[0], parts.count > 1 ? parts[1] : parts[0])
    case let number as Double:
        return Vec2(number, number)
    case let number as Int:
        return Vec2(Double(number), Double(number))
    default: return nil
    }
}

private func asColor(_ value: Any?) -> Vec3? { asVec3(value, clamped: true) }

// MARK: small helpers

extension ImageLayer {
    var hasVisibleEffect: Bool { effects.contains { $0.visible } }
}

func withoutBOM(_ data: Data) -> Data {
    var copy = data
    if copy.starts(with: [0xEF, 0xBB, 0xBF]) { copy.removeFirst(3) }
    return copy
}

/// No leading "/", no empty segments.
func cleanPath(_ raw: String?) -> String? {
    guard var path = raw else { return nil }
    while path.hasPrefix("/") { path.removeFirst() }
    while path.hasSuffix("/") { path.removeLast() }
    return path.isEmpty ? nil : path
}
