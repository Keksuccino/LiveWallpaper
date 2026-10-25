// swift-tools-version: 6.2
import PackageDescription

// Targets, one bundle (see build.sh):
//   Core                    (library)    settings model, state file, XPC/socket messages; no SwiftUI/AppKit
//   SceneFormat             (library)    scene package, texture and scene.json parsing; Foundation only
//   SceneRendererFFI/SceneBridge         Rust + Metal scene renderer (SceneRenderer/, built by scripts/build-scene-renderer.sh)
//   WallpaperMageService    (executable) background service: menu bar, playback, lock screen, socket server
//   WallpaperMage           (executable) settings app, SwiftUI; Steam sign-in and Workshop downloads
// Every target is built for macOS 26 with the macOS 26 SDK (build.sh and CI pin the SDK via scripts/macos-sdk.sh).
// Swift 5 language mode for every target (no Swift 6 strict concurrency checking).
let package = Package(
    name: "WallpaperMage",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "SceneFormat", targets: ["SceneFormat"]),
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .target(
            name: "SceneFormat",
            path: "Sources/SceneFormat"
        ),
        // Our own renderer (SceneRenderer/, a Rust library that draws scenes with Metal), via uniffi.
        // Build the static lib and regenerate these sources with scripts/build-scene-renderer.sh.
        .systemLibrary(
            name: "SceneRendererFFI",
            path: "Sources/SceneBridge/FFI"
        ),
        .target(
            name: "SceneBridge",
            dependencies: ["SceneRendererFFI"],
            path: "Sources/SceneBridge",
            exclude: ["FFI"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", Context.packageDirectory + "/SceneRenderer/target/release",
                    "-lscene_renderer",
                ]),
                .linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"), .linkedFramework("CoreText"), .linkedFramework("Foundation"),
                .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
            ]
        ),
        // Background service: the only writer of state.json, plays wallpapers, XPC to the UI. AppKit only.
        .executableTarget(
            name: "WallpaperMageService",
            dependencies: ["Core", "SceneBridge"],
            path: "Sources/WallpaperMageService"
        ),
        .executableTarget(
            name: "WallpaperMage",
            dependencies: ["Core", "SceneFormat"],
            path: "Sources/WallpaperMage"
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
        // The Settings app's model (playlist editor sessions); never bootstrapped, so it talks to no service.
        .testTarget(
            name: "WallpaperMageTests",
            dependencies: ["WallpaperMage"],
            path: "Tests/WallpaperMageTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
