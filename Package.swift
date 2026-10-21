// swift-tools-version: 5.9
import PackageDescription

// Targets, one bundle (see build.sh):
//   Core                    (library)    settings model, state file, XPC/socket messages; no SwiftUI/AppKit
//   SceneFormat             (library)    scene package, texture and scene.json parsing; Foundation only
//   WallpaperBridgeFFI/RenderBridge      Rust renderer (RenderService/, built by scripts/build-render-service.sh)
//   LiveWallpaperService    (executable) background service: menu bar, playback, lock screen, socket server
//   LiveWallpaper           (executable) settings app, SwiftUI; Steam sign-in and Workshop downloads
// Deployment target stays macOS 13 for every target: nothing in the scene engine needs newer API (SPEC3.md 0).
let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v13)],
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
        // WallpaperMachine's Rust/C++ renderer (RenderService/), via uniffi. Build the static lib and
        // regenerate these sources with scripts/build-render-service.sh first. See docs/render-bridge-notes.md.
        .systemLibrary(
            name: "WallpaperBridgeFFI",
            path: "Sources/RenderBridge/FFI"
        ),
        .target(
            name: "RenderBridge",
            dependencies: ["WallpaperBridgeFFI"],
            path: "Sources/RenderBridge",
            exclude: ["FFI"],
            // Same libraries as WallpaperMachine's project.yml (rendererLibraryPaths / rendererLinkerFlags).
            linkerSettings: [
                .unsafeFlags([
                    "-L", Context.packageDirectory + "/RenderService/target/release",
                    "-L", "/opt/homebrew/opt/mwe-ffmpeg/lib",
                    "-L", "/opt/homebrew/lib",
                    "-L", "/opt/homebrew/opt/quickjs-ng/lib",
                    "-L", "/opt/homebrew/opt/glslang/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/opt/mwe-ffmpeg/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/opt/quickjs-ng/lib",
                    "-lwallpaper_bridge", "-lc++", "-lvulkan", "-llz4", "-lfreetype",
                    "-lavformat", "-lavcodec", "-lavutil", "-lswresample", "-lavfilter", "-lavdevice", "-lswscale",
                    "-lqjs", "-lglslang", "-lSPIRV", "-lglslang-default-resource-limits", "-liconv",
                ]),
                .linkedFramework("Accelerate"), .linkedFramework("AppKit"), .linkedFramework("CoreAudio"),
                .linkedFramework("CoreData"), .linkedFramework("CoreFoundation"), .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"), .linkedFramework("CoreMedia"), .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"), .linkedFramework("Foundation"), .linkedFramework("IOSurface"),
                .linkedFramework("Metal"), .linkedFramework("OpenGL"), .linkedFramework("QuartzCore"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        // Background service: the only writer of state.json, plays wallpapers, XPC to the UI. AppKit only.
        .executableTarget(
            name: "LiveWallpaperService",
            dependencies: ["Core", "RenderBridge"],
            path: "Sources/LiveWallpaperService"
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
