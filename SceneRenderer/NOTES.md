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
| [WallpaperMachine](https://github.com/WallpaperMachine/WallpaperMachine) | GPL-2.0 | Only the vendored copy in `RenderService/` exists in this repo. Do not read it while writing new renderer code. Its behaviour can be observed by running the old app. |
| [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) | GPL-3.0 | Study only. How scene features behave. No code. |
| [open-wallpaper-engine-mac](https://github.com/deepratna-awale/open-wallpaper-engine-mac) | GPL-3.0 | Study only. |
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
| Lock screen | Swap a video into an Aerial slot | vlzuiev/animated (MIT) | planned, Phase D4 | no |
| Lock screen | Alternative approach considered | kageroumado/phosphene (MIT) | not used | n/a |
| Shader macros | `texSample2D`, `texSample2DLod`, `ApplyBlending` are names the engine's own shaders use | our own asset shaders in `WallpaperEngineAssets` | prelude `#define`s in `shader.rs` | yes, grep in the asset tree |
| Engine uniforms | Runtime uniform names (`g_Time`, `g_Screen`, `g_PointerPosition`, `g_ParallaxPosition`, `g_TexelSize`, ...) | our own asset shaders; names are the engine-shader contract | `engine.rs` `engine_uniform` maps name to a value kind | yes, every name we use was found in our own asset shaders |
| Reserved words | Words that are legal in 1.20/HLSL but reserved in GLSL 4.50 | GLSL 4.50 spec keyword list | nine-word table in `shader.rs`, renamed with a `lw_` prefix | yes, compared with the GPL translator's tables (see audit) |
| naga MSL output | How to hand naga a resource binding and a pipeline | naga documentation | `shader.rs` `to_msl` | yes |
| Scene keys | `colorBlendMode`, `constantshadervalues`, `parallaxDepth`, `cameraparallax*` | our own scene files | read as plain JSON keys | yes |
| HLSL implicit conversions | HLSL converts between the numeric types, truncates the longer vector of a product and truncates a float used as an index; GLSL does neither | the HLSL language rules (public documentation) and the shaders of our own asset tree, which use all of them | `shader.rs` reads naga's error, patches the source and compiles again, up to eight times | yes, corpus 80 ok / 8 fail, and the four local scenes render |
| `LightingV1` chunk | A scene shader asks for the chunk with `#require LightingV1`; we do not have the engine's chunk, so we write our own | the call sites in our own asset shaders (`generic4.frag` and six more) give the name, the eight parameters and the older `PerformLighting_Deprecated` in `generic3.frag` gives the light uniforms | `shader.rs` `LIGHTING_V1`: a point light with a GGX specular term, the ambient stays with the shader | yes, the seven shaders that ask for it compile, the Reze and Angel scenes draw their layers again |
| PBR term | The specular term of the light chunk | the public Cook-Torrance/GGX description, written out in `shader.rs` `lw_point_light` | our own function, no code taken from anywhere | yes, the chunk compiles and the scenes render |
| Combo values | The combo values are put into the text instead of staying macros | a fact about naga: its preprocessor gives an expanded token the span of the *definition*, which puts the span of an expression that uses a macro in the wrong place | `shader.rs` `expand_combos` writes the value in place of the name | yes, corpus and scenes |
| `BLENDROWCOUNT` | The engine counts the rows of a puppet's blend map per scene | our own asset shader `puppettexturechannels.vert` | `shader.rs` defines it as one row, we do not draw puppets yet | yes, the shader compiles |

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

## Open provenance items (must be checked before release)
- Our first code in `SceneRenderer/` was written while `RenderService/` was in the same repo. The
  audit above (2026-10-22) compared our files against `RenderService/` for copied structure, names
  and comments and found nothing beyond common idioms. Repeat the audit for every file added
  after this date, and especially for code written while reading a GPL source.
- Shader translator: the preprocessor and the rewrite rules are ours. The reserved-word table was
  compared with the GPL translator's tables (different structure, one word in common) and stays as
  it is: the words come from the GLSL 4.50 spec.
- The implicit-conversion fixer of `shader.rs` (plan item B7, 2026-10-22) was written without
  `RenderService/` open: the rules come from the HLSL language rules and from the shaders in our
  own asset tree, the patcher reads naga's own diagnostics. The `LightingV1` chunk is our own; the
  engine's chunk is a binary blob we do not have.
- Attribute any idea that came from a GPL project here, even when the code is rewritten.
