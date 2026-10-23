# Live Wallpaper

<img src="assets/logos/app-icon.svg" width="128" alt="">

A macOS app that plays videos and Wallpaper Engine scenes as a desktop wallpaper, can rotate through several wallpapers on a timer, and can play a video on the lock screen on macOS 26 or later. Wallpapers can come from your Mac or from the Steam Workshop for Wallpaper Engine.

Live Wallpaper is split into two processes:

- **LiveWallpaper** (Settings): a SwiftUI window for the library, scene settings, rotation, Steam sign-in and Workshop downloads. It plays nothing; during normal operation the service is the only writer of `state.json`, and Settings reads state and sends commands to the service.
- **LiveWallpaperService**: a nested AppKit background app with a menu bar item. It owns playback, the lock screen, rotation timers, the Unix socket and `state.json`. It keeps running when the Settings window closes.

The scene renderer is linked into `LiveWallpaperService`; it is not a separate scene-host process.

## Install

1. Download `LiveWallpaper-<version>.dmg` from the [Releases](../../releases) page. Optional: check it with `shasum -a 256 -c LiveWallpaper-<version>.dmg.sha256` in the same folder.
2. Open the DMG and drag **LiveWallpaper** onto the **Applications** shortcut.
3. First launch. The app is signed ad hoc and **not notarized** (there is no paid Apple Developer account behind this project), so macOS blocks a downloaded copy the first time. Do one of these once:
   - Try to open it, then go to **System Settings > Privacy & Security**, scroll to the message about "LiveWallpaper", and press **Open Anyway**.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/LiveWallpaper.app` (this also covers the nested service).
4. macOS may ask for access to your Desktop, Documents or Downloads folder, once for the Settings app and once for the background service (the service is what reads your videos and scenes).


## Usage

- Add videos by dropping them on the window or with Add Videos (⌘O). The first item is selected automatically.
- The preview shows the selected item, muted and looping.
- **Set as Desktop**, **Set as Lock Screen** or **Set as Both** assigns the selected item. Scenes can only be used on the Desktop; the lock screen needs a video.
- Rotation cycles through the playlist, or the library when no playlist is set, in list order. Set how often it switches (minimum 5 seconds). Rotation needs at least two wallpapers.
- **Same for both** (on by default) shares the selection and rotation settings between Desktop and Lock Screen. Turn it off to configure them separately.
- **Start Wallpaper** (⌘↩) starts the service if needed and begins playback. **Stop Wallpaper** ends playback and restores your original wallpapers.
- The service's menu bar item offers Open Settings, Start/Stop, Pause/Resume, Next Desktop Wallpaper, Next Lock Screen Wallpaper, Mute and Quit.
- Closing the Settings window quits Settings; the service keeps playing. Choosing Quit Wallpaper restores Apple's wallpapers and stops the service.

Everything the app installs stays in `~/Library/Application Support/LiveWallpaper/` and `~/Library/Caches/LiveWallpaperSteam/`. Remove the app and those folders to uninstall; choose **Quit Wallpaper** in the menu bar first so Apple's original wallpapers are restored.

## Requirements

- macOS 15 or later on Apple silicon.
- Live lock-screen video on macOS 26 or later. On macOS 15 the lock screen uses a still frame of the current video instead.
- To build from source: macOS 26 with Xcode 26 or matching Command Line Tools, and Rust stable (rustup). No Homebrew libraries are needed.

Release builds are arm64. `UNIVERSAL=1 ./build.sh` adds an x86_64 slice (it needs `rustup target add x86_64-apple-darwin`).

## Build and run

```sh
./build.sh
open build/LiveWallpaper.app
```

`build.sh` first runs `scripts/build-scene-renderer.sh`, which builds the scene renderer (`SceneRenderer/target/release/libscene_renderer.a`) and regenerates its UniFFI Swift bindings in `Sources/SceneBridge`. It then builds the two Swift products and assembles `build/LiveWallpaper.app` with `LiveWallpaperService.app` nested at `Contents/Library/LoginItems/`, and signs both ad hoc.

Run the app through the `.app` bundle. `swift run` does not work, because both products need their `Info.plist`.

Useful options:

- `CONFIG=debug ./build.sh` builds a debug variant.
- `VERSION=1.2.3 BUILD_NUMBER=45 ./build.sh` stamps a version into both bundles.
- `swift test` runs the Core and SceneFormat tests after the renderer has been built.

The build checks that Settings never links the old scene engine and that the service never links SwiftUI or the old in-repo scene engine. The service does link Metal and `SceneBridge` for scenes.

`scripts/make-dmg.sh build/LiveWallpaper.app 1.2.3` packs the app into `dist/LiveWallpaper-1.2.3.dmg` with an Applications shortcut and a SHA-256 file. Pushing a tag such as `v1.2.3` runs the `release` workflow on a macOS 26 runner and attaches the DMG to a GitHub Release.



## Architecture

Live Wallpaper has two processes: the SwiftUI Settings app and the nested background service. The service owns playback, the lock screen, `state.json` and the Unix socket. Settings talks to it over that socket and never imports `SceneBridge`. The Rust scene renderer is statically linked into the service, not a separate process.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the combined process, class, IPC and Rust bridge diagram, state ownership, scene-option mapping and build details.
