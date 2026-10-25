import Foundation

/// What a scene offers beyond its own user properties, which decides the wallpaper options Wallpaper Engine shows for
/// it: a volume when it has sound, the alignment options when it is a 2D scene, a mouse parallax switch when its
/// camera follows the pointer. The rules are Wallpaper Engine's.
public struct SceneFeatures: Equatable, Sendable {
    /// A 2D scene (`general.orthogonalprojection`); a 3D scene always covers the display.
    public var orthographic: Bool
    /// Some object plays sound (and is not a model).
    public var sound: Bool
    /// `general.cameraparallax` is on (as a plain value) with a mouse influence that is not zero.
    public var parallax: Bool

    public init(orthographic: Bool = true, sound: Bool = false, parallax: Bool = false) {
        self.orthographic = orthographic
        self.sound = sound
        self.parallax = parallax
    }

    /// The features of a parsed `scene.json`.
    public init(sceneJSON root: [String: Any]) {
        let general = root["general"] as? [String: Any] ?? [:]
        orthographic = general["orthogonalprojection"] is [String: Any]
        // Only literals count: not a value bound to a user property ({"user": ..., "value": ...}), and a boolean must be
        // a boolean and a number a number (NSNumber holds both).
        let isBool = { (n: NSNumber) in CFGetTypeID(n) == CFBooleanGetTypeID() }
        let enabled = (general["cameraparallax"] as? NSNumber).map { isBool($0) && $0.boolValue } == true
        let influence = (general["cameraparallaxmouseinfluence"] as? NSNumber).map { !isBool($0) && $0.doubleValue != 0 }
        parallax = enabled && influence == true
        let objects = root["objects"] as? [[String: Any]] ?? []
        sound = objects.contains { object in
            let model = object["model"] as? String
            let files = object["sound"] as? [Any]
            return (model ?? "").isEmpty && !(files ?? []).isEmpty
        }
    }

    /// The features of the scene at `path`: a scene package or a loose scene's `scene.json`. nil when it cannot be
    /// read.
    public static func read(scenePath path: URL) -> SceneFeatures? {
        let data: Data?
        if path.pathExtension.lowercased() == "pkg" {
            data = try? PKGArchive(contentsOf: path).data(at: "scene.json")
        } else {
            data = try? Data(contentsOf: path)
        }
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return SceneFeatures(sceneJSON: root)
    }
}
