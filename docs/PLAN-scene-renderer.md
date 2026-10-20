# Plan: scene player, per-target wallpapers, easier Steam login, releases

Branch: `feat-pkg-renderer` (from `main` at phase 2). Status: plan agreed, implementation not started.
Nothing below has been run on a Mac yet unless it says so; items marked **unverified** need a real test.

## Decisions (agreed)
- **Scenes play live on the desktop; the lock screen plays a pre-rendered video of the scene.** Our own engine renders the scene offline to a looping video, caches it, and the existing Aerial-swap path installs it. This is not an external `.pkg`-to-mp4 converter: it is the scene engine driven frame by frame.
- **Scene engine runs in a separate helper process** (`LiveWallpaperSceneHost`, a third nested helper app) that starts only when a scene is active and exits afterwards. The video agent stays small (about 16 MB measured); the helper may use hundreds of MB.
- **Our own engine, MIT.** Ideas and format knowledge come from the projects listed in the README credits; no code is copied from GPL projects.
- **Steam password is handled transiently inside the app** (passed to SteamCMD through a pseudo-terminal, never in argv, never stored). SteamCMD keeps only its own login token on the user's machine.
- **SteamCMD is downloaded by the app on first run, never bundled** (Valve's license restricts redistribution).
- **Repo is public, MIT, no Apple Developer account.** Releases are ad-hoc signed DMGs (see "Releases" for what users must do).
- Name stays `LiveWallpaper`. "Wallpaper Engine" appears only as a compatibility statement with a not-affiliated disclaimer.

## Order
1. **Schema v2** (desktop and lock wallpapers separate, mute). Everything else depends on it.
2. In parallel: Workshop preview UI, Steam login wizard, release pipeline, scene engine M0.
3. Scene engine M1 to M3, lock-screen render.

## 1. Schema v2: separate desktop and lock, mute
- `state.json` gets a `desktop` and a `lock` section, each with its own wallpaper or playlist, interval and current item. A "same for both" switch is on by default. v1 files migrate automatically. Add `muted` (default true).
- Agent: two independent channels (desktop windows; lock-screen install). Status messages report both current items. Commands take a target.
- UI: per item "Set as Desktop / Lock Screen / Both" plus role badges. A scene chosen for the lock screen shows "Rendering for lock screen..." until its video exists.
- Mute: toggle in Settings and the menu bar. When muted the agent can skip loading the audio track. The lock-screen file never has audio. Sound only while the desktop is visible.

## 2. Workshop preview on click
Clicking a result opens a detail pane: large preview (Workshop previews are often animated GIFs, so use an image view that animates), title, tags, size, description, Download. After download the pane shows the real video preview.

## 3. Steam login wizard
1. **Install Steam tools:** download SteamCMD from Valve on first run into the app's support folder. Detect the binary's architecture (`lipo -archs`) and only mention Rosetta if it is x86_64-only and Rosetta is missing. (The user reports SteamCMD running without a Rosetta prompt on Apple silicon; a native arm64 build is **unverified**.)
2. **Sign in:** username, password and Steam Guard fields in the app, fed to SteamCMD through a pty. Exact Steam Guard prompts and any QR/mobile-approval support are **unverified**: start with a short spike against a real account.
3. **Check ownership:** confirm the account owns Wallpaper Engine; clear message if not. Offer "Sign out" (removes the cached login).

## 4. Scene engine
Design rule from the start: the renderer is time-driven (`render(at: t)`), not only a display-link loop, so the same code serves live desktop playback and offline lock-screen rendering.

- **M0:** `.pkg` and `.tex` parsing, `scene.json` graph, image layers, blend modes, camera parallax. Preview-image fallback for anything unsupported.
- **M1:** common effects, then shader translation to Metal.
- **M2:** particles.
- **M3:** audio reactivity, SceneScript via JavaScriptCore, puppet animation, user properties.
- Each scene gets a support badge: full, partial, preview-only.
- **Assets:** scenes need Wallpaper Engine's shared resource files from a copy the user owns, fetched with the same SteamCMD flow. Which depot holds them is **unverified**.
- **Memory:** keep textures compressed on the GPU, cap frame rate (30 fps on battery), pause then release GPU resources when the desktop is covered, memory budget with eviction (for example 400 MB).
- **Lock-screen render:** offline render at screen resolution, 30 fps, HEVC via AVAssetWriter, run in the helper at low priority with progress in the UI. Loop length is the scene's own period if it has one, otherwise 20 to 30 seconds with a cross-fade at the seam (random particle scenes will not loop perfectly). Cached as `Library/<id>/lock-<width>x<height>.mov`, re-rendered if the screen resolution changes, then installed through the existing Aerial path (which already tiles to about 3 minutes).
- Optional later: a "light mode" that plays the pre-rendered video on the desktop too, trading parallax and interactivity for much lower RAM.

## 5. Releases
- Workflow on a version tag: build, assemble the bundle (agent and scene host nested), package a DMG with an Applications shortcut, attach it plus a checksum to a GitHub Release, inject the version from the tag.
- No Apple Developer account, so the app is ad-hoc signed and **not notarized**. On current macOS a downloaded copy is blocked on first open. As far as I know the right-click Open shortcut no longer works on macOS 15 and later: the user opens System Settings, Privacy & Security, and presses "Open Anyway" once (or runs `xattr -dr com.apple.quarantine` on the app). The README documents this with steps. A Homebrew tap cask can come later. Notarization removes the prompt but needs the paid account.

## Risks
- Scene fidelity will be partial; plan to iterate scene by scene.
- Private-framework-free, but the Aerial file swap depends on undocumented macOS behavior and may break on OS updates.
- Rosetta availability for Intel-only tools is time-limited by Apple (a limited version from macOS 28).
- Scene helper and lock render add a third process and GPU/disk load; measure with `footprint` and Instruments before shipping.

## Status (work paused)
Done on this branch: schema v2 and the scaffold (new state shape, scene host stub, release workflow, `docs/SPEC3-contracts.md` = the full contracts and per-worker checklists), and the Settings app side (role badges, Set as Desktop / Lock Screen / Both, same-for-both, per-target rotation, mute toggle, Workshop detail pane, 3-step Steam wizard screens).

Not done:
- Agent side (two channels, mute in the player, scene host hand-off, lock render install): partial work saved on branch `feat/agent` (WIP, unreviewed, never compiled).
- Steam side (SteamCMD installer, pty sign-in, ownership check, Wallpaper Engine assets, scene import): partial work saved on branch `feat/steam` (WIP, unreviewed, never compiled). Until it lands the wizard has nothing behind it.
- Scene engine (SceneFormat parsers, Metal renderer, scene host, offline lock-screen render): not started beyond the stubs.
- Merging, CI fix rounds, and the real-Mac tests (T1 to T17 in the spec).
Because the Settings UI now expects the new agent and Steam behavior, this branch is not releasable until those land.

## Status (phase 3 implementation)
- The two WIP branches (`feat/agent`, `feat/steam`) are merged into `feat-pkg-renderer` with `--no-ff` (review pending, both compiled clean).
- Scene engine M0 implemented on this Mac (Apple Swift 6.3.2, arm64): `.pkg` archives, LZ4/`.tex` decoding, `scene.json` parsing with the y-mirror coordinate convention (UNVERIFIED against real content), analyzer with fixed note order, Metal scene renderer (blend modes, parallax), the scene host (live windows, occlusion-aware pump, IPC), and the offline lock render (LoopPlan, HEVC/H.264 via AVAssetWriter, `.partial` then atomic move, preview fallback).
- `swift build` green with zero warnings. `swift test` CANNOT run here: only Command Line Tools are installed (no Xcode), and CLT ships no XCTest module. The first CI run failed in `swift test`: the .tex fixtures used length-prefixed magic strings where the format is null-terminated (spec 5.2), plus two wrong analyzer expectations (missing texture also sets noRenderableLayer; a v4 MP4 texture has imageFormat -1 + isVideoMp4 == 1). Fixed; rerun pending. Files: fixtures (PKG/TEX/LZ4/TEXS byte builders), PKG tests, TEX tests, scene parser/analyzer tests; `CoreTests` predates this.
- Still not done: running the tests, real-Mac comparison of the coordinate convention (task T10), the agent/steam review, and the real-Mac tests T1–T17.
