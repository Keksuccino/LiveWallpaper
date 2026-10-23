# Plan: finish the Rust + Metal scene renderer and replace RenderService

Audience: an engineering agent picking this up cold. Read this whole file before touching code.
Date written: 2026-10-22. Branch: `feat-lean-rust-metal-renderer`.

---

## Status, 2026-10-22 (end of the integration round)

Done: B1 puppets (pose, attachments), B2 particles (y-up simulation space fixed), B3 bloom, B4 text
(box-height scale, script-driven clock/date), B5 SceneScript on QuickJS, B6 sound objects
(AVAudioPlayer) and audio response (Core Audio process tap + FFT in the service, packed spectrum
uniforms), D1–D3 API and Swift service (battery/Low Power rules applied in Swift), D4 scene lock
screen (`LockSceneRecorder`, 10 s HEVC loop per screen size), D5 `RenderService/`,
`Sources/RenderBridge`, its scripts and docs deleted. Phase C skipped by the owner's choice.
Still open: B7 3D-only shaders (`gl_InstanceID`), B8 video textures, random sound playlists and
`mintime`/`maxtime` gaps, antialiasing setting, audio tap not yet checked on a playing Mac.

## 0. Why this exists

LiveWallpaper (MIT) plays Wallpaper Engine scenes on the macOS desktop. Today it does that with
`RenderService/`, a verbatim copy of WallpaperMachine's Rust/C++ renderer (GPL-2.0-only, Vulkan via
MoltenVK, FFmpeg, QuickJS, glslang ...). Two problems:

1. **License.** GPL-2.0 code is statically linked into an MIT app. Not allowed. It must go.
2. **Heat and memory.** It works, but uses about 1 GB and heats the Mac.

Replacement: `SceneRenderer/`, an original MIT crate (Rust + Metal via `objc2-metal`, shaders
translated with `naga`). It already renders image layers, effects and properties. This plan takes
it from "renders three test scenes" to "ships in the app, RenderService deleted".

### Hard rules
- **Take inspiration, never copy.** Ideas and format facts may come from other projects (list in
  the README credits). Copying code, identifiers, tables or comments is not allowed, from any
  project, MIT or GPL. Write each idea down in your own words, then implement it from that note.
  Do not open `RenderService/` source while writing new renderer code.
- **Log every inspired feature** in `SceneRenderer/NOTES.md` (idea, source, how we did it, how
  checked). A feature with no log row is not finished. Read that file's "Open provenance items"
  before any release step.
- **No quality loss** to save memory/heat: no lossy texture recompression, no lower default
  resolution. Reducing work the viewer cannot see (offscreen, hidden, unchanged, sub-pixel) is fine.
- **Keep it lean.** No new dependency for a few lines. Each dependency added needs a one-line reason
  in `Cargo.toml`. Prefer Apple frameworks (AVFoundation, CoreText, CoreAudio) over crates for
  video, text and audio: zero added binary size, no license risk.
- MIT-compatible dependencies only (MIT, Apache-2.0, BSD, Zlib, Unicode). Check with
  `cargo tree` + crate metadata before adding.
- Do not commit or push unless the user asks. Commit messages end with the attribution lines the
  session tells you to use.

---

## 1. Current state (verified 2026-10-22 on this Mac, arm64, macOS 26.4)

Nothing in `SceneRenderer/` is committed yet. `SceneRenderer/target/` was added to `.gitignore`.

