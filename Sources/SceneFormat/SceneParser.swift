import Foundation

// The analysis the library keeps about a scene (design size, shared-asset use) and the `scene.json` parsing it needs.
// Foundation only. The parser is TOLERANT: a missing or oddly typed field falls back to its default and never throws;
// only an unreadable file or a missing object list throws.

public struct SceneAnalysis: Equatable, Sendable {
    public static let revision = 1               // stored in SceneInfo.analysisRevision

    public var designWidth: Int
    public var designHeight: Int
    public var needsSharedAssets: Bool

    public init(designWidth: Int = 1920, designHeight: Int = 1080, needsSharedAssets: Bool = false) {
        self.designWidth = designWidth
        self.designHeight = designHeight
        self.needsSharedAssets = needsSharedAssets
    }
}

public enum SceneLoader {
    /// Opens the `.pkg` and analyses the `scene.json` inside. `sharedAssets` is the folder of Wallpaper Engine's shared
    /// assets (AppPaths.sharedAssetsDirectory) when present.
    public static func analyze(packageAt url: URL, sharedAssets: URL?) throws -> SceneAnalysis {
        let archive = try PKGArchive(contentsOf: url)
        let json = try archive.data(at: try pathForSceneJSON(in: archive))
        return try analyze(sceneJSON: json, files: archive, sharedAssets: sharedAssets)
    }

    /// Same for an unpacked folder that contains `scene.json`.
    public static func analyze(directory url: URL, sharedAssets: URL?) throws -> SceneAnalysis {
        let source = DirectorySource(root: url)
        guard source.fileExists("scene.json") else { throw SceneFormatError.missingFile("scene.json") }
        return try analyze(sceneJSON: try source.data(at: "scene.json"), files: source, sharedAssets: sharedAssets)
    }

    /// Resolves the scene's paths against its own files layered over the shared assets.
    private static func analyze(sceneJSON: Data, files: SceneFileSource, sharedAssets: URL?) throws -> SceneAnalysis {
        let layered = LayeredSource(primary: files, fallback: sharedAssets.map { DirectorySource(root: $0) })
        return SceneAnalyzer.analyze(document: try parseDocument(sceneJSON: sceneJSON, files: layered), files: layered)
    }

    /// Parses `scene.json` bytes (UTF-8, BOM tolerated) against `files` (used to resolve model -> material ->
    /// texture paths and to check that referenced files exist).
    static func parseDocument(sceneJSON: Data, files: SceneFileSource) throws -> SceneDocument {
        try SceneDocumentParser.parse(json: withoutBOM(sceneJSON), files: files)
    }

    /// `scene.json`; some scenes pack it under a different case or inside a folder prefix.
    static func pathForSceneJSON(in files: SceneFileSource) throws -> String {
        for candidate in ["scene.json", "Scene.json", "SCENE.JSON"] where files.fileExists(candidate) {
            return candidate
        }
        for path in files.allPaths() where path.lowercased().hasSuffix("scene.json") { return path }
        throw SceneFormatError.missingFile("scene.json")
    }
}

enum SceneAnalyzer {
    /// Pure and cheap: it checks where the textures are, never reads them.
    static func analyze(document: SceneDocument, files: SceneFileSource) -> SceneAnalysis {
        SceneAnalysis(designWidth: Int(document.designWidth), designHeight: Int(document.designHeight),
                      needsSharedAssets: document.imageLayers.contains { reliesOnSharedAssets($0, files: files) })
    }

    /// A shown layer whose texture could not be found or is not in the scene's own files, or a hidden one whose texture
    /// only the shared assets have.
    private static func reliesOnSharedAssets(_ layer: ImageLayer, files: SceneFileSource) -> Bool {
        guard let path = layer.texturePath else { return layer.shown }
        return layer.shown ? !LayeredPathProbe.inPrimary(files, path: path)
                           : LayeredPathProbe.onlyInFallback(files, path: path)
    }
}

/// Distinguishes "the scene has its own copy" from "it references the shared assets".
enum LayeredPathProbe {
    static func inPrimary(_ source: SceneFileSource, path: String) -> Bool {
        if let layered = source as? LayeredSource { return layered.primary.fileExists(path) }
        return source.fileExists(path)
    }

    static func onlyInFallback(_ source: SceneFileSource, path: String) -> Bool {
        guard let layered = source as? LayeredSource, let fallback = layered.fallback else { return false }
        return fallback.fileExists(path) && !layered.primary.fileExists(path)
    }
}

// MARK: - The document parser (tolerant JSON)

private enum SceneDocumentParser {
    static let maxObjects = 20_000

    static func parse(json: Data, files: SceneFileSource) throws -> SceneDocument {
        guard let root = (try? JSONSerialization.jsonObject(with: json, options: [.allowFragments])) as? [String: Any]
        else {
            throw SceneFormatError.invalid("scene.json is not valid JSON")
        }
        guard let objects = root["objects"] as? [Any] else {
            throw SceneFormatError.invalid("scene.json has no object list")
        }
        guard objects.count <= maxObjects else {
            throw SceneFormatError.invalid("too many objects (\(objects.count))")
        }

        var document = SceneDocument()
        if let projection = (root["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Any] {
            document.designWidth = plainDouble(projection["width"]) ?? document.designWidth
            document.designHeight = plainDouble(projection["height"]) ?? document.designHeight
        }
        document.imageLayers = objects.compactMap { value in
            guard let object = value as? [String: Any], let model = object["image"] else { return nil }
            let shown = (plainBool(object["visible"]) ?? true) && (plainDouble(object["alpha"]) ?? 1) > 0
            return ImageLayer(shown: shown, texturePath: texturePath(ofModel: model, files: files))
        }
        return document
    }

    /// model -> material -> the first texture of its first pass.
    private static func texturePath(ofModel value: Any, files: SceneFileSource) -> String? {
        guard let modelPath = cleanPath(plainString(value)), files.fileExists(modelPath),
              let model = json(at: modelPath, files: files),
              let materialPath = cleanPath(plainString(model["material"])), files.fileExists(materialPath),
              let material = json(at: materialPath, files: files),
              let firstPass = (material["passes"] as? [Any])?.first as? [String: Any],
              let textures = firstPass["textures"] as? [Any] else { return nil }
        return resolveTexture(plainString(textures.first), files: files)
    }

    private static func json(at path: String, files: SceneFileSource) -> [String: Any]? {
        guard let data = try? files.data(at: path),
              let object = try? JSONSerialization.jsonObject(with: withoutBOM(data), options: [.allowFragments])
        else { return nil }
        return object as? [String: Any]
    }

    /// A texture entry ("foo") maps to `materials/foo.tex`; a path already given is kept if it exists.
    private static func resolveTexture(_ raw: String?, files: SceneFileSource) -> String? {
        guard let path = cleanPath(raw) else { return nil }
        let stem = (path as NSString).deletingPathExtension
        let candidates = [path, "materials/\(path)", "materials/\(stem).tex"]
        return candidates.first { files.fileExists($0) }
    }
}

// MARK: scalar reading

/// A value as written, or the `value` inside one of Wallpaper Engine's bound-value wrappers
/// (`{ "value": v, "user": "..." }`, `{ "value": v, "script": "..." }`).
private func unwrap(_ value: Any?) -> Any? {
    if let bound = value as? [String: Any], let plain = bound["value"] { return plain }
    return value
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

// MARK: small helpers

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
