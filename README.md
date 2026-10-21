# Live Wallpaper

<img src="assets/logos/app-icon.svg" width="128" alt="">

A small macOS app that plays your own videos as a looping desktop wallpaper, can rotate through several of them on a timer, and plays a wallpaper on the lock screen too (macOS 26 or later). The desktop and the lock screen can show different wallpapers. Wallpapers can come from your Mac or from the Steam Workshop for Wallpaper Engine (videos now; scenes are being added, see "Scenes" below).

It is three apps in one bundle:

- **Live Wallpaper** (Settings): the window where you manage your library, rotation and Steam downloads. Open and close it whenever you like.
- **Live Wallpaper Agent**: a tiny background app with a menu bar icon that actually plays the wallpaper. It keeps running when the Settings window is closed.
- **Live Wallpaper Scene Host**: a helper that the agent starts only while a Wallpaper Engine *scene* is the wallpaper (or has to be rendered for the lock screen) and that quits afterwards. It keeps the scene engine's memory out of the agent.

## Install

1. Download `LiveWallpaper-<version>.dmg` from the [Releases](../../releases) page. Optional: check it with `shasum -a 256 -c LiveWallpaper-<version>.dmg.sha256` in the same folder.
2. Open the DMG and drag **LiveWallpaper** onto the **Applications** shortcut.
3. First launch. The app is signed ad hoc and **not notarized** (there is no paid Apple Developer account behind this project), so macOS blocks a downloaded copy the first time. Do one of these once:
   - Try to open it, then go to **System Settings > Privacy & Security**, scroll to the message about "LiveWallpaper", and press **Open Anyway**.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/LiveWallpaper.app` (this also covers the two helper apps inside it).

   On macOS 14 and earlier, right-click > Open also works. As far as we know it no longer does on macOS 15 and later, which is why the steps above are the documented way.
4. macOS may ask for access to your Desktop, Documents or Downloads folder, once for the Settings app and once for the agent (the agent is what plays your videos).

Everything the app installs stays in `~/Library/Application Support/LiveWallpaper/` and `~/Library/Caches/LiveWallpaperSteam/`. Remove the app and those folders to uninstall; Quit Wallpaper in the menu bar first so Apple's original wallpapers are restored.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools with Swift 5.9 or later

## Build and run

```sh
./build.sh
open build/LiveWallpaper.app
```

Run the app through the `.app` bundle. `swift run` does not work, because both apps need their `Info.plist`.

`./build.sh` builds a release binary of each app, assembles `build/LiveWallpaper.app` with the agent and the scene host nested inside at `Contents/Library/LoginItems/`, and signs the helpers first and then the outer app, ad hoc. Use `CONFIG=debug ./build.sh` for a debug build, `UNIVERSAL=1 ./build.sh` for an arm64 + x86_64 binary and `VERSION=1.2.3 ./build.sh` to stamp a version into all three bundles. The build fails if the agent links SwiftUI, Metal or the scene engine, because the agent must stay small.

`scripts/make-dmg.sh build/LiveWallpaper.app 1.2.3` packs the app into `dist/LiveWallpaper-1.2.3.dmg` with an Applications shortcut and a SHA-256 file. Pushing a tag such as `v1.2.3` runs the `release` workflow, which does all of this on GitHub and attaches the DMG to a Release. Running that workflow by hand does a dry run and only uploads the DMG as a build artifact.

## Usage

- Add videos by dropping them on the window or with Add Videos (⌘O). The first video is selected automatically.
- The preview shows the selected video, muted and looping.
- Rotate wallpaper cycles through your videos in list order. Set how often it switches (minimum 5 seconds). Rotation needs at least two videos.
- Apply to chooses whether the video plays on the Desktop, the Lock Screen, or both. The Lock Screen needs a one-time setup, see below.
- Start Wallpaper (⌘↩) starts the agent if needed and begins playback. Stop Wallpaper ends it and restores your original wallpapers.
- The agent's menu bar icon offers Open Settings, Start/Stop, Pause/Resume, Next Video and Quit Wallpaper. Quitting the agent restores your original wallpapers and ends the background app. Closing the Settings window does not stop anything.

## Steam Workshop (Wallpaper Engine)

The Workshop tab downloads wallpapers from the Steam Workshop for Wallpaper Engine into your library. It uses Valve's official SteamCMD with **your own Steam account, which must own Wallpaper Engine**. Nothing is downloaded anonymously, through shared accounts or through third-party download services, and nothing from Wallpaper Engine is bundled with or redistributed by this app.

Steam Setup tab (in development; the phase-2 flow, `brew install --cask steamcmd` plus a one-time Terminal sign-in, still works until it lands):

1. **Install the Steam tools.** The app downloads SteamCMD from Valve into its own folder the first time you ask. It is never bundled in the app because Valve's license does not allow redistributing it. The app checks which processor the tool is built for and only mentions Rosetta if the tool is Intel-only and Rosetta is missing.
2. **Sign in.** Enter your Steam username, password and, if asked, the Steam Guard code in the app. They are handed to SteamCMD through a pseudo-terminal and are not stored, logged or put on a command line. SteamCMD keeps its own login token on your Mac; **Sign out** removes it.
3. **Check ownership.** The app confirms the account owns Wallpaper Engine.

Click a Workshop result to see its preview (animated previews play), tags, size and description, then Download. Video wallpapers (MP4, MOV, M4V) play directly. Scene wallpapers need the scene engine, see below. Web and application wallpapers, and video formats macOS cannot decode, are shown as unsupported and are never converted. Workshop items belong to their creators: they are downloaded for your personal use on this Mac, through your own account. Do not redistribute them. This app is not affiliated with Valve or Wallpaper Engine.

## Scenes (in development)

Many Workshop wallpapers are *scenes*: layered images with effects, particles and sound. The app has its own scene engine (MIT, written for this project) that reads a scene's package and draws it with Metal. The first milestone covers image layers, blend modes and camera parallax; every scene gets a badge: **Full** (everything it uses is supported), **Partial** (it plays, but some effects, particles, sounds or scripts are ignored) or **Preview only** (the preview image is shown). Particles, effects, audio and scripts come in later milestones. Some scenes also need Wallpaper Engine's shared asset files, which the app can fetch with your own account in Steam Setup (optional).

On the desktop a scene plays live, in the scene host helper. For the lock screen macOS can only play a video, so the app renders the scene offline into a looping video at your screen's resolution (about 20 seconds, with a cross-fade at the loop point), caches it in the item's folder, and installs it like any other lock screen video. The Library shows "Rendering for lock screen" while that runs. If your screen resolution changes it is rendered again.

## Desktop, lock screen and sound

Each item in the Library has **Set as Desktop**, **Set as Lock Screen** and **Set as Both**, and shows a badge for where it is used. "Same for both" in Settings (on by default) keeps one wallpaper, one rotation list and one interval for both; turn it off to give the lock screen its own. **Mute** (on by default) is in Settings and in the agent's menu bar menu; the lock screen never has sound.

## Lock screen

On macOS 26 (Tahoe) and later the lock screen plays your video. macOS has no public API for that, so the agent borrows the slot of an Apple Aerial wallpaper: Apple stores downloaded Aerial videos as `.mov` files in `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`, and the agent swaps your video into all of them. The system then plays it on the lock screen as if it were the Aerial. No admin rights or SIP changes are needed, and everything stays inside your user folder.

One-time setup: open System Settings > Wallpaper, pick any Apple Aerial, wait for it to download and leave it selected. Without a downloaded Aerial the agent reports an error instead of applying the lock screen.

The agent can't tell which downloaded Aerial the lock screen plays, and each display or Space can use a different one, so it replaces every downloaded Aerial with your video. The extra copies are hard links, so they normally take no additional disk space. Apple's Aerial screen saver shows your video too while the agent runs.

- Apple's original files are moved to `~/Library/Application Support/LiveWallpaper/Backups/` before the first swap. Stop and Quit Wallpaper move them back. After a crash they are moved back the next time the agent launches without resuming playback, or on Stop.
- Your video is converted without audio and repeated end to end until it lasts about 3 minutes, because the renderer misbehaves when a video ends. The converted file normally keeps the source encoding and can be large, since the repeats add up.
- Rotation updates the lock screen at most every 30 seconds, always ending on the latest video. The desktop switches at your chosen interval.
- The agent restarts the wallpaper renderer each time you unlock the screen, which keeps later lock screens from going black. It never does this while the screen is locked.
- The first lock after switching videos may briefly show the previous frame.
- The FileVault login screen shown after a cold boot stays static, because it appears before your session exists.
- A macOS update may put Apple's own Aerial back. Stop and start the wallpaper to install your video again.
- On macOS 13 to 15 the lock screen gets a still frame of the current video as the system wallpaper instead, which replaces your wallpaper while the agent runs and is restored on Stop or Quit.

## Upgrading

From version 2 (separate agent): replace the app. The library file is upgraded to the new format on the first launch of the new Settings app (a copy of the old one stays next to it as `state.v1-backup.json`); nothing in your library changes. Quit Wallpaper in the menu bar before replacing the app so an older agent does not keep running.

From the single-app version (phase 1): quit the old Live Wallpaper app first (its Quit restores your Aerials), then replace it with this build. The first launch of the new Settings app imports your old library once. Do not run the old and new versions together: the new agent refuses to start while an old copy is running.

## Files

Everything lives in `~/Library/Application Support/LiveWallpaper/`: `state.json` (library and settings, written by Settings; a copy of an older file is kept as `state.v1-backup.json`), `agent.json` (what the agent needs to restore your wallpapers), `Library/<id>/` (a downloaded Workshop item with its preview and, for scenes, the rendered lock screen video), `Backups/` and `Stills/` (lock screen), `SteamCMD/` and `SteamHome/` (the Steam tool and its login token, once the Steam wizard is in), and optionally `WallpaperEngineAssets/`. Steam downloads are staged in `~/Library/Caches/LiveWallpaperSteam/`.

## Permissions and Gatekeeper

The apps are signed ad hoc, not notarized (see Install above). If macOS refuses to open a build you downloaded or copied, clear the quarantine flag on the whole bundle (this includes both nested helpers):

```sh
xattr -dr com.apple.quarantine /Applications/LiveWallpaper.app
```

Because the signature is ad hoc, macOS may ask again for access to folders such as Desktop, Documents, Downloads or removable volumes after each rebuild, once for the Settings app and once for the agent (the agent is what plays your videos).

## Performance

Prefer H.264 or HEVC videos at or near your screen resolution. Higher resolutions and exotic codecs use more CPU and battery. The agent is AppKit only and keeps its memory low; playback pauses automatically when the desktop is fully covered and while the display sleeps. A playing scene costs far more memory than a video (it lives in the scene host, which quits when no scene is active), is limited to 30 frames per second on battery, and releases its GPU memory while the desktop is covered.

## Credits

This app is an independent implementation and is not affiliated with Apple, Valve or Wallpaper Engine. Ideas and format knowledge came from these projects; no code is copied from them:

- [vlzuiev/animated](https://github.com/vlzuiev/animated) (MIT): the lock screen technique of swapping a converted video into an Apple Aerial slot.
- [MozeeB/OpenWallpaperMac](https://github.com/MozeeB/OpenWallpaperMac) (MIT): reference for scene wallpaper structure on macOS.
- [Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) (GPL-3.0), [deepratna-awale/open-wallpaper-engine-mac](https://github.com/deepratna-awale/open-wallpaper-engine-mac) (GPL-3.0), [Leshao-Zhang/WallpaperMachine](https://github.com/Leshao-Zhang/WallpaperMachine) and [ayasa520/wallpaper-scene-renderer](https://github.com/ayasa520/wallpaper-scene-renderer): existing scene renderers studied for how Wallpaper Engine scenes work.
- [kageroumado/phosphene](https://github.com/kageroumado/phosphene) (MIT): considered as an alternative lock screen approach.
- [notscuffed/repkg](https://github.com/notscuffed/repkg) (MIT): read for the layout of the `.pkg` and `.tex` formats; no code is copied.
- The Wallpaper Engine designer documentation (docs.wallpaperengine.io) for what scene features exist.

The scene engine in this repository is original MIT code. Nothing from the GPL projects above was copied into it.

## Possible future extras

- Launch at login (the agent already sits where `SMAppService.loginItem` expects it)
- Shuffle order
- Different videos per screen
- App Sandbox support (needs security-scoped bookmarks for the chosen videos)