### Crate layout (`SceneRenderer/`, about 3,500 lines)
| File | Role |
|---|---|
| `Cargo.toml` | crate `scene_renderer`, `rlib` + `staticlib`, release `lto = true`, `codegen-units = 1`. Deps: block2, naga 29 (glsl-in, msl-out), serde_json, thiserror, image (png, jpeg), objc2*, uniffi 0.28.3 |
| `src/lib.rs` | `Error` enum (Io, Format, Missing, Unsupported, Shader, Metal), `uniffi::setup_scaffolding!()` |
| `src/vfs.rs` | `Pkg` (PKGV archive, entry table only, reads on demand with `read_exact_at`), `Vfs` (scene pkg/folder + shared `WallpaperEngineAssets`), `Reader` |
| `src/tex.rs` | `.tex` decode: TEXB0001..0004, LZ4 blocks, RGBA8/RG8/R8/BC1/BC2/BC3 mips, embedded PNG/JPEG via `image`, TEXS sprite frames |
| `src/shader.rs` | WE GLSL → GLSL 450 → naga → MSL. Own preprocessor (`#include`, `#if/#elif/#ifdef`, integer expression eval, `[COMBO]`, `// {"material":...}` annotations), rewrite (layout bindings, std140 UBO, reserved-word renames, `lw_inverse` polyfills, HLSL=1, audio spectrum arrays as silent consts), disk cache `~/Library/Caches/LiveWallpaper/shaders` keyed by `TRANSLATOR_REVISION` (currently 4; **bump it whenever translation output changes**) |
| `src/scene.rs` | `scene.json` model: `Layer`, `Material`, `Effect`, `EffectPass`, `Fbo`, `Bound` (value bound to a user property + condition), `Parallax`, `Scene::load` (counts skipped object kinds), `project_properties` |
| `src/gpu.rs` | Metal device/queue/samplers, texture upload, pipelines, composite shader, `Pool` (MTLHeap-backed transient render targets, aliasable), `begin` render pass, `set_bytes` / `set_buffer_or_bytes` (4 KB threshold) |
| `src/engine.rs` | `Engine`: load, `rebuild` (per-layer GPU items, skips hidden layers/effects, evicts unused textures), `encode` (frame graph), effect chains at on-screen resolution, cached static effect output, framebuffer copy for `_rt_FullFrameBuffer`, colour blend modes at final composite, engine uniforms (`Dyn`), `is_animated`, `trim` |
| `src/api.rs` | UniFFI `Renderer` object + render thread (see §1.2) |
| `examples/render_png.rs` | `render_png <scene.pkg> <out.png> [time] [w h]` → one frame |
| `examples/bench.rs` | `bench <scene.pkg> <seconds> <fps> [--hold]` → CPU %, peak RSS, frames, GPU ms/frame; `--hold` keeps process alive for `footprint` |
| `examples/shader_corpus.rs` | `shader_corpus <dir-with-shaders/> [assets]` → translate every `.frag`, list failures |

### 1.2 Public API (`src/api.rs`)
```
Renderer::new(pkg_path) -> Result<Renderer, Error>   // loads on a dedicated "scene-renderer" thread
attach_layer(layer_ptr: u64)            // CAMetalLayer, Unmanaged.passUnretained(layer).toOpaque()
play() / pause() / stop()
apply_property(name, value_json)        // triggers rebuild
apply_antialiasing(samples: u32)        // 0/1 off, 2, 4 (MSAA on main pass)
load_errors() -> [String]               // warnings: unsupported objects, failed effects
properties() -> [SceneProperty{name, kind, label, value_json}]
set_muted(bool) / set_volume(f32)       // stored only; no audio yet
set_fps_cap(f32)                        // 0 = display rate
resize(w, h)                            // pixels
set_visible(bool)                       // false: no frames, pool freed
set_pointer(x, y)                       // 0..1, top-left origin
stats() -> RenderStats{frames, gpu_ms_per_frame}
render_frame(time: f64) -> [u8]         // BGRA8 at last resize size, offscreen, for lock-screen video
```
Asset lookup: `Library/<id>/scene.pkg` → `../../WallpaperEngineAssets`.

### 1.3 Supported vs not
Supported: image layers, groups/parents, origin/scale/angles, alpha/color/brightness, visibility
and values bound to user properties, effects (multi-pass, named FBOs, scale), compose layers,
`colorBlendMode`, sprite sheets (TEXS), parallax, pointer, `_rt_FullFrameBuffer`, DXT on GPU.

Not supported (reported through `load_errors`):
- particles, text, sound objects, lights, 3D models
- puppet animation (drawn as still), layers attached to puppet bones (misplaced)
- scene scripts (SceneScript JS on properties)
- bloom (`general.bloom` in scene.json)
- video textures
- audio playback and audio-response uniforms (`g_AudioSpectrum*` are silent zeros)
- shaders naga rejects (§4.4)

### 1.4 Measurements (3024×1964, 30 fps, `bench` + `footprint`)
| Scene (Library id) | Footprint | CPU (one core) | GPU ms/frame |
|---|---|---|---|
| Nier `3008153534` | 404 MB | 8.7% | 20.2 |
| Reze `3612198967` | 197 MB | 5.7% | 6.1 |
| Angel `3695791724` | 470 MB | not captured | not captured |

Caveat: missing features (particles etc.) are not drawn, so this is partly flattering. Old engine
was **not** measured side by side; user reports "about 1 GB". Angel ships about 150 MB of
uncompressed RGBA textures (that is the floor for that scene without lossy compression).
Fourth local scene `1289832516` has not been examined.

### 1.5 Known visual issues
- Angel: blindfold/hair pieces misplaced (puppet attachment); 12 particle systems missing.
- Nier: two compose layers use `Simple_Audio_Bars` which fails to translate (§4.4).
- Nier GPU 20 ms/frame at 30 fps is high: investigate (§5.2).

---

## 2. Dev workflow

