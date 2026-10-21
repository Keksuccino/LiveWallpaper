# RenderBridge integration notes

`import RenderBridge` gives you WallpaperMachine's renderer (Rust + C++ open-wallpaper-engine,
`RenderService/`, see `RenderService/SOURCE.txt`) through uniffi. Rebuild with
`scripts/build-render-service.sh` (cargo + bindgen), then `swift build`.
Everything below is taken from WallpaperMachine's `App/` (BridgeStore.swift, ClientPaths.swift,
BridgeEnvironment.swift, AppDelegate.swift) and the Rust API (`crates/bridge/src/api/mod.rs`),
and the scene flow was run end to end on this Mac on 2026-10-22 (first frame in ~5 s, `native_metal` backend).

## The object

One `WallpaperBridge` per process: `let bridge = try WallpaperBridge()`. It owns the engine, the
windows on every display, persisted config and logs. Every call is `async throws` (except
`emitGuiLog`, `logFolderPath`, `clearLogs`, `beginHostLoadLog`, `webAudioSpectrum`,
`currentSystemMediaState`, `resamplePowerSource`); calls are serialised by an actor inside, so you
can call from any task. WallpaperMachine calls it from `@MainActor` code and keeps the main run loop
running (AppKit app): the engine creates its borderless desktop-level `NSWindow`/`CAMetalLayer` by
dispatching to the main thread, so **the main thread must be free and running a run loop / the main
dispatch queue** (an `NSApplication`, or top-level `await` in a CLI). Never block the main thread
waiting on a bridge call.

### Environment, set with `setenv` BEFORE `WallpaperBridge()` (paths.rs reads them at each use)

| Variable | Meaning | Default if unset |
|---|---|---|
| `WALLPAPER_MACHINE_SUPPORT_ROOT` | bridge's own state: `config.toml`, `wallpapers/<id>.json` (per-wallpaper options), `load-journal.json`, `shader-cache/`, `Logs/` | `~/Library/Application Support/app.wallpapermachine` |
| `WALLPAPER_MACHINE_LIBRARY_ROOT` | library: every direct subfolder that has a `project.json` is a wallpaper, id = folder name | Steam workshop `.../steamapps/workshop/content/431960` |
| `WALLPAPER_MACHINE_ASSETS_ROOT` | Wallpaper Engine shared `assets` folder itself (contains `shaders/`, `materials/`, ...) | Steam `.../common/wallpaper_engine/assets` |
| `WALLPAPER_MACHINE_USER_ASSETS_ROOT` | copies of files the user picks for file/folder properties | `$SUPPORT_ROOT/UserAssets` |
| `WALLPAPER_MACHINE_BUILD` | build stamp; when it changes the load journal releases crash-held wallpapers | optional |
| `VK_ICD_FILENAMES` | MoltenVK ICD for the Vulkan ("compatibility") scene path | WM sets it to a bundled `MoltenVK_icd.json`; in dev use `/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json` |

There is no `WALLPAPER_MACHINE_HOME` in the renderer; that one is only read by WM's Swift
`ClientPaths` to compute the others.

### For this app

```
SUPPORT_ROOT     = ~/Library/Application Support/LiveWallpaper/RenderService   (new subfolder: keeps
                   config.toml / wallpapers/ / Logs/ / shader-cache/ out of our own files)
LIBRARY_ROOT     = ~/Library/Application Support/LiveWallpaper/Library         (already the right layout:
                   Library/<id>/project.json + scene.pkg)
ASSETS_ROOT      = ~/Library/Application Support/LiveWallpaper/WallpaperEngineAssets
USER_ASSETS_ROOT = ~/Library/Application Support/LiveWallpaper/RenderService/UserAssets
```

The library is only scanned/read (`library/scanner.rs`); the bridge does not write into item folders.
WM checks before applying a scene that the assets folder has `shaders/genericimage2.vert`,
`shaders/genericimage2.frag`, `materials/util/effectpassthrough.json` (non-empty) and shows an error
otherwise; do the same. `config.toml` is created and owned by the bridge; do not hand-write it.
After adding/removing library folders call `refreshLibrary()`.

## Show one scene on one display (BridgeStore.performActivation)

1. `try await bridge.bootstrap()` once after creation (scans displays + library, loads config, and
   **re-opens whatever was assigned last time**, from config.toml).
2. `let sel = try await bridge.selectWallpaper(id: id)` -> `sel.wallpaperOptions` (non-nil for that id).
   Check `options.supported`.
3. Pick the display row: `options.displayConfigurations` (`BridgeDisplayConfigRow.displayId`, `title`,
   `enabled`, `targetFps`, `maxFps`...). Display ids are the bridge's selector strings (the main one
   came back as `"primary"`); always take them from these rows (or `settingsSnapshot().displays`),
   never build them from `CGDirectDisplayID`.
4. `try await bridge.setDisplayConfigEnabled(wallpaperId: id, displayId: d, enabled: true)` (draft).
5. `let b = try await bridge.applyWallpaperOptions(wallpaperId: id, userInitiated: true)` - commits
   the draft, saves it, opens the scene. WM then requires `b.wallpaperOptions.dirty == false` and
   that `allSnapshots().monitorInformation.rows` has a row `displayId == d, wallpaperId == id`.
   `userInitiated: true` also lifts a crash-loop hold; pass false for automatic rotation.
   On error WM calls `allSnapshots()` to resync, and re-sets the previous `enabled` value.

