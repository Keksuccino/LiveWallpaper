import Foundation
import Core
import SceneFormat

// Owner: STEAM. Imports a downloaded scene-type Workshop item into the library (SPEC3.md section 4.7): copies
// scene.pkg (or the loose scene files), project.json and the preview into Library/<id>/, runs the SceneFormat
// analyzer for the support badge and builds the VideoItem. Called by the import step of Workshop.swift when
// project.json says type "scene". The video import path is unchanged.

struct SceneImportInput {
    var workshopID: String
    var title: String
    var author: String?
    var tags: [String]
    var contentFolder: URL           // where steamcmd put the item (contains project.json and scene.pkg)
    var previewSource: URL?          // preview image already on disk (from the content folder), if any
}

enum SceneImporter {
    /// Throws WorkshopError.importFailed(detail) with nothing half-written (Library/<id>.partial is removed).
    /// The item's `scene` record is filled from SceneLoader's analysis; `path` is Library/<id>/scene.pkg.
    static func importScene(_ input: SceneImportInput) async throws -> VideoItem {
        throw WorkshopError.importFailed("Scene import is not implemented yet.")
    }

    /// Re-runs the analyzer for an already imported scene (after an engine update raised
    /// SceneAnalysis.revision or EngineCapabilities.current changed). Returns the item with a fresh `scene` record.
    static func reanalyze(_ item: VideoItem) -> VideoItem {
        item
    }
}