```bash
export PATH="$HOME/.cargo/bin:$PATH"          # cargo not on zsh PATH by default
cd SceneRenderer
cargo +stable build --offline --release --examples
cargo +stable test --offline                  # 8 unit tests, must stay green
rustup component add clippy --toolchain stable   # clippy not installed yet
cargo +stable clippy --offline --all-targets -- -D warnings

L=~/Library/Application\ Support/LiveWallpaper/Library
./target/release/examples/render_png "$L/3695791724/scene.pkg" /tmp/out.png 1 960 540
./target/release/examples/bench "$L/3008153534/scene.pkg" 10 30
./target/release/examples/bench "$L/3008153534/scene.pkg" 10 30 --hold &  sleep 11
footprint $(pgrep -f examples/bench) | grep Footprint; kill $(pgrep -f examples/bench)
MTL_DEBUG_LAYER=1 ./target/release/examples/render_png ...   # Metal validation; must print no asserts
```
- Compare renders against each scene's `preview.gif`/`preview.jpg` in its Library folder. View PNGs
  with the Read tool (it shows images).
- Put scratch output in the session scratchpad, not in the repo.
- Provenance check (Phase A, new item A6): compare `SceneRenderer/src` against `RenderService/`
  for copied structure, names and comments; record the result in `SceneRenderer/NOTES.md`.
- Extract a `.pkg` to inspect `scene.json`, materials, effects: write a tiny Rust example or Python
  script using the PKGV layout (`u32 len + "PKGV...."`, `u32 count`, entries `(u32 len, name,
  u32 offset, u32 size)`, data follows the table). Run Python on extracted files with `python3 -I`.
- Shader cache: delete `~/Library/Caches/LiveWallpaper/shaders` or bump `TRANSLATOR_REVISION`
  when testing translator changes.
- Debug env hooks were removed. If you add temporary ones (`LW_DEBUG_*`), remove them before finishing.

---

## 3. Phase A — housekeeping (small, do first)

A1. Install clippy, fix all warnings (`-D warnings`). Keep existing lint style.
A2. `cargo fmt` with a `rustfmt.toml` matching `RenderService/.rustfmt.toml` *settings only*
    (max_width etc.; copying 5 config lines is not code).
A3. Add `#![deny(unsafe_op_in_unsafe_fn)]`; every `unsafe` block has a `// SAFETY:` line (already the
    convention).
A4. Golden-image test harness (`tests/golden.rs`, `#[ignore]` by default because it needs local
    scenes): render each scene in `Library/` at 640×360, t=1.0, compare against
    `SceneRenderer/tests/golden/<id>.png` with per-channel tolerance (mean abs diff < 2/255, max
    diff over < 1% pixels). Golden PNGs are **our own renders** after visual approval, never
    Wallpaper Engine assets (don't commit `.pkg`/`.tex`; generated PNGs of copyrighted scenes also
    stay out of git — store them in `~/Library/Caches/LiveWallpaper/golden/` and document how to
    regenerate). Env `LW_GOLDEN_UPDATE=1` rewrites them.
A6. Provenance audit: compare every file in `SceneRenderer/src` with `RenderService/` for copied
    structure, identifiers, reserved-word or built-in tables and comments. Rewrite any match from
    the idea alone. Record the outcome in `SceneRenderer/NOTES.md` (open items section). Must pass
    before Phase D.
A5. Ask the user before the first commit. Suggested split: (1) crate skeleton + vfs/tex,
    (2) shader translator, (3) scene + engine + gpu, (4) api + examples.

Acceptance: clippy clean, tests green, golden harness runs on the 4 local scenes.

---

## 4. Phase B — feature completeness

Order by visible impact on the test scenes. Each item: implement, add unit test for the parser /
math part, render-compare, bench (no regression > 10% GPU or memory unless the feature itself costs it).

### B1. Puppet layers (models with skeletons) — highest visible impact (Angel)
- Image layers whose model is a `.mdl` (puppet) carry a mesh, a skeleton (bones with parent index,
  local transforms) and animations (keyframed per-bone transforms, fps, length, blend layers).
- Parse the MDL binary in a new `src/puppet.rs`: header/version tags, vertices (pos, uv, bone
  indices+weights), indices, skeleton, animation tracks. Figure out the layout from real files with a
  hex dump; write the layout as a comment. Unit-test against a small extracted MDL.
- Render: skinning in the vertex stage. Simplest: CPU skinning per frame into a shared vertex
  buffer (meshes are small, a few thousand verts) — measure; move to GPU (bone matrix buffer +
  weights) only if CPU > 1 ms/frame.
- Attachments: layers with `"attachment": "<bone name>"` and `parent` = puppet layer follow that
  bone's world transform. Hook into `Engine::world()`. This fixes misplaced blindfold/hair.
