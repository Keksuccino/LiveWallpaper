// swift-tools-version: 5.9
import PackageDescription

// Targets, one bundle (see build.sh):
//   Core                    (library)    shared model, state files, IPC; no SwiftUI/AppKit/Combine/Metal
//   SceneFormat             (library)    scene package, texture and scene.json parsing + support analysis; Foundation only
//   SceneEngine             (library)    Metal scene renderer + offline lock screen video writer; host only
//   LiveWallpaperAgent      (executable) headless wallpaper player, AppKit only (must not link SwiftUI, Metal,
//                                        SceneEngine or SceneFormat: build.sh fails the build if it does)
//   LiveWallpaperSceneHost  (executable) helper app that plays scenes on the desktop and renders the lock screen loop
//   LiveWallpaper           (executable) Settings app, SwiftUI; also does Steam sign-in and Workshop downloads
// Deployment target stays macOS 13 for every target: nothing in the scene engine needs newer API (SPEC3.md 0).
let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .target(
            name: "SceneFormat",
            path: "Sources/SceneFormat"
        ),
        .target(
            name: "SceneEngine",
            dependencies: ["Core", "SceneFormat"],
            path: "Sources/SceneEngine"
        ),
        .executableTarget(
            name: "LiveWallpaperAgent",
            dependencies: ["Core"],
            path: "Sources/LiveWallpaperAgent"
        ),
        .executableTarget(
            name: "LiveWallpaperSceneHost",
            dependencies: ["Core", "SceneFormat", "SceneEngine"],
            path: "Sources/LiveWallpaperSceneHost"
        ),
        .executableTarget(
            name: "LiveWallpaper",
            dependencies: ["Core", "SceneFormat"],
            path: "Sources/LiveWallpaper"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "SceneFormatTests",
            dependencies: ["SceneFormat"],
            path: "Tests/SceneFormatTests"
        ),
    ]
)
