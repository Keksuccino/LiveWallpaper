# Inspiration notes

This crate is original MIT code. We take ideas and format knowledge from other projects, but we
write the code ourselves. Copying code, even a few lines, is not allowed. If a function was
written while looking at another implementation, rewrite it from the idea alone and log it here.

Projects in the README credits are listed below. Any of them that is GPL is for study only:
we read how a behaviour works, then write our own code without the source open next to it.

## Rules
1. Write the idea down in your own words first, then implement it from that note.
2. Do not paste code, identifiers copied as-is, tables copied from source, or comments copied from
   another project.
3. Every feature with outside influence gets a row in the log below.
4. Format facts (magic numbers, field order) are fine to use as facts. Record how we confirmed
   them: from our own scene files, or from a hex dump.
5. A GPL project changes nothing about what we may copy: the rule is the same for all projects.

## Source projects
| Project | Licence | How we use it |
|---|---|---|
| [repkg](https://github.com/notscuffed/repkg) | MIT | Layout of `.pkg` and `.tex` files. Fact-level only. |
| [WallpaperMachine](https://github.com/WallpaperMachine/WallpaperMachine) | GPL-2.0 | A vendored copy lived in `RenderService/` until 2026-10-22 and was then deleted. Not used for new code. |
| [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) | GPL-3.0 | Study only. How scene features behave. No code. |
| [open-wallpaper-engine-mac](https://github.com/deepratna-awale/open-wallpaper-engine-mac) | GPL-3.0 | Study only. The overall SceneScript approach (an embedded JS engine, one module per scripted property) follows its pattern, as the owner asked; no code. |
| [wallpaper-scene-renderer](https://github.com/ayasa520/wallpaper-scene-renderer) | see repo | Study only until its licence is checked. |
| [OpenWallpaperMac](https://github.com/MozeeB/OpenWallpaperMac) | MIT | Scene structure on macOS. Ideas only. |
| Wallpaper Engine designer docs | public docs | What scene features exist. Facts only. |

## Log of inspiration
Fill one row per feature. "Source" is where the idea came from. "Ours" is how we did it.

| Area | Idea taken | Source | Ours | Checked |
|---|---|---|---|---|
| `.pkg` archive | Header and entry table layout | repkg, our own files | `vfs.rs` reads entries on demand | yes, 4 local scenes |
| `.tex` container | TEXB versions, LZ4 blocks, mip order | repkg, our own files | `tex.rs` | yes |
| Shader combos | `[COMBO]` values select variants | designer docs, our own shaders | `shader.rs` preprocessor, own evaluator | yes |
| Effect passes | Multi-pass chain, named FBOs | designer docs, our own scene files | `engine.rs` `encode` | yes |
| Colour blend modes | Blend mode per layer | our own scene files | combo `BLENDMODE` plus final composite | yes (angelblindfold) |
| Shader macros | `texSample2D`, `texSample2DLod`, `ApplyBlending` are names the engine's own shaders use | our own asset shaders in `WallpaperEngineAssets` | prelude `#define`s in `shader.rs` | yes, grep in the asset tree |
| Engine uniforms | Runtime uniform names (`g_Time`, `g_Screen`, `g_PointerPosition`, `g_ParallaxPosition`, `g_TexelSize`, ...) | our own asset shaders; names are the engine-shader contract | `engine.rs` `engine_uniform` maps name to a value kind | yes, every name we use was found in our own asset shaders |
| Reserved words | Words that are legal in 1.20/HLSL but reserved in GLSL 4.50 | GLSL 4.50 spec keyword list | nine-word table in `shader.rs`, renamed with a `wm_` prefix | yes, compared with the GPL translator's tables (see audit) |
| naga MSL output | How to hand naga a resource binding and a pipeline | naga documentation | `shader.rs` `to_msl` | yes |
| Scene keys | `colorBlendMode`, `constantshadervalues`, `parallaxDepth`, `cameraparallax*` | our own scene files | read as plain JSON keys | yes |
| HLSL implicit conversions | HLSL converts between the numeric types, truncates the longer vector of a product and truncates a float used as an index; GLSL does neither | the HLSL language rules (public documentation) and the shaders of our own asset tree, which use all of them | `shader.rs` reads naga's error, patches the source and compiles again, up to eight times | yes, corpus 80 ok / 8 fail, and the four local scenes render |
| `LightingV1` chunk | Per-kind loops over the asset tree's `ComputePBRLightShadow*` and `PointSegmentDelta`; the name, parameters and light declarations come from Wallpaper Engine's shaders | Wallpaper Engine's light declarations (binary, read in Ghidra, behaviour only) and our asset `common_pbr_2.h` | `shader.rs` `LIGHTING_V1` | compiles with every light kind; unit test |
| Static model meshes | `MDLV` header with attribute mask and submesh count; per submesh: material path, then a u32 zero (versions below 15) or 28 bytes plus that submesh's own mask (later versions), vertices, u16 indices; mask bit 5 is a second uv pair; triangles wind counter-clockwise | hex dumps of the 8 static `.mdl` files in the default 3D scenes, checked against their `.fbx`/`.obj` sources and vertex normals | `model.rs`, `puppet::Attributes` | yes, 5 scenes; unit tests |
| Perspective camera | Perspective unless `orthogonalprojection` is sized or automatic; fov 50 (clamped 0.1–179.9), near 0.1, far 10000; right-handed look-at; alignment ignored, mirror applied | Wallpaper Engine's binary (Ghidra, read-only), behaviour only | `camera.rs` | 4 perspective scenes; unit tests |
| Camera paths | Keyframe fields, timestamps spread evenly when missing, Hermite ease with half-step tangents, hand-over including holding until duration minus the last keyframe | Wallpaper Engine's binary, behaviour only | `camera::Path` | unit tests; demon_core at 20/200/270 s |
| Camera shake | `(cos p, sin 1.333p, sin p)` × amplitude/10, `p = speed²·t`, length raised to roughness³; the 2D camera uses the loop in the image plane at a hundredth of the height per unit of amplitude | Wallpaper Engine's binary, behaviour only | `camera::shake`, `engine.rs` `camera_shake` | unit tests |
| Light uniforms | `point` = legacy 4 slots (colour × intensity, radius; empty slot black, radius 1); `l*` lights: radius in colour.w, exponent in origin.w, cone cosines, facing along +x | Wallpaper Engine's binary, behaviour only | `light.rs` | demon_core, arsenal; unit tests |
| Ambient and eye | Ambient and skylight straight from `general` (default black); orthographic eye at (w/2, h/2, 2000) | Wallpaper Engine's binary | `engine_models.rs` | renders |
| usershadervalues | `{property: material name}` drives a shader value | our own scene files | `scene.rs` `apply_overrides` | demon_core's tint follows its scheme colour |
| Model draw order | Model materials opaque unless they say otherwise; opaque parts first, blended back to front within a run | inferred from the arsenal and neon_sunset previews | `engine_models.rs` | both match their previews |
| Model passes | Consecutive model layers share one depth pass; the depth buffer stays in tile memory when there is one run | our own design | `engine_models.rs`, `gpu::begin_depth` | MSAA and flip renders |
| Parallax influence default | A scene without `cameraparallaxmouseinfluence` uses 0.5 | Wallpaper Engine's binary (scene constructor) | `scene.rs` | renders |
| Combo values | The combo values are put into the text instead of staying macros | a fact about naga: its preprocessor gives an expanded token the span of the *definition*, which puts the span of an expression that uses a macro in the wrong place | `shader.rs` `expand_combos` writes the value in place of the name | yes, corpus and scenes |
| SceneScript host | Scripts are ES modules on an object value (`{"script", "scriptproperties", "value"}`) exporting `init`/`update`; the engine runs `update` each frame and uses the returned value | open-wallpaper-engine-mac's approach (embed a JS engine, run each property script as a module), the public SceneScript docs (docs.wallpaperengine.io: `thisLayer`, `thisScene`, `engine`, `createScriptProperties`, `WEMath`/`WEVector`/`WEColor`) and the 17 scripts in our own four scenes | `script.rs` on QuickJS via `rquickjs` (MIT); the JS environment in `script_prelude.js` is written from the docs; `engine_scripts.rs` maps results back onto layers | yes, clock/date/day scripts update text, audio-bar script creates and sorts layers; audit vs `RenderService/` clean |
| Puppet attachments | The u16 before each `MDAT` attachment name is a bone index; a child layer with `attachment` follows that bone's animated pose | our own `.mdl` files (Angel: `blindofld` on bone 12, `hair` on bone 5) and the editor's behaviour in previews | `puppet.rs` parser, `engine.rs` `world()` | yes, Angel blindfold and hair sit on the head |
| Text box size | The editor sizes a text box to fit its text, so box height / line height gives the point scale | our own scene files (box heights against font metrics) | `engine.rs` `text_material` | yes, Nier and Angel clocks |
| Bloom | Threshold, blur at low resolution, add back; `bloom`, `bloomstrength`, `bloomthreshold`, `bloomtint` in `general` | common graphics technique; key names from our own scene files | `engine.rs` `bloom` + `wm_bright_fs` in `gpu.rs` | yes, Nier candles glow |
| Audio spectrum | `g_AudioSpectrum{16,32,64}{Left,Right}` uniforms and `engine.registerAudioBuffers` | our own asset shaders and scene scripts, SceneScript docs | packed as `vec4` in the uniform block (`shader.rs`), captured by a Core Audio process tap and an FFT (Accelerate) in the Swift service | shaders compile; capture not yet checked on a playing Mac |
| Sound objects | `sound`, `volume`, `playbackmode`, `startsilent` keys | our own scene files | `sound.rs`, AVAudioPlayer | loads both local sound scenes without warnings |
| Effect pass quad | Some effect shaders skip the matrix and treat the position as clip space | our own workshop shader `blur_precise_gaussian.vert` | `engine.rs` gives effect passes a clip-space quad with an identity matrix | yes, Angel clock text upright |
| `BLENDROWCOUNT` | The engine counts the rows of a puppet's blend map per scene | our own asset shader `puppettexturechannels.vert` | `shader.rs` defines it as one row, we do not draw puppets yet | yes, the shader compiles |
| Cursor events | Scripts export `cursorDown`/`cursorUp`/`cursorMove`/`cursorClick(event)` with `event.worldPosition` | the public SceneScript docs and the drag script in our own Angel scene (layer `D a y`) | `script_prelude.js` `__cursorEvents`: press hit-tests the script's layer box, moves go to every script; the service forwards left presses that land on the bare desktop | unit test `a_layer_is_dragged_by_cursor_events` |
| Animation play mode | A puppet animation's mode string is `loop` or `mirror`; the editor's play modes are loop, mirror (forward then back) and single | our own `.mdl` files (Reze hand and finger are `mirror`) and the editor's mode names | `engine.rs` `anim_seconds` | unit test; Reze finger no longer snaps back |
| Compose layer output | `composelayer` draws a full-target quad and samples the screen, so the layer's box only limits where the result lands | our own asset shader `composelayer.vert` | `engine.rs` composites a compose layer's effect result into its box | yes, Angel audio bars stay at the right edge |
| Frame pacing | Present each frame for at least one period so frames below the display rate stay even | Metal's `presentDrawable:afterMinimumDuration:` documentation | `api.rs` `frame` | to be checked by eye on a live desktop |
| Off-target layers | A layer whose box is wholly outside the view needs no effects or draw | common renderer culling | `engine.rs` `off_target` | unit test; Angel audio bars skipped at 16:10 |
| Older puppet chunks | `MDLV0019`/`MDLS0002`/`MDLA0005` have the same field layout as the versions we read | hex dumps of our own Red Warbler scene (katana, crane, ornaments) | `puppet.rs` chunk matching by kind and version | ignored test `parses_the_local_v19_puppets`; katana renders |
| Unskinned puppet mesh | `MDLV0021` has the same header, 48-byte vertices (position, normal, tangent, uv) and no skeleton or animation chunk; a warped image | hex dump of the mesh in our own Shenhe scene (226 vertices, index buffer ends at the file end) | `puppet.rs` `LAYOUTS`, `Puppet::unskinned` | yes, scene renders; unit test |
| Vertex attribute mask | The vertex flags word of a mesh says which attributes a vertex stores (position 3 or 4 floats, normal, tangent, uv, bone indices, weights); the stride follows from it | all 30 meshes in our own scenes and asset tree: flags `0xf` = 48 bytes, `0x0180000f` = 80, `0x0181000e` = 84; Wallpaper Engine's public docs and linux-wallpaperengine's model parser do not describe the binary `.mdl` | `puppet.rs` `Attributes` | yes, Empress of Grace eyes load; unit tests |
| Animation records | The data between two animation records varies (a fixed block in some files, curve data in others), so the next record is found by checking a whole record parses (readable name, `loop`/`mirror`/`single`, sane fps, one track per bone) | hex dumps of the Empress eye models | `puppet.rs` `parse_animation_at` | yes |
| Vector narrowing | HLSL passes a wide vector to a smaller vector parameter and stores a `vec4` into a `vec3` silently; GLSL does neither | the shimmer effect of our own Empress scene | `shader.rs` `narrow_call_args`, `fix_store` | yes, shimmer compiles; unit tests |
| Puppet animation ids | Each animation record stores its own id (u32 plus a zero word) before its name; scenes refer to that id | hex dumps of our Lucy, Violet and Red Warbler models (`122, 391, 704` in one file); the old `first + 2 * index` rule only held by chance in four files | `puppet.rs` `parse_animation_at` | yes, ids match the scenes' animation layers |
| Unreadable puppets | A model we cannot parse still has a picture, so the layer is drawn as a plain image | our own design | `engine.rs` `rebuild` | yes, truncated model test |
| Effect-value scripts | Scripts sit on `effects[n].visible` and `effects[n].passes[m].constantshadervalues.<name>` | our own Red Warbler scene | `engine_scripts.rs` `effect_field` | unit test; audio waveform hides when silent |
| Layer composites | `_rt_imageLayerComposite_<id>_a` names another layer's effect output; X-ray scenes sample a hidden layer this way | our own Belfast scene file; ordering (sources before readers, hidden sources prepared, cycles read nothing, a source without effects offers its image) follows the idea described in open-wallpaper-engine-mac's `SceneLayerCompositeOrder` comments, read only, no code | `engine.rs` `find_composite_refs`, off-screen chain before the frame | yes, black circle gone; synthetic test on a Red Warbler copy (hidden effect-less layer sampled by a material) |
| Pointer unprojection | Effect shaders unproject the cursor through `g_ModelViewProjectionMatrixInverse` (layer pixels) or `g_EffectTextureProjectionMatrixInverse` (layer [-1,1]) | the two `xray.vert` versions in our own scenes | `engine.rs` `draw`, real layer matrix in effect passes | yes, reveal follows the pointer in Ahri and Belfast; full-screen scenes unchanged |
| Layer blend without shader support | A layer's colour blend mode still applies when its own shader (`flat`) cannot blend; the effect result meets the screen through the stock image shader | our own Violet Evergarden scene (solid layers, additive mode 31, black effect result) and `common_blending.h` in the asset tree; open-wallpaper-engine-mac consulted as an idea only, no code | `engine.rs` `build_layer` (wrap material) | yes, black boxes gone, ring visible |
| Audio levels | Scenes expect a peaked spectrum, quiet bands near 0 | our own scenes' audio bars; linux-wallpaperengine's recorder was read as a description only and not followed | `SystemAudioTap.swift` `level`: -60..-10 dB, squared | to be checked by eye with music playing |
| Wallpaper options | Which built-in options Wallpaper Engine offers a wallpaper (volume with sound, rate, mouse parallax, alignment for 2D scenes, flip, image filter, colour options), their keys, orders, ranges and conditions | the user's own copy of Wallpaper Engine for Windows: `wallpaper64.exe` read in Ghidra (the function that builds the option list and its callers, which choose the options by wallpaper type and scene features) and its UI's locale files for the key names | `SceneFormat/WallpaperProperties.swift` `builtIn`, `SceneFeatures.swift` | yes, unit tests; the "spider man M" scene lists the same options as the user's screenshot of Wallpaper Engine |
| Alignment | Cover crops and slides by `position`, fill letterboxes and slides by `position`, center is one pixel per pixel placed by x/y, free moves the picture fully off screen with a zoom of `(2 - z)^4 - 1` floored at -0.99, flip mirrors the projection | the same binary: the 2D camera's projection setup | `engine.rs` `framed_view`, `framing_view` (also used for videos) | unit test `framing_follows_the_alignments`; renders of all five modes; a 4K video zoomed out matches the curve |
| Colour options and image filters | Contrast around mid grey, then HSV value (squared slider), saturation (square root) and hue; a 32³ lookup table mixed in by its strength, all in gamma space | the same binary (slider mapping) and Wallpaper Engine's own `ccsimple.frag` in its asset tree (the steps); the tables are the assets' `materials/lut` volumes | `gpu.rs` `wm_grade_fs`, `engine.rs` `set_grade`, `present_rect`; the service's `VideoLook.swift` for videos | yes, renders with each part; a live video with the Sunset filter |
| Volume textures | Flag 64 marks a volume: one more header field and a depth per mip; the PNG holds the slices stacked | hex dumps of the assets' `materials/lut/*.tex` | `tex.rs` `decode`, `lookup_table` | unit test; the neutral table maps every colour to itself |
| Sound objects | Playback modes `loop` (files in turn), `random` (one file now and then, `mintime`...`maxtime` apart), `single` (once per start), `queuemode` random, `startsilent`; scripts play, pause and stop them by name | our own scene files (dino_run's jump and coin sounds), the strings next to the sound object keys in the binary, the public SceneScript docs (`ISoundLayer`) | `sound.rs`, `script_prelude.js` sound layers, `engine_scripts.rs` routing | unit tests; KonoSuba's music plays |
| SceneScript additions | `engine.registerAsset`, `applyUserProperties` (called once with every value, then with changes), `engine.userProperties`, `thisObject` with `getMaterial(n)` for effect scripts, timers with ids, `resizeScreen`, persistent `localStorage` | the public SceneScript docs and the scripts in Wallpaper Engine's default projects (dino_run) | `script_prelude.js`, `script.rs`, `engine_scripts.rs` | unit tests; dino_run switches levels and plays its sounds |
| Varying narrowing | HLSL narrows a wide vector written into a narrower varying (`v_NoiseCoord = v_TexCoord;`) | the cloud motion effect of the user's KonoSuba scene | `shader.rs` `fix_store` for globals, shared `converted` | unit test; the clouds move |
| Particle defaults | Every key's default (separate 2D and 3D sets), vector parsing (missing components 0, a bare rotation is z, colours /255), default emitter rate 10, sprite renderer when none is listed | Wallpaper Engine's binary (the particle parser, read in Ghidra and written up as prose before coding), cross-checked against the asset presets | `particles/model.rs` | yes, an audit test parses every particle file of the assets; unit tests |
| Particle step | Order: age, death events, control points, emission, operators; `starttime` prewarms in 0.05/0.2 s steps; spawn size 0.5; only `movement` moves particles | the same binary (particle runtime), prose notes | `particles/sim.rs` | yes, KonoSuba's light shafts show at t=0; unit tests |
| Particle operators | The maths of all 26 operators and their blend-in/blend-out windows; remap inputs, transforms and outputs; plane, sphere, bounds and quad collisions | the same binary (operator switch), prose notes | `particles/operators.rs` | yes, unit tests; the default projects' particle presets render |
| Instance overrides | `count` scales emission rates, `speed` speeds, `lifetime`/`size` their initializers, `rate` the clock, `alpha` the start alpha; `colorn`/`color` shift colours in HSV or tint them; control-point overrides | the same binary (override patcher), prose notes | `particles/overrides.rs` | yes, KonoSuba's bokeh turn blue as in its preview; unit tests |
| Particle vertices | Corner-vertex layouts, uniforms, combos and sprite-sheet frame values of the engine's particle shaders | the engine's own particle shaders in our asset tree, and the binary's vertex builder | `particles/geometry.rs`, `engine.rs` `particle_draw` | yes, presets and KonoSuba |
| Rope shader fix | The asset rope vertex shader subtracts 1 from positions and writes `.w` of a float | our own asset shader `genericropeparticle.vert` | `engine.rs` `load_rope_shader` patches the source in memory | yes, lightning presets |
| Simplex noise | 1D/2D/3D simplex noise with the standard gradient sets | the public description of the algorithm; our own shuffled permutation, no table copied | `particles/noise.rs` | yes, unit tests |

## Provenance audit, 2026-10-22 (plan item A6)

Compared every file of `SceneRenderer/src`, `SceneRenderer/examples` and `SceneRenderer/tests`
against `RenderService/crates`, `RenderService/external` and the C++ sources, with a script:

| Check | Result |
|---|---|
| Comment lines (8 words or 45 characters or more) found verbatim in their tree | 0 |
| Three-line code blocks (60 characters or more) found verbatim in their tree | 0 |
| Single code lines of 30 characters or more found verbatim | 20, all Rust or Metal idioms (`use std::collections::HashMap;`, `#[derive(Debug, Clone, Copy, PartialEq, Eq)]`, `fn fmt(&self, f: &mut std::fmt::Formatter<'_>)`, `objc2::rc::autoreleasepool(|_| {`, ...) |
| Module layout | ours: 8 flat modules; theirs: `crates/core`, `crates/shader`, `crates/bridge` with different internal splits. No file-to-file correspondence |
| Reserved-word and built-in tables | ours: a nine-word GLSL 4.50 keyword list. Theirs: per-category tables with different entries; the only word in common is `sample` |
| Engine uniform names | every `g_*` name we use was found in our own asset shaders, except `g_Daytime`, which is part of the engine-shader contract and is not present in the assets. It is a name, not code, and it is also spelled `g_DayTime` by the engine, so we accept both spellings |

Names such as `BindTarget`, `BindSamplerTarget`, `EntryPointResources`, `PipelineOptions`,
`fake_missing_bindings` and `per_entry_point_map` are naga's own MSL backend API, not ours.
`ApplyBlending`, `texSample2D`, `constantshadervalues` and `parallaxDepth` are format facts that
appear in our own scene and shader files.

Nothing was rewritten because of this audit: no match went beyond a common idiom.

## Provenance audit, 2026-10-22 (second pass, before deleting `RenderService/`)

`script.rs`, `script_prelude.js`, `engine_scripts.rs`, `sound.rs`, `puppet.rs` and `mat.rs`
against the whole `RenderService/` tree: no three-line block in common; the only single lines
in common are `pub fn is_empty(&self) -> bool {` and the `Debug::fmt` signature.

## Open provenance items (must be checked before release)
- Our first code in `SceneRenderer/` was written while `RenderService/` was in the same repo. The
  two audits above compared our files against it and found nothing beyond common idioms.
  `RenderService/` is deleted now; it stays in git history (before the deletion commit) if a
  later audit needs it.
- Shader translator: the preprocessor and the rewrite rules are ours. The reserved-word table was
  compared with the GPL translator's tables (different structure, one word in common) and stays as
  it is: the words come from the GLSL 4.50 spec.
- The implicit-conversion fixer of `shader.rs` (plan item B7, 2026-10-22) was written without
  `RenderService/` open: the rules come from the HLSL language rules and from the shaders in our
  own asset tree, the patcher reads naga's own diagnostics. The `LightingV1` chunk is our own; the
  engine's chunk is a binary blob we do not have.
- Attribute any idea that came from a GPL project here, even when the code is rewritten.