- Animation layers in scene.json (`animationlayers`: animation id, rate, blend, visible) mix tracks.
- Acceptance: Angel matches preview pose over time; attached pieces stay on the bones.

### B2. Particles — highest missing-content count (Angel 12, Nier 5)
- New `src/particles.rs`. Particle system JSON (`particles/*.json`): emitters (box/sphere, rate,
  directions, speed range), initializers (lifetime, size, color, alpha, velocity, rotation, turbulent
  velocity), operators (movement with gravity/drag, alpha fade, size change, color change,
  oscillate alpha/size/position, turbulence, vortex, control-point attract), renderers (sprite,
  spritetrail, rope), `maxcount`, `starttime`, child systems, control points, instance overrides
  from scene.json (`instanceoverride`: count, rate, lifetime, size, speed, alpha, color).
- Simulation on CPU in the render thread, fixed timestep, `rand` replaced by a tiny xorshift (no
  dependency). Deterministic seed per system so `render_frame(t)` is reproducible: simulate from 0
  to t in fixed steps for offline; live path steps incrementally.
- Draw: one instanced draw per system. Per-instance buffer (pos, size, rotation, color, frame) in a
  ring of 3 shared `MTLBuffer`s (triple buffering, no allocation per frame). Material shader is
  `genericparticle` with combos; reuse existing shader translator + `draw_item`.
- Implement operators in order of how often the 4 local scenes use them (count them first:
  grep particle JSON for `"name"` under operator/initializer). Unknown operators: skip + warning.
- Memory cap: `maxcount` respected; no unbounded Vec growth.
- Acceptance: particles visible and plausible vs preview on Angel and Nier; GPU cost per system
  reported in a bench run; Nier/Angel CPU stays < 15% one core at 30 fps.

### B3. Bloom
- `general.bloom`, `bloomstrength`, `bloomthreshold` in scene.json. Implement as a final
  post-process: threshold → downsample chain (half-res steps, 4–5 levels) → upsample/blur → add.
  Use `Pool` buffers at reduced size (inherently low-frequency, so no visible quality loss).
- Acceptance: scenes with bloom on look like their preview glow; GPU cost < 1 ms at 3024×1964.

### B4. Text layers
- Text objects: font file (in pkg or system), size, color, alignment, padding, `text` value which
  can be bound to properties or a script (date/time). Render with CoreText into a CGBitmapContext
  (objc2-core-text / objc2-core-graphics crates, or a minimal FFI) → upload texture; re-render only
  when the string changes (clock: once per second/minute). No font-rasterizer crate.
- Acceptance: text objects in local scenes appear; clock text updates.

### B5. Scene scripts (SceneScript)
- Properties may carry `"script"` (JavaScript) that computes values every frame (clocks, audio
  response, cursor). A JS engine is a big dependency. **Decision for the user** (ask before
  implementing): (a) skip scripts, use the static value (current behaviour); (b) handle the most
  common script patterns natively (clock text, simple oscillation) by pattern-matching; (c) embed a
  small MIT/Apache JS engine (e.g. `boa_engine` — measure binary size and memory first).
  Recommend (a) now, (b) later for clocks only.

### B6. Audio
- Sound objects: `sound` list of files (mp3/ogg/wav), volume, playback mode (loop/random),
  `mintime/maxtime`. Play with AVAudioEngine/AVAudioPlayerNode via objc2-avf-audio (no decoder crate;
  AVFoundation decodes mp3/wav; **ogg is not supported by AVFoundation** → check how many scenes use
  ogg; if needed, `lewton` (MIT/Apache, pure Rust) decodes Vorbis to PCM fed into the player node).
- `set_muted` / `set_volume` drive the engine's main mixer. Muted = engine stopped (no CPU).
- Audio response: `g_AudioSpectrum16Left/Right`, `32`, `64` uniforms. Source: system audio capture
  (app already has `NSAudioCaptureUsageDescription`). Use a Core Audio process tap
  (`AudioHardwareCreateProcessTap`, macOS 14.2+) on the Swift side or in Rust via objc2 — capture,
  FFT (write a small radix-2 FFT; or use Accelerate `vDSP_fft_zrip` via FFI, zero size cost), log
  bin grouping into 16/32/64 bands, smoothing, feed as uniform arrays. Replace the silent-const
  rewrite in `shader.rs` with real uniforms (bump `TRANSLATOR_REVISION`).
- Capture only while visible, audio response enabled, and a loaded shader uses a spectrum uniform.
- Acceptance: Nier audio bars move with music (after B7 fixes the shader); zero audio CPU when muted
  and no spectrum shader.