`monitorInformation.rows` only lists displays that currently have a wallpaper (it was empty before
step 5). `app.activeWallpaperIds`, `app.playbackState`, `app.errors`, `app.heldWallpaperIds` report status.

### Other controls (all `async throws`)

| Want | Call | Notes |
|---|---|---|
| stop on a display | `ejectWallpaperFromDisplay(displayId:wallpaperId:)` | saved; the display shows nothing |
| pause / resume all | `pauseAll()` / `playAll()` | global, not per display |
| hide all without unloading | `setPresentationSuspended(suspended:)` / `setDisplayPresentationSuspended(displayId:suspended:)` | |
| unload everything (e.g. low power) | `setPresentationUnloaded(unloaded:)` | |
| fps on one display | `setTargetFps(wallpaperId:displayId:fps:)` | live + saved; clamped to display refresh |
| global fps cap | `setFrameRateCap(cap: UInt32?)` | nil = none |
| scaling | `setScalingMode(wallpaperId:displayId:mode:)` `.none/.stretch/.match/.fill/.matchBlurred` | live + saved |
| zoom | `editScalingFactor(wallpaperId:displayId:factor:)` | draft (live preview); then `applyWallpaperOptions` |
| pan | `setDisplayPosition(wallpaperId:displayId:panX:panY:)` 0...1 | live + saved |
| user property | `editProperty(wallpaperId:propertyId:value: BridgePropertyValue)` then `applyWallpaperOptions` | draft; `.bool/.number/.string/.colorRgb/.empty`; ids from `options.properties`; `previewWallpaperProperties` shows unsaved edits live; `cancelWallpaperOptions` drops the draft |
| mute / volume | `setMuted(wallpaperId:muted:)`, `setVolume(wallpaperId:volume:)` | live + saved; `setAudioSuppressed` mutes all |
| renderer | `setSceneRenderer(mode: "native_metal_preferred" | "compatibility")` | default native Metal where the scene allows, else Vulkan/MoltenVK |
| displays changed | `refreshDisplays()` | WM calls it on screen-parameter changes |
| quit | `try await bridge.shutdown()` | closes scenes; call before exit |

## Video files

Yes, through the same flow. A video is a library folder whose `project.json` is
`{"type": "video", "file": "<name>.mp4", "title": "..."}` with the file beside it (WM checks the
file is a readable, non-empty regular file before applying). Then steps 2-5 as for a scene.
Keep `setVideoBackend(mode: "compatibility")` (the default in a fresh config.toml): the scene engine
decodes it with FFmpeg (mwe-ffmpeg, VideoToolbox enabled) and draws it itself. `"native_preferred"`
instead hands eligible videos to the *host* (WM's `NativeVideoWallpaperHost`, AVFoundation, via
`nativeVideoWallpapers()` + `reportHostWallpaperStartup` / `rejectNativeVideo`); that host is not
ported here, so do not enable it. (Web wallpapers are likewise host-rendered: `webWallpapers()`.)
Not yet tested here, see docs/TESTS-TODO.md.

## Minimal Swift

```swift
import Foundation
import RenderBridge

let base = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LiveWallpaper")
setenv("WALLPAPER_MACHINE_SUPPORT_ROOT", base.appendingPathComponent("RenderService").path, 1)
setenv("WALLPAPER_MACHINE_USER_ASSETS_ROOT", base.appendingPathComponent("RenderService/UserAssets").path, 1)
setenv("WALLPAPER_MACHINE_LIBRARY_ROOT", base.appendingPathComponent("Library").path, 1)
setenv("WALLPAPER_MACHINE_ASSETS_ROOT", base.appendingPathComponent("WallpaperEngineAssets").path, 1)
if ProcessInfo.processInfo.environment["VK_ICD_FILENAMES"] == nil {
    setenv("VK_ICD_FILENAMES", "/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json", 1) // bundle it for release
}

let bridge = try WallpaperBridge()          // main thread must keep running (AppKit app / top-level await)
_ = try await bridge.bootstrap()
let id = "3695791724"                        // folder name under Library/
guard let options = try await bridge.selectWallpaper(id: id).wallpaperOptions, options.supported,
      let display = options.displayConfigurations.first?.displayId else { fatalError("cannot play \(id)") }
_ = try await bridge.setDisplayConfigEnabled(wallpaperId: id, displayId: display, enabled: true)
_ = try await bridge.applyWallpaperOptions(wallpaperId: id, userInitiated: true)
// later: _ = try await bridge.ejectWallpaperFromDisplay(displayId: display, wallpaperId: id)
//        try await bridge.shutdown()
```

## Linking / packaging

`Package.swift` targets: `WallpaperBridgeFFI` (system library, `Sources/RenderBridge/FFI`) and
`RenderBridge` (Swift, links `libwallpaper_bridge.a` + Homebrew dylibs + frameworks, rpaths to
/opt/homebrew). Add `"RenderBridge"` to an executable's dependencies. The binary then depends on
Homebrew dylibs at runtime (vulkan, lz4, freetype, mwe-ffmpeg, qjs, glslang, dav1d...); a
distributable .app must bundle them + MoltenVK + an ICD json (WM: `scripts/package.py`). The renderer
static lib is built for macOS 15.0 (`OWE_MACOSX_DEPLOYMENT_TARGET`) while the package says macOS 13,
so the linker warns and the host should require macOS 15 at runtime. A `swift build` of anything
that links RenderBridge needs `RenderService/target/release/libwallpaper_bridge.a` to exist (88 MB, built
by the script; `RenderService/target/` is gitignored).