### B7. Shader translation failures
Current corpus (bundled assets + local scenes): 46 ok, 13 fail. Fix in this order:
1. `Simple_Audio_Bars` (Nier): `frequency % RESOLUTION` int/float mismatch → in rewrite, when `%`
   has a float operand, emit `mod(a, b)`; also check `RESOLUTION` define. Needs a small expression
   type pass or targeted regex; prefer naga error-driven fix: catch naga's type error, retry with
   implicit-conversion rewrite.
2. `Iris Movement +`: `vec2 * vec4` (HLSL implicit truncation) → rewrite to `.xy` swizzle on the
   wider operand when naga reports mismatched vector sizes. Generalise: HLSL allows implicit
   vector truncation and int→float; GLSL does not. Implement one "HLSL implicit conversion" fixer
   driven by naga's span-tagged errors (re-parse loop, max 8 iterations).
3. `PerformLighting_V1` (`#require LightingV1`): provide our own lighting snippet implementing the
   documented semantics (point lights, ambient) — written from scratch.
4. `BLENDROWCOUNT` (puppettexturechannels), `editorpaintbrush`: low priority.
5. `gl_InstanceID`, `gl_ViewportIndex` (fur, shadowcaster): 3D only, skip.
6. HLSL/dx11 shader files: not needed, ignore.
Keep `shader_corpus` as the regression check; record ok/fail counts in this file when they change.

### B8. Video textures
- Some scenes reference `.mp4`/`.webm` as textures. Decode with AVFoundation `AVPlayerItemVideoOutput`
  → `CVPixelBuffer` (IOSurface-backed) → `CVMetalTextureCache` zero-copy texture. No FFmpeg.
  WebM/VP9: AVFoundation support is limited; report as unsupported via `load_errors` if it fails.

### B9. Other gaps (low priority)
- 3D models, lights: report unsupported.
- `camerashake`, `cameraparallax*`, `camerafade`, `clearcolor`, `orthogonalprojection` (custom
  width/height), `zoom`: verify each against scene.json of local scenes, implement what is cheap.
- `nearz/farz`, perspective camera: only if a local scene needs it.

---

## 5. Phase C — heat and memory

Principle: the cheapest frame is the one not rendered. Measure before and after each change with
`bench` (CPU, GPU ms/frame, frames) and `footprint`. Record numbers in §1.4.

### C1. Measure the old engine (baseline) — do before claiming wins
- Build the app as-is (`./build.sh` per README), play each of the 4 scenes at the same resolution
  and FPS, record `footprint <LiveWallpaperService pid>`, `top -l 10 -pid` CPU, and
  `sudo powermetrics --samplers gpu_power -i 1000 -n 20` GPU power (needs the user to run sudo:
  ask them, suggest `! sudo powermetrics ...`). Ask the user before launching the app — it changes
  their desktop.
- Same measurement for SceneRenderer once integrated (Phase D). Table in this file.

### C2. Frame pacing
- Render thread currently sleeps to a fixed cadence. Switch to `CAMetalDisplayLink` (macOS 14+) or
  CVDisplayLink on the attached layer's screen, with `preferredFrameRateRange` set to the FPS cap.
  Gives vsync-aligned frames, no busy-wait, ProMotion aware.
- `is_animated() == false` → draw once after any change, then stop the loop entirely (already done;
  keep it working with particles/puppets/audio, which make a scene animated).
- When only the pointer moves (parallax) on an otherwise static scene: render on pointer change only.
- Skip identical frames: if nothing time-dependent is visible this frame (all animated layers
  hidden), don't present.

### C3. Visibility
- `set_visible(false)` from Swift on: screen asleep, display off, wallpaper window fully occluded
  (`NSWindow.occlusionState`), fullscreen app on that space, user session inactive, screen locked.
  Renderer then releases transient pool and cached effect textures (`trim`) after 5 s hidden.
- Mark static textures purgeable (`setPurgeableState(.volatile)`) while hidden? Only if reload cost
  is acceptable; measure. Default: keep.

### C4. Power-aware policy (map the app's existing `PowerOptions`)
- `frameRateCap`, `batteryFPS`, `batteryMode` (keepRunning / reducedQuality / pause),
  `batteryRenderScale`, `skipRepeatedFrames`, `renderOnlyOnChange` exist in the Swift model
  (`SceneRenderService.push`). Implement on the Swift side by calling `set_fps_cap`,
  `set_visible`, and a new `set_render_scale(f32)` (render to smaller drawable, upscale in the
  layer via `contentsScale` — user-chosen, so allowed to reduce quality).
- Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`) → treat as battery.

### C5. GPU cost reduction (Nier 20 ms/frame is the target to cut)
- Profile with Xcode GPU capture or `MTLCaptureManager` to a `.gputrace` (add a hidden
  `LW_CAPTURE=path` env in `render_png` only). Find the heaviest passes.
- Likely wins, keep visual identity:
  1. **Effect buffers already at on-screen resolution.** Verify all 5 Nier 3840×2160 layers do get
     scaled to screen size (they are full-screen, so ~3024×1964 each) — each runs 3–4 effects ⇒
     ~15–20 full-screen passes. Merge: consecutive single-pass effects that only read their input
     at the same UV could be fused — complex; skip unless profiling shows bandwidth bound.
  2. **Store/load actions:** every pass uses `DontCare` load when it overwrites fully, `DontCare`
     store for MSAA resolve sources and for buffers not read later. Check `gpu::begin`.
  3. **Memoryless MSAA** attachment (`MTLStorageMode.memoryless`) for the main pass MSAA texture:
     saves memory and bandwidth on Apple GPUs.
  4. **Fewer render encoders:** sample showed `renderCommandEncoderWithDescriptor` as the top CPU
     cost. Batch consecutive layers without effects into one encoder (already done for the main
     pass); avoid ending/restarting the main encoder for layers whose effects don't read the frame.
  5. **Framebuffer copies:** `_rt_FullFrameBuffer` copies the whole screen per reader. Copy only
     the layer's screen bounding rect (blit region) when the reader is a small layer.
  6. Pipeline state and sampler binds: sort is not needed (layer order is fixed), but skip redundant
     `setRenderPipelineState`/texture binds when unchanged.
- Half-float (`RGBA16Float`) buffers are **not** needed; stay BGRA8 unless banding is visible.

### C6. Memory
- Floor = scene textures. Already: DXT kept compressed, hidden layers not loaded, unused textures
  evicted after property change, one heap for transient buffers.
- Remaining ideas, all lossless:
  1. Don't keep CPU copies of texture data after upload (verify `tex::Tex` buffers are dropped).
  2. Mipmaps: only generate/upload mips the shader samples at the drawn size; a 4444×3333 layer
     drawn at 1500 px wide never samples mip 0 → upload from the first mip ≥ drawn size
     (**this is visually lossless**: the GPU would sample the smaller mip anyway). Biggest single
     win for Angel (60 MB texture). Handle `resize` growth by re-uploading.
  3. `Pool` heap sizing: keep heap at max-of-frame high-water mark, shrink after N frames below.
  4. Release `Pkg` file handle data / JSON trees after load.
  5. Shader cache: `MTLBinaryArchive` for compiled pipelines to cut first-load CPU (heat at start).
- Target: every local scene ≤ 60% of old engine footprint, none above 500 MB.

---

## 6. Phase D — integrate into the Swift app, delete RenderService

Read first: `Package.swift`, `Sources/LiveWallpaperService/SceneRenderService.swift`,
`Sources/LiveWallpaperService/WallpaperWindows.swift`, `LockScreen.swift`, `Orchestrator.swift`,
`build.sh`, `scripts/build-render-service.sh`, `scripts/bundle-dylibs.py`,
`scripts/verify-bundle.sh`, `.github/workflows/build.yml` and `release.yml`, `README.md`,
`ARCHITECTURE.md`, `docs/render-bridge-notes.md`, `docs/PLAN-scene-renderer.md`.

### D1. API gaps to close before wiring (Rust side)
The old bridge offered things the new API lacks. Add:
- `set_fit_mode(mode)`: fill / fit(match) / stretch / none / matchBlurred (blurred fill behind fit:
  draw scene once into a small buffer, blur, stretch behind). Today the engine always "fills" by
  the scene's orthographic size — check `fit` computation in `encode`.
- `set_pan_zoom(pan_x, pan_y, zoom)`.
- `set_render_scale(f32)` (§C4).
- Multiple displays: **one `Renderer` per display** is simplest but duplicates textures. Prefer one
  `Renderer` with `attach_layer(display_id: String, layer_ptr: u64, w, h)` /
  `detach_layer(display_id)`; the render thread renders each attached target per tick (shared
  textures, per-target pool buffers). Decide by measuring: if a typical user has 1–2 displays and
  per-display textures are < 200 MB, per-display Renderer is acceptable — but shared is better for
  the memory goal. Recommend shared.
- `set_audio_response(enabled)`.
- Error-free UniFFI `Record`/`Enum` for fit mode instead of strings.

### D2. Build
- New `scripts/build-scene-renderer.sh`: `cargo build --release` in `SceneRenderer`, then
  `uniffi-bindgen generate --library target/release/libscene_renderer.a --language swift`.
  UniFFI 0.28 needs a bindgen binary: add `[[bin]] uniffi-bindgen` in a tiny workspace member
  `SceneRenderer/uniffi-bindgen/` (`fn main() { uniffi::uniffi_bindgen_main() }`, feature `cli`),
  so it is not linked into the static lib.
- Output into `Sources/SceneBridge/` (`SceneRenderer.swift`) + `Sources/SceneBridge/FFI/`
  (`scene_rendererFFI.h`, `module.modulemap`). Rename targets in `Package.swift`:
  `WallpaperBridgeFFI` → `SceneRendererFFI`, `RenderBridge` → `SceneBridge`.
- Linker flags shrink to `-L SceneRenderer/target/release -lscene_renderer` + frameworks
  `Metal`, `QuartzCore`, `Foundation`, `AppKit` (+ `AVFoundation`, `CoreAudio`, `CoreText`,
  `CoreVideo` when Phase B adds them). No Homebrew paths, no rpaths, no `-lc++`.
- Toolchain: `rust-toolchain.toml` in `SceneRenderer/` pinning stable (current dev uses `+stable`).
- macOS deployment target: `MACOSX_DEPLOYMENT_TARGET=15.0` for cargo matches the Swift package
  (check `Package.swift` platforms). If proc-macro dylib issues appear (as noted in the old
  script), set it via `CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS="-C link-arg=-mmacosx-version-min=15.0"`.
- Universal binary? Check `build.sh`/release workflow for x86_64; if needed, build both targets and
  `lipo` the static libs.

### D3. Swift service rewrite (`SceneRenderService.swift`)
Map old → new:
| Old bridge call | New |
|---|---|
| `WallpaperBridge()`, `bootstrap`, `selectWallpaper(id)`, `applyWallpaperOptions` | `Renderer(pkgPath: Library/<id>/scene.pkg)` |
| `setDisplayConfigEnabled`, `ejectWallpaperFromDisplay` | `attach_layer` / `detach_layer` with the wallpaper window's `CAMetalLayer`; drop renderer on stop |
| `pauseAll` / `playAll` | `pause()` / `play()` |
| `setMuted`, `setVolume` | same |
| `setFrameRateCap`, `setTargetFps`, battery calls | `set_fps_cap` + policy in Swift (§C4) |
| `setRenderScale` | `set_render_scale` |
| `setScalingMode`, `setDisplayPosition`, `editScalingFactor` | `set_fit_mode`, `set_pan_zoom` |
| `setAudioResponseEnabled` | `set_audio_response` |
| `editProperty(value: BridgePropertyValue)` | `apply_property(name, valueJSON)` — encode `ScenePropertyValue` to JSON (bool, number, string, color as `"r g b"` string — check what `scene.rs` `Bound` expects for colors) |
| `selection.wallpaperOptions.supported == false` | `Renderer.init` throws → `failed(...)`; non-fatal `load_errors()` → log, optionally surface in UI |
- Create the renderer off the main actor (load takes ~0.3 s cached, up to several seconds cold):
  `Task.detached`, then hop back to attach.
- Window layer: wallpaper windows must host a `CAMetalLayer` (`wantsLayer`, `makeBackingLayer`);
  set `contentsScale` to the screen's backing scale; call `resize` on `viewDidChangeBackingProperties`
  and frame changes; `set_visible` from occlusion notifications.
- Pointer: global mouse position (NSEvent.mouseLocation, polled at frame rate or via a global
  monitor — monitor needs no extra permission for mouse moves) → `set_pointer` normalized per display.
- Remove `SceneBridge.configureEnvironment` (WALLPAPER_MACHINE_* env, VK_ICD_FILENAMES).

### D4. Lock screen
- Plan (docs/PLAN-scene-renderer.md): render the scene offline to a looping HEVC video and install it
  through the existing Aerial path in `LockScreen.swift`.
- Swift: `AVAssetWriter` (HEVC, 30 fps, screen resolution) fed by `render_frame(t)` BGRA bytes
  wrapped in `CVPixelBuffer` (use a `CVPixelBufferPool`; copy rows respecting bytesPerRow). Loop
  length 20–30 s; cross-fade last 1 s with the first second for a seamless loop (blend in Swift via
  vImage or ask Rust for both frames). Low priority `Task`, progress in UI, `.partial` then atomic
  move to `Library/<id>/lock-<w>x<h>.mov`.
- Better: add `render_frame_into(time, iosurface_ptr)` to render straight into the pixel buffer's
  IOSurface (no copy) — optional optimisation.
- Particles must be deterministic for `render_frame` (B2).

### D5. Delete the GPL code and its plumbing
Only after D3 works end to end and the user agrees:
- `git rm -r RenderService/ Sources/RenderBridge/ scripts/build-render-service.sh`
- `build.sh`: remove dylib bundling (`bundle-dylibs.py` call, MoltenVK copy, ICD manifest,
  Homebrew load-path check); the service now has no third-party dylibs. Keep the SceneEngine/
  SceneFormat separation checks, renamed to the new module.
- `scripts/bundle-dylibs.py`: delete if nothing else uses it (grep).
- `scripts/verify-bundle.sh`: replace dylib/MoltenVK checks with "service links no Homebrew paths"
  (`otool -L` shows only /System and /usr/lib).
- `scripts/install-render-deps.sh`: delete (Homebrew deps were only for RenderService); check
  README references.
- CI `.github/workflows/build.yml`, `release.yml`: replace `scripts/build-render-service.sh` and
  brew installs with rustup stable + `scripts/build-scene-renderer.sh`. Cache `~/.cargo` and
  `SceneRenderer/target`.
- `.gitignore`: drop `RenderService/target/`.
- Docs: README (credits, license section, build steps, "Wallpaper Engine compatibility"
  statement), `ARCHITECTURE.md`, `docs/render-bridge-notes.md` (delete or rewrite as
  `docs/scene-renderer.md`), `docs/PLAN-scene-renderer.md` status section. State plainly: the
  renderer is original MIT code; format knowledge came from public observation of scene files.
- `LICENSE` stays MIT. Add `THIRD-PARTY-NOTICES` listing Rust deps' licenses
  (`cargo about` or a manual list from `cargo tree`), since a static lib bundles them.
- Search for leftovers: `grep -rni "wallpaper_bridge\|WallpaperBridge\|MoltenVK\|vulkan\|mwe-ffmpeg\|GPL" .`
  (excluding `.build/`, `target/`).
- Old app state: `AppPaths.supportDirectory/RenderService` folder — add a one-time cleanup in the
  service on launch (delete if present) so users don't keep stale GB of cache.

### D6. Acceptance for integration
- `./build.sh` produces an app with no Homebrew dependency; `scripts/verify-bundle.sh` passes.
- All four local scenes play on the desktop; properties edited in Settings apply live; pause, mute,
  FPS cap, fit modes, pan/zoom, multi-display, sleep/wake, lock/unlock, space switch all work.
- Lock-screen video renders and installs.
- Memory and heat table (§C1) shows new ≤ old on every scene.
- CI green on both workflows.

---

## 7. Phase E — shader pipeline improvements (answers the user's question)

Current: WE GLSL (1.20-ish, HLSL flavoured) → own preprocessor with combo specialisation →
rewrite to GLSL 450 → naga → MSL → `newLibraryWithSource` at runtime, MSL cached on disk.

Improvements, in value order:
1. **Cache compiled Metal, not just MSL.** Use `MTLBinaryArchive` (or `newLibraryWithData` from a
   precompiled `.metallib` produced via `MTLDynamicLibrary`/`serializeToURL`) keyed by
   (translator revision, shader hash, combos, pixel format, blend, sample count). Cuts load CPU
   and the start-up heat spike. Invalidate on OS version change.
2. **HLSL implicit-conversion fixer** (B7.2) — biggest correctness win.
3. **Keep naga, don't write an MSL backend.** naga is MIT/Apache, maintained, and good. The
   alternative (direct GLSL→MSL text rewrite) would be smaller but fragile.
4. **Precompile at import time.** When a scene is added to the library (Swift import flow), spawn
   a background translate of all its materials so first play is fast.
5. **Dead uniform/texture elimination** already happens via combo preprocessing; also skip
   binding textures the translated shader doesn't reference (naga reflection gives used globals).
6. **Uniform upload:** small blocks via `setVertexBytes`/`setFragmentBytes` (done, ≤ 4 KB). Static
   (per-material, property-only) uniforms could live in a persistent buffer updated on rebuild
   instead of per frame — minor CPU win.

---

## 8. Suggested execution order

1. Phase A (housekeeping, golden harness).
2. D1 + D2 + D3 minimal (single display, play/pause/properties) — get it into the app early behind
   a hidden setting `useNewRenderer` (default off) so the user can A/B heat on real use. Ask the
   user to try it.
3. C1 baseline measurements with both renderers.
4. B1 puppets, B2 particles, B7 shader fixes, B3 bloom (visible gaps on the user's scenes).
5. C2–C6 performance.
6. B6 audio, B4 text, B8 video, D4 lock screen.
7. Default `useNewRenderer` on; after user confirmation, D5 delete RenderService.
8. Ask user about B5 scripts.

Each step: build, unit tests, golden compare, bench, update §1.3/§1.4 in this file, short report
to the user with numbers. Do not mark anything done that wasn't run.

---

## 9. Risks and open decisions (ask the user)
- Ogg audio: add `lewton` or skip ogg.
- When to delete RenderService (needs user sign-off; destructive `git rm`).
- Measuring power needs `sudo powermetrics` — the user must run it.
- Golden images of copyrighted scenes must not be committed.
- naga version bumps can change MSL output: bump `TRANSLATOR_REVISION` on any naga upgrade.
