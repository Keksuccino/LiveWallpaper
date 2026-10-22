//! Scene state on the GPU and the per-frame draw.
//!
//! Everything that only changes with user properties (textures, programs, pipelines, uniform
//! defaults and constants) is resolved once into `DrawItem`s; a frame only patches the few
//! engine-driven uniforms (matrices, time) and issues draws.

use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;

use objc2::rc::Retained;
use objc2_metal::*;
use serde_json::Value;

use crate::gpu::{self, Gpu, Pool, Texture, TARGET_FORMAT};
use crate::scene::{floats, Blend, Layer, Material, Scene};
use crate::shader::{self, Program, Uniform};
use crate::tex::Frame;
use crate::vfs::Vfs;
use crate::Error;

type Mat4 = [f32; 16];

const IDENTITY: Mat4 = [
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
];

/// Maps the unit model quad onto a whole render target (y down, like the texture).
const FBO_MVP: Mat4 = [
    2., 0., 0., 0., 0., -2., 0., 0., 0., 0., 0., 0., 0., 0., 0.5, 1.,
];

/// Blur radius in source texels for the blurred background of the blurred-fit mode.
const BLUR_RADIUS: f32 = 32.0;

fn mul(a: &Mat4, b: &Mat4) -> Mat4 {
    let mut out = [0.0; 16];
    for c in 0..4 {
        for r in 0..4 {
            out[c * 4 + r] = (0..4).map(|k| a[k * 4 + r] * b[c * 4 + k]).sum();
        }
    }
    out
}

fn translate(x: f32, y: f32, z: f32) -> Mat4 {
    let mut m = IDENTITY;
    m[12] = x;
    m[13] = y;
    m[14] = z;
    m
}

fn scale(x: f32, y: f32, z: f32) -> Mat4 {
    let mut m = IDENTITY;
    m[0] = x;
    m[5] = y;
    m[10] = z;
    m
}

fn rotate_z(a: f32) -> Mat4 {
    let (s, c) = a.sin_cos();
    let mut m = IDENTITY;
    m[0] = c;
    m[1] = s;
    m[4] = -s;
    m[5] = c;
    m
}

/// Orthographic projection to Metal clip space with z pinned to the middle of the depth range.
fn ortho(l: f32, r: f32, b: f32, t: f32) -> Mat4 {
    let mut m = IDENTITY;
    m[0] = 2.0 / (r - l);
    m[5] = 2.0 / (t - b);
    m[10] = 0.0;
    m[12] = -(r + l) / (r - l);
    m[13] = -(t + b) / (t - b);
    m[14] = 0.5;
    m
}

fn invert_affine_2d(m: &Mat4) -> Mat4 {
    let (a, b, c, d) = (m[0], m[1], m[4], m[5]);
    let det = a * d - b * c;
    if det.abs() < 1e-12 {
        return IDENTITY;
    }
    let (ia, ib, ic, id) = (d / det, -b / det, -c / det, a / det);
    let (tx, ty) = (m[12], m[13]);
    let mut out = IDENTITY;
    out[0] = ia;
    out[1] = ib;
    out[4] = ic;
    out[5] = id;
    out[12] = -(ia * tx + ic * ty);
    out[13] = -(ib * tx + id * ty);
    out
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Dyn {
    Mvp,
    Model,
    ModelInverse,
    ViewProjection,
    MvpInverse,
    Identity,
    Time,
    FrameTime,
    DayTime,
    Screen,
    Pointer,
    Parallax,
    TexResolution(usize),
    TexTexel(usize),
    TexelSize,
    TexelSizeHalf,
    Color4,
    Color3,
    Alpha,
    SpriteRotation,
    SpriteTranslation,
}

impl Dyn {
    /// Changes between frames without any property change.
    fn moves(self) -> bool {
        matches!(
            self,
            Self::Time
                | Self::FrameTime
                | Self::DayTime
                | Self::Pointer
                | Self::Parallax
                | Self::SpriteRotation
                | Self::SpriteTranslation
        )
    }
}

fn engine_uniform(name: &str) -> Option<Dyn> {
    Some(match name {
        "g_ModelViewProjectionMatrix" | "g_EffectModelViewProjectionMatrix" => Dyn::Mvp,
        "g_ModelMatrix" | "g_EffectModelMatrix" | "g_AltModelMatrix" => Dyn::Model,
        "g_ModelMatrixInverse" => Dyn::ModelInverse,
        "g_ViewProjectionMatrix" | "g_AltViewProjectionMatrix" => Dyn::ViewProjection,
        "g_ModelViewProjectionMatrixInverse" | "g_EffectModelViewProjectionMatrixInverse" => {
            Dyn::MvpInverse
        }
        "g_EffectTextureProjectionMatrix"
        | "g_EffectTextureProjectionMatrixInverse"
        | "g_NormalModelMatrix" => Dyn::Identity,
        "g_Time" => Dyn::Time,
        "g_Frametime" => Dyn::FrameTime,
        "g_Daytime" | "g_DayTime" => Dyn::DayTime,
        "g_Screen" => Dyn::Screen,
        "g_PointerPosition" | "g_PointerPositionLast" => Dyn::Pointer,
        "g_ParallaxPosition" => Dyn::Parallax,
        "g_TexelSize" => Dyn::TexelSize,
        "g_TexelSizeHalf" => Dyn::TexelSizeHalf,
        "g_Color4" => Dyn::Color4,
        "g_Color" => Dyn::Color3,
        "g_Alpha" | "g_UserAlpha" => Dyn::Alpha,
        "g_Texture0Rotation" => Dyn::SpriteRotation,
        "g_Texture0Translation" => Dyn::SpriteTranslation,
        _ => {
            let rest = name.strip_prefix("g_Texture")?;
            let digits = rest.find(|c: char| !c.is_ascii_digit())?;
            let index = rest[..digits].parse().ok()?;
            match &rest[digits..] {
                "Resolution" => Dyn::TexResolution(index),
                "Texel" => Dyn::TexTexel(index),
                _ => return None,
            }
        }
    })
}

/// A loaded image: one GPU texture per sprite-sheet image.
#[derive(Debug)]
struct TexEntry {
    images: Vec<Retained<Texture>>,
    /// (texture w, texture h, image w, image h)
    res: [f32; 4],
    frames: Vec<Frame>,
    sampler: usize,
}

impl TexEntry {
    fn frame(&self, time: f32) -> Option<&Frame> {
        let total: f32 = self.frames.iter().map(|f| f.seconds).sum();
        if total <= 0.0 {
            return self.frames.first();
        }
        let mut t = time.rem_euclid(total);
        self.frames.iter().find(|f| {
            t -= f.seconds;
            t < 0.0
        })
    }
}

#[derive(Debug, Clone)]
enum TexSource {
    Image(Rc<TexEntry>),
    /// `previous` or an effect FBO name, resolved at draw time.
    Target(String),
}

#[derive(Debug)]
struct DrawItem {
    pipeline: Retained<gpu::Pipeline>,
    /// (Metal slot, g_TextureN index, source)
    textures: Vec<(u8, usize, TexSource)>,
    vs: Vec<u8>,
    fs: Vec<u8>,
    dynamic: Vec<(bool, Uniform, Dyn)>,
    /// Samples `_rt_FullFrameBuffer`.
    reads_frame: bool,
}

#[derive(Debug)]
struct EffectPassGpu {
    item: DrawItem,
    target: Option<String>,
}

#[derive(Debug)]
struct EffectGpu {
    passes: Vec<EffectPassGpu>,
    fbos: Vec<(String, f32)>,
}

#[derive(Debug)]
struct LayerGpu {
    /// The material draw; `None` for groups.
    base: Option<DrawItem>,
    /// The same material drawn unblended into the first effect buffer.
    base_fx: Option<DrawItem>,
    /// Texture 0 of the base material, used for sizing and the fallback.
    image: Option<Rc<TexEntry>>,
    /// Visible effects only.
    effects: Vec<EffectGpu>,
    blend: Blend,
    /// Placement resolved from the current properties; `None` when hidden or sizeless.
    placed: Option<Placed>,
    /// The effect chain's output never changes (no time, pointer or sprite input), so it is
    /// rendered once and kept.
    still: bool,
    cached: Option<Retained<Texture>>,
}

#[derive(Debug, Clone, Copy)]
struct Placed {
    world: Mat4,
    size: [f32; 2],
    color: [f32; 3],
    alpha: f32,
    compose: bool,
}

/// Values a frame needs.
#[derive(Debug, Clone, Copy)]
pub struct FrameInput {
    pub time: f32,
    pub frame_time: f32,
    pub pointer: [f32; 2],
}

#[derive(Debug, Clone, Copy)]
struct DrawCtx {
    mvp: Mat4,
    model: Mat4,
    view_projection: Mat4,
    target: [f32; 2],
    color: [f32; 3],
    alpha: f32,
    /// Intermediate buffers are rendered at this fraction of the layer's native size;
    /// resolution uniforms still report native sizes, so texel-based kernels keep their look.
    buffer_scale: f32,
}

/// How the scene is mapped onto the target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FitMode {
    /// Cover the target; the overflow is cropped.
    Fill,
    /// Show the whole scene; the rest stays empty.
    Fit,
    /// Stretch the scene onto the target, ignoring the aspect ratio.
    Stretch,
    /// One scene pixel per target pixel.
    Unscaled,
    /// Show the whole scene; a blurred copy of it fills the rest.
    MatchBlurred,
}

pub struct Engine {
    pub gpu: Gpu,
    vfs: Vfs,
    pub scene: Scene,
    pub props: HashMap<String, Value>,
    textures: HashMap<String, Rc<TexEntry>>,
    sources: HashMap<String, Rc<shader::Source>>,
    programs: HashMap<(String, BTreeMap<String, i64>), Rc<Program>>,
    pipelines: HashMap<(usize, Blend, usize), Retained<gpu::Pipeline>>,
    layers: Vec<LayerGpu>,
    pool: Pool,
    pub warnings: Vec<String>,
    samples: usize,
    msaa: Option<Retained<Texture>>,
    white: Rc<TexEntry>,
    black: Rc<TexEntry>,
    /// How the scene is mapped onto the target.
    pub fit: FitMode,
    /// Horizontal and vertical offset, in screen widths and heights.
    pub pan: [f32; 2],
    /// Magnification; 1 shows the scene at its fitted size.
    pub zoom: f32,
}

impl Engine {
    pub fn load(vfs: Vfs, props: HashMap<String, Value>) -> Result<Self, Error> {
        let gpu = Gpu::new()?;
        let mut warnings = Vec::new();
        let scene = Scene::load(&vfs, &mut warnings)?;
        for (kind, n) in &scene.skipped {
            warnings.push(format!("{n} {kind} object(s) not drawn yet"));
        }
        let solid = |rgba| -> Result<Rc<TexEntry>, Error> {
            Ok(Rc::new(TexEntry {
                images: vec![gpu.solid(rgba)?],
                res: [1.0; 4],
                frames: Vec::new(),
                sampler: 1,
            }))
        };
        let (white, black) = (solid([255; 4])?, solid([0, 0, 0, 255])?);
        let mut engine = Self {
            gpu,
            vfs,
            scene,
            props,
            textures: HashMap::new(),
            sources: HashMap::new(),
            programs: HashMap::new(),
            pipelines: HashMap::new(),
            layers: Vec::new(),
            pool: Pool::default(),
            warnings,
            samples: 1,
            msaa: None,
            white,
            black,
            fit: FitMode::Fill,
            pan: [0.0, 0.0],
            zoom: 1.0,
        };
        engine.rebuild();
        Ok(engine)
    }

    /// Re-resolves materials after a property or antialiasing change. Textures, shader sources,
    /// programs and pipelines are cached, so only changed combos compile anything.
    pub fn rebuild(&mut self) {
        let mut layers = Vec::with_capacity(self.scene.layers.len());
        for index in 0..self.scene.layers.len() {
            let layer = self.scene.layers[index].clone();
            // Hidden layers load nothing; a property change that shows them rebuilds.
            let material = layer.material.as_ref().filter(|_| self.visible(index));
            let Some(material) = material else {
                layers.push(LayerGpu {
                    base: None,
                    base_fx: None,
                    image: None,
                    effects: Vec::new(),
                    blend: Blend::Translucent,
                    placed: None,
                    still: false,
                    cached: None,
                });
                continue;
            };
            let has_effects = !layer.effects.is_empty();
            let image = material
                .textures
                .first()
                .cloned()
                .flatten()
                .filter(|t| !t.starts_with("_rt_"))
                .and_then(|t| self.texture(&t));
            let base = match self.draw_item(
                material,
                material.blend,
                TARGET_FORMAT,
                self.samples,
                &[],
                false,
            ) {
                Ok(item) => Some(item),
                Err(e) => {
                    self.warnings.push(format!(
                        "layer {}: {e}; drawing its texture directly",
                        layer.name
                    ));
                    None
                }
            };
            // With effects the base pass renders into an intermediate buffer, replacing it whole.
            let base_fx = if has_effects && base.is_some() {
                // The colour blend mode applies when the finished layer meets the screen.
                let mut plain = material.clone();
                let _ = plain.combos.remove("BLENDMODE");
                self.draw_item(&plain, Blend::Disabled, gpu::FBO_FORMAT, 1, &[], false)
                    .ok()
            } else {
                None
            };
            let mut effects = Vec::new();
            for effect in &layer.effects {
                if !effect.visible.truthy(&self.props) {
                    continue;
                }
                let mut passes = Vec::new();
                let mut failed = None;
                for pass in &effect.passes {
                    match self.draw_item(
                        &pass.material,
                        pass.material.blend,
                        gpu::FBO_FORMAT,
                        1,
                        &pass.binds,
                        true,
                    ) {
                        Ok(item) => passes.push(EffectPassGpu {
                            item,
                            target: pass.target.clone(),
                        }),
                        Err(e) => {
                            failed = Some(e);
                            break;
                        }
                    }
                }
                match failed {
                    Some(e) => self.warnings.push(format!(
                        "layer {}: effect {} skipped: {e}",
                        layer.name, effect.name
                    )),
                    None => effects.push(EffectGpu {
                        passes,
                        fbos: effect
                            .fbos
                            .iter()
                            .map(|f| (f.name.clone(), f.scale.max(1.0)))
                            .collect(),
                    }),
                }
            }
            let placed = self.place(index, &layer, image.as_deref());
            let items = base_fx.iter().chain(
                effects
                    .iter()
                    .flat_map(|e| e.passes.iter().map(|p| &p.item)),
            );
            let still = !effects.is_empty()
                && !base.as_ref().is_some_and(|b| b.reads_frame)
                && image.as_ref().is_none_or(|t| t.frames.len() <= 1)
                && !placed.is_some_and(|p| p.compose)
                && items
                    .into_iter()
                    .all(|i| !i.reads_frame && !i.dynamic.iter().any(|(_, _, d)| d.moves()));
            layers.push(LayerGpu {
                base,
                base_fx,
                image,
                effects,
                blend: material.blend,
                placed,
                still,
                cached: None,
            });
        }
        self.layers = layers;
        // Drop textures nothing draws any more (hidden by a property change).
        self.textures.retain(|_, t| Rc::strong_count(t) > 1);
        let mut seen = std::collections::HashSet::new();
        self.warnings.retain(|w| seen.insert(w.clone()));
    }

    pub fn set_samples(&mut self, samples: usize) {
        let samples = match samples {
            0 | 1 => 1,
            2 | 3 => 2,
            _ => 4,
        };
        if samples != self.samples {
            self.samples = samples;
            self.msaa = None;
            self.rebuild();
        }
    }

    /// Frees intermediate buffers; they are recreated on the next frame.
    pub fn trim(&mut self) {
        self.pool.clear();
        for l in &mut self.layers {
            l.cached = None;
        }
        self.msaa = None;
    }

    fn texture(&mut self, name: &str) -> Option<Rc<TexEntry>> {
        if let Some(t) = self.textures.get(name) {
            return Some(t.clone());
        }
        let loaded = (|| -> Result<TexEntry, Error> {
            let path = format!("materials/{name}.tex");
            let data = self.vfs.read(&path).ok_or(Error::Missing(path))?;
            let tex = crate::tex::decode(&data)?;
            let images = (0..tex.images.len())
                .map(|i| self.gpu.upload(&tex, i))
                .collect::<Result<Vec<_>, _>>()?;
            let sampler = usize::from(!tex.clamp) + 2 * usize::from(tex.nearest);
            Ok(TexEntry {
                images,
                res: [
                    tex.texture_width as f32,
                    tex.texture_height as f32,
                    tex.image_width as f32,
                    tex.image_height as f32,
                ],
                frames: tex.frames,
                sampler,
            })
        })();
        match loaded {
            Ok(entry) => {
                let entry = Rc::new(entry);
                let _ = self.textures.insert(name.to_string(), entry.clone());
                Some(entry)
            }
            Err(e) => {
                self.warnings.push(format!("texture {name}: {e}"));
                None
            }
        }
    }

    fn program(
        &mut self,
        shader_name: &str,
        combos: &BTreeMap<String, i64>,
    ) -> Result<(Rc<Program>, Rc<shader::Source>), Error> {
        let source = match self.sources.get(shader_name) {
            Some(s) => s.clone(),
            None => {
                let s = Rc::new(shader::Source::load(&self.vfs, shader_name)?);
                let _ = self.sources.insert(shader_name.to_string(), s.clone());
                s
            }
        };
        let key = (shader_name.to_string(), combos.clone());
        if let Some(p) = self.programs.get(&key) {
            return Ok((p.clone(), source));
        }
        let program = Rc::new(source.compile(combos)?);
        let _ = self.programs.insert(key, program.clone());
        Ok((program, source))
    }

    fn draw_item(
        &mut self,
        material: &Material,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        binds: &[(String, usize)],
        effect: bool,
    ) -> Result<DrawItem, Error> {
        // Texture sources per g_TextureN index.
        let mut sources: BTreeMap<usize, TexSource> = BTreeMap::new();
        if effect {
            let _ = sources.insert(0, TexSource::Target("previous".into()));
        }
        for (i, name) in material.textures.iter().enumerate() {
            if let Some(name) = name {
                if name.starts_with("_rt_") {
                    let _ = sources.insert(i, TexSource::Target(name.clone()));
                } else if let Some(t) = self.texture(name) {
                    let _ = sources.insert(i, TexSource::Image(t));
                }
            }
        }
        for (name, slot) in binds {
            let _ = sources.insert(*slot, TexSource::Target(name.clone()));
        }

        let shader_name = material.shader.clone();
        let source = match self.sources.get(&shader_name) {
            Some(s) => s.clone(),
            None => {
                let s = Rc::new(shader::Source::load(&self.vfs, &shader_name)?);
                let _ = self.sources.insert(shader_name.clone(), s.clone());
                s
            }
        };
        let mut combos = material.combos.clone();
        for (index, meta) in &source.texture_meta {
            if let Some(combo) = meta["combo"].as_str() {
                if sources.contains_key(index) {
                    let _ = combos.insert(combo.to_string(), 1);
                }
            }
        }
        if let Some(TexSource::Image(t)) = sources.get(&0) {
            if !t.frames.is_empty() {
                let _ = combos.insert("SPRITESHEET".into(), 1);
            }
        }
        let (program, _) = self.program(&shader_name, &combos)?;

        // Shader-declared textures with nothing bound get their annotated default.
        let mut textures = Vec::new();
        for &(index, slot) in program
            .vertex
            .textures
            .iter()
            .chain(&program.fragment.textures)
        {
            let src = match sources.get(&index) {
                Some(s) => s.clone(),
                None => {
                    let default = source
                        .texture_meta
                        .get(&index)
                        .and_then(|m| m["default"].as_str())
                        .unwrap_or("");
                    if default.starts_with("_rt_") {
                        TexSource::Target(default.to_string())
                    } else if default.is_empty() {
                        TexSource::Image(self.white.clone())
                    } else {
                        TexSource::Image(
                            self.texture(default).unwrap_or_else(|| self.black.clone()),
                        )
                    }
                }
            };
            textures.push((slot, index, src));
        }

        let pkey = (
            Rc::as_ptr(&program) as usize,
            blend,
            samples * 1000 + format.0,
        );
        let pipeline = match self.pipelines.get(&pkey) {
            Some(p) => p.clone(),
            None => {
                let p = self.gpu.pipeline(&program, blend, format, samples)?;
                let _ = self.pipelines.insert(pkey, p.clone());
                p
            }
        };

        let mut dynamic = Vec::new();
        let mut stage_bytes = |code: &shader::StageCode, vertex: bool| -> Vec<u8> {
            let mut bytes = vec![0u8; code.ubo_size as usize];
            for u in &code.uniforms {
                if let Some(d) = engine_uniform(&u.name) {
                    dynamic.push((vertex, u.clone(), d));
                    continue;
                }
                let meta = program.uniform_meta.get(&u.name);
                let key = meta.and_then(|m| m["material"].as_str());
                let constant = key.and_then(|k| {
                    material
                        .constants
                        .iter()
                        .find(|(c, _)| c.eq_ignore_ascii_case(k))
                        .map(|(_, v)| v.get(&self.props))
                });
                let value = constant
                    .or_else(|| meta.map(|m| m["default"].clone()))
                    .unwrap_or(Value::Null);
                let mut f = floats(&value);
                // Angles in the editor are degrees for `direction` sliders only when flagged; the
                // files already store radians, so values pass through unchanged.
                if f.is_empty() && u.name == "g_Brightness" {
                    f = vec![1.0];
                }
                write_uniform(&mut bytes, u, &f);
            }
            bytes
        };
        let vs = stage_bytes(&program.vertex, true);
        let fs = stage_bytes(&program.fragment, false);
        let reads_frame = textures
            .iter()
            .any(|(_, _, s)| matches!(s, TexSource::Target(n) if n == "_rt_FullFrameBuffer"));
        Ok(DrawItem {
            pipeline,
            textures,
            vs,
            fs,
            dynamic,
            reads_frame,
        })
    }

    /// Everything about a layer's placement that only properties can change, computed once per
    /// rebuild instead of re-parsing the scene values every frame.
    fn place(&self, index: usize, layer: &Layer, image: Option<&TexEntry>) -> Option<Placed> {
        let size = match (layer.size, image) {
            ([w, h], _) if w > 0.0 && h > 0.0 => [w, h],
            (_, Some(t)) => [t.res[2], t.res[3]],
            _ => return None,
        };
        let mut color = [1.0f32; 3];
        for (o, v) in color.iter_mut().zip(floats(&layer.color.get(&self.props))) {
            *o = v * layer.brightness;
        }
        Some(Placed {
            world: self.world(index, 0),
            size,
            color,
            alpha: floats(&layer.alpha.get(&self.props))
                .first()
                .copied()
                .unwrap_or(1.0),
            compose: layer
                .material
                .as_ref()
                .is_some_and(|m| m.shader == "composelayer"),
        })
    }

    /// Layer world matrix including parents, in design pixels (y up).
    fn world(&self, index: usize, depth: u32) -> Mat4 {
        let layer = &self.scene.layers[index];
        let o = floats(&layer.origin.get(&self.props));
        let s = floats(&layer.scale.get(&self.props));
        let a = floats(&layer.angles.get(&self.props));
        let get = |v: &[f32], i: usize, d: f32| v.get(i).copied().unwrap_or(d);
        // The file stores y down from the top of the design; the renderer works y up.
        let local = mul(
            &mul(
                &translate(get(&o, 0, 0.0), get(&o, 1, 0.0), 0.0),
                &rotate_z(-get(&a, 2, 0.0)),
            ),
            &scale(get(&s, 0, 1.0), get(&s, 1, 1.0), 1.0),
        );
        let parent = layer
            .parent
            .and_then(|p| self.scene.layers.iter().position(|l| l.id == p));
        match parent {
            Some(p) if depth < 32 => mul(&self.world(p, depth + 1), &local),
            _ => local,
        }
    }

    fn visible(&self, index: usize) -> bool {
        let mut layer: Option<&Layer> = self.scene.layers.get(index);
        let mut depth = 0;
        while let Some(l) = layer {
            if !l.visible.truthy(&self.props) || depth > 32 {
                return false;
            }
            layer = l
                .parent
                .and_then(|p| self.scene.layers.iter().find(|x| x.id == p));
            depth += 1;
        }
        true
    }

    /// The part of the design that is on screen, in design units: left, right, top, bottom.
    /// The fit mode decides how much of the design is visible, zoom narrows it further and pan
    /// moves it.
    fn view_rect(&self, tw: f32, th: f32) -> (f32, f32, f32, f32) {
        let (w, h) = (self.scene.width, self.scene.height);
        let (vw, vh) = match self.fit {
            // Cover the target: the smaller axis of the design fits exactly.
            FitMode::Fill => {
                let s = (tw / w).max(th / h);
                (tw / s, th / s)
            }
            // Show all of it: the larger axis of the design fits exactly.
            FitMode::Fit | FitMode::MatchBlurred => {
                let s = (tw / w).min(th / h);
                (tw / s, th / s)
            }
            // The design is mapped onto the target as it is.
            FitMode::Stretch => (w, h),
            // One design pixel per target pixel.
            FitMode::Unscaled => (tw, th),
        };
        let z = self.zoom.max(0.05);
        let (vw, vh) = (vw / z, vh / z);
        let cx = w / 2.0 - self.pan[0] * vw;
        let cy = h / 2.0 - self.pan[1] * vh;
        (cx - vw / 2.0, cx + vw / 2.0, cy - vh / 2.0, cy + vh / 2.0)
    }

    /// The rectangle the design itself covers on the target, in target pixels: x, y, width,
    /// height. Used by the blurred-fit mode, where the rest of the target is filled with a
    /// blurred copy of the same picture.
    fn content_rect(&self, tw: f32, th: f32) -> (f32, f32, f32, f32) {
        let (w, h) = (self.scene.width, self.scene.height);
        let s = (tw / w).min(th / h) * self.zoom.max(0.05);
        let (cw, ch) = (w * s, h * s);
        let x = tw / 2.0 + self.pan[0] * tw - cw / 2.0;
        let y = th / 2.0 + self.pan[1] * th - ch / 2.0;
        (x, y, cw, ch)
    }

    /// Renders one frame into `target` (a drawable or offscreen texture) on `cb`.
    pub fn encode(
        &mut self,
        cb: &gpu::CommandBuffer,
        target: &Texture,
        input: FrameInput,
    ) -> Result<(), Error> {
        let (tw, th) = (target.width() as f32, target.height() as f32);
        if self.samples > 1
            && self
                .msaa
                .as_ref()
                .is_none_or(|m| m.width() != target.width() || m.height() != target.height())
        {
            self.msaa = Some(self.gpu.render_target(
                target.width(),
                target.height(),
                TARGET_FORMAT,
                self.samples,
            )?);
        }
        let msaa = self.msaa.clone();

        // The visible part of the design, in design units. Files are y-down from the design's
        // top-left, which is also Metal's texture orientation.
        let (l, r, t, b) = self.view_rect(tw, th);
        let view_projection = ortho(l, r, b, t);
        // Screen pixels per design pixel.
        let fit = tw / (r - l).max(0.001);

        let c = self.scene.clear_color;
        // The blurred-fit mode draws the scene into a texture first: the empty part of the
        // target is then filled with a blurred copy of the same picture.
        let blurred = self.fit == FitMode::MatchBlurred;
        let scene_tex = if blurred {
            Some(self.pool.take(&self.gpu, target.width(), target.height())?)
        } else {
            None
        };
        let scene_target: &Texture = scene_tex.as_ref().map_or(target, |t| &**t);
        let mut main = Some(gpu::begin(
            cb,
            scene_target,
            msaa.as_deref(),
            Some([c[0] as f64, c[1] as f64, c[2] as f64, 1.0]),
        )?);
        let screen = [tw, th];
        // Screen copy for `_rt_FullFrameBuffer` readers, refreshed before each such draw.
        let mut frame_copy: HashMap<String, Retained<Texture>> = HashMap::new();

        for li in 0..self.layers.len() {
            let Some(Placed {
                world,
                size,
                color,
                alpha,
                compose,
            }) = self.layers[li].placed
            else {
                continue;
            };
            if self.layers[li].base.is_none() && self.layers[li].image.is_none() {
                continue;
            }
            let image = self.layers[li].image.clone();
            let model = mul(&world, &scale(size[0], size[1], 1.0));
            // Screen pixels per layer pixel. Effects never need more detail than the screen shows.
            let on_screen = fit * world_scale(&world);
            let ctx = DrawCtx {
                mvp: mul(&view_projection, &model),
                model,
                view_projection,
                target: screen,
                color,
                alpha,
                buffer_scale: 1.0,
            };
            let uv = image.as_ref().map_or([1.0, 1.0], |t| {
                [t.res[2] / t.res[0].max(1.0), t.res[3] / t.res[1].max(1.0)]
            });
            let visible_effects: Vec<usize> = (0..self.layers[li].effects.len()).collect();

            if visible_effects.is_empty() || self.layers[li].base_fx.is_none() {
                // A compose layer without effects would redraw what is already behind it.
                if compose {
                    continue;
                }
                if self.layers[li].base.as_ref().is_some_and(|b| b.reads_frame) {
                    main = Some(self.copy_frame(
                        cb,
                        main.take(),
                        scene_target,
                        msaa.as_deref(),
                        &mut frame_copy,
                    )?);
                }
                let enc = main
                    .as_ref()
                    .ok_or_else(|| Error::Metal("main pass".into()))?;
                match &self.layers[li].base {
                    Some(item) if visible_effects.is_empty() => {
                        self.draw(enc, item, &ctx, uv, input, None, &frame_copy, None);
                        // Copied again by the next reader, so it need not stay alive meanwhile.
                        if let Some(t) = frame_copy.remove("_rt_FullFrameBuffer") {
                            self.pool.give(t);
                        }
                    }
                    _ => {
                        if let Some(t) = &image {
                            self.composite(
                                enc,
                                &t.images[0],
                                t.sampler,
                                self.layers[li].blend,
                                &ctx,
                                uv,
                            )?;
                        }
                    }
                }
                continue;
            }

            let k = on_screen.clamp(0.05, 1.0);
            let (fw, fh) = (
                (size[0] * k).round().max(1.0) as usize,
                (size[1] * k).round().max(1.0) as usize,
            );
            if let Some(cached) = self.layers[li]
                .cached
                .clone()
                .filter(|c| c.width() == fw && c.height() == fh)
            {
                let enc = main
                    .as_ref()
                    .ok_or_else(|| Error::Metal("main pass".into()))?;
                self.composite(enc, &cached, 0, self.layers[li].blend, &ctx, [1.0, 1.0])?;
                continue;
            }

            // Effects: base -> A, each pass A -> B (or a named buffer), swap; then composite A.
            if self.layers[li]
                .base_fx
                .as_ref()
                .is_some_and(|b| b.reads_frame)
            {
                main = Some(self.copy_frame(
                    cb,
                    main.take(),
                    scene_target,
                    msaa.as_deref(),
                    &mut frame_copy,
                )?);
            }
            if let Some(enc) = main.take() {
                enc.endEncoding();
            }
            let mut prev = self.pool.take(&self.gpu, fw, fh)?;
            let fbo_ctx = DrawCtx {
                mvp: FBO_MVP,
                model: IDENTITY,
                view_projection: IDENTITY,
                target: size,
                color,
                alpha: 1.0,
                buffer_scale: k,
            };
            {
                let enc = gpu::begin(cb, &prev, None, Some([0.0; 4]))?;
                if let Some(item) = &self.layers[li].base_fx {
                    // A compose layer samples the screen behind it, so it keeps its real placement.
                    let base_ctx = if compose {
                        DrawCtx {
                            color: [1.0; 3],
                            ..ctx
                        }
                    } else {
                        DrawCtx {
                            color: [1.0; 3],
                            ..fbo_ctx
                        }
                    };
                    self.draw(&enc, item, &base_ctx, uv, input, None, &frame_copy, None);
                }
                enc.endEncoding();
            }
            if let Some(t) = frame_copy.remove("_rt_FullFrameBuffer") {
                self.pool.give(t);
            }
            for &ei in &visible_effects {
                let effect = &self.layers[li].effects[ei];
                let mut named = frame_copy.clone();
                for (name, div) in &effect.fbos {
                    let (w, h) = (
                        ((fw as f32) / div).max(1.0) as usize,
                        ((fh as f32) / div).max(1.0) as usize,
                    );
                    let _ = named.insert(name.clone(), self.pool.take(&self.gpu, w, h)?);
                }
                for pass in &effect.passes {
                    let out = match &pass.target {
                        Some(name) => named
                            .get(name)
                            .cloned()
                            .ok_or_else(|| Error::Format(format!("unknown buffer {name}")))?,
                        None => self.pool.take(&self.gpu, fw, fh)?,
                    };
                    let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
                    let pctx = DrawCtx {
                        target: [out.width() as f32 / k, out.height() as f32 / k],
                        ..fbo_ctx
                    };
                    self.draw(
                        &enc,
                        &pass.item,
                        &pctx,
                        [1.0, 1.0],
                        input,
                        Some(&prev),
                        &named,
                        None,
                    );
                    enc.endEncoding();
                    if pass.target.is_none() {
                        self.pool.give(std::mem::replace(&mut prev, out));
                    }
                }
                for (name, _) in &effect.fbos {
                    if let Some(t) = named.remove(name) {
                        self.pool.give(t);
                    }
                }
            }
            if self.layers[li].still {
                // Keep a copy outside the transient heap; later frames composite it directly.
                let keep = self.gpu.render_target(fw, fh, gpu::FBO_FORMAT, 1)?;
                let blit = cb
                    .blitCommandEncoder()
                    .ok_or_else(|| Error::Metal("blit encoder".into()))?;
                // SAFETY: same size and format.
                unsafe { blit.copyFromTexture_toTexture(&prev, &keep) };
                blit.endEncoding();
                self.layers[li].cached = Some(keep);
            }
            // With a colour blend mode, the layer's own material blends the result with the screen.
            let blended = self.layers[li].base.as_ref().filter(|b| b.reads_frame);
            let enc = match blended {
                Some(_) => {
                    self.copy_frame(cb, None, scene_target, msaa.as_deref(), &mut frame_copy)?
                }
                None => gpu::begin(cb, scene_target, msaa.as_deref(), None)?,
            };
            match &self.layers[li].base {
                Some(item) if item.reads_frame => {
                    self.draw(
                        &enc,
                        item,
                        &ctx,
                        [1.0, 1.0],
                        input,
                        None,
                        &frame_copy,
                        Some(&prev),
                    );
                    if let Some(t) = frame_copy.remove("_rt_FullFrameBuffer") {
                        self.pool.give(t);
                    }
                }
                _ => self.composite(&enc, &prev, 0, self.layers[li].blend, &ctx, [1.0, 1.0])?,
            }
            self.pool.give(prev);
            main = Some(enc);
        }
        if let Some(enc) = main {
            enc.endEncoding();
        }
        if let Some(scene_tex) = scene_tex {
            // The scene is on its own texture; put a blurred copy of it behind and the sharp
            // picture on top, so the empty part of the target is not bare.
            let (x, y, cw, ch) = self.content_rect(tw, th);
            let qw = ((cw / 4.0).round() as usize).max(1);
            let qh = ((ch / 4.0).round() as usize).max(1);
            let bg = self.blur_frame(cb, &scene_tex, [x / tw, y / th, cw / tw, ch / th], qw, qh)?;
            let enc = gpu::begin(cb, target, None, Some([0.0, 0.0, 0.0, 1.0]))?;
            // The blurred copy covers the whole target.
            let crop = cover_crop(cw / ch, tw / th);
            self.composite_rect(&enc, &bg, 0, Blend::Normal, 1, FBO_MVP, crop, [1.0; 3], 1.0)?;
            // The picture itself keeps its place.
            let mvp = sub_rect_mvp(x, y, cw, ch, tw, th);
            self.composite_rect(
                &enc,
                &scene_tex,
                0,
                Blend::Normal,
                1,
                mvp,
                [x / tw, y / th, (x + cw) / tw, (y + ch) / th],
                [1.0; 3],
                1.0,
            )?;
            enc.endEncoding();
            self.pool.give(bg);
            self.pool.give(scene_tex);
        }
        for (_, t) in frame_copy {
            self.pool.give(t);
        }
        self.pool.end_frame(&self.gpu);
        Ok(())
    }

    /// Ends the main pass, copies the target into `_rt_FullFrameBuffer` and reopens the pass.
    fn copy_frame(
        &mut self,
        cb: &gpu::CommandBuffer,
        main: Option<Retained<gpu::Encoder>>,
        target: &Texture,
        msaa: Option<&Texture>,
        frame_copy: &mut HashMap<String, Retained<Texture>>,
    ) -> Result<Retained<gpu::Encoder>, Error> {
        if let Some(enc) = main {
            enc.endEncoding();
        }
        let copy = match frame_copy.remove("_rt_FullFrameBuffer") {
            Some(t) => t,
            None => self.pool.take(&self.gpu, target.width(), target.height())?,
        };
        let blit = cb
            .blitCommandEncoder()
            .ok_or_else(|| Error::Metal("blit encoder".into()))?;
        // SAFETY: same size and format; the target is not framebuffer-only when this runs
        // (see `reads_framebuffer`).
        unsafe { blit.copyFromTexture_toTexture(target, &copy) };
        blit.endEncoding();
        let _ = frame_copy.insert("_rt_FullFrameBuffer".into(), copy);
        gpu::begin(cb, target, msaa, None)
    }

    /// Whether some draw samples the screen; the drawable must then be readable.
    pub fn reads_framebuffer(&self) -> bool {
        self.layers
            .iter()
            .flat_map(|l| l.base.iter().chain(&l.base_fx))
            .any(|i| i.reads_frame)
    }

    fn composite(
        &mut self,
        enc: &gpu::Encoder,
        tex: &Texture,
        sampler: usize,
        blend: Blend,
        ctx: &DrawCtx,
        uv: [f32; 2],
    ) -> Result<(), Error> {
        self.composite_rect(
            enc,
            tex,
            sampler,
            blend,
            self.samples,
            ctx.mvp,
            [0.0, 0.0, uv[0], uv[1]],
            ctx.color,
            ctx.alpha,
        )
    }

    /// Draws a texture over the area the matrix maps the unit quad onto, taking the part of the
    /// texture the rectangle names.
    #[allow(clippy::too_many_arguments)]
    fn composite_rect(
        &mut self,
        enc: &gpu::Encoder,
        tex: &Texture,
        sampler: usize,
        blend: Blend,
        samples: usize,
        mvp: Mat4,
        rect: [f32; 4],
        color: [f32; 3],
        alpha: f32,
    ) -> Result<(), Error> {
        let pipeline = self.gpu.composite(blend, TARGET_FORMAT, samples)?;
        enc.setRenderPipelineState(&pipeline);
        let mut u = [0f32; 20];
        u[..16].copy_from_slice(&mvp);
        u[16..19].copy_from_slice(&color);
        u[19] = alpha;
        let bytes: Vec<u8> = u.iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(enc, true, &bytes, 0);
        gpu::set_bytes(enc, false, &bytes, 0);
        gpu::set_bytes(
            enc,
            true,
            &quad_rect(rect),
            shader::VERTEX_BUFFER_SLOT as usize,
        );
        // SAFETY: slot 0 exists in the composite shader; the texture outlives the encoder's use.
        unsafe {
            enc.setFragmentTexture_atIndex(Some(tex), 0);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[sampler]), 0);
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4);
        }
        Ok(())
    }

    /// A blurred copy of the part of `src` the rectangle names, in a texture of `w` by `h`.
    fn blur_frame(
        &mut self,
        cb: &gpu::CommandBuffer,
        src: &Texture,
        rect: [f32; 4],
        w: usize,
        h: usize,
    ) -> Result<Retained<Texture>, Error> {
        let tmp = self.pool.take(&self.gpu, w, h)?;
        let out = self.pool.take(&self.gpu, w, h)?;
        {
            let enc = gpu::begin(cb, &tmp, None, Some([0.0; 4]))?;
            let dir = (BLUR_RADIUS / src.width().max(1) as f32, 0.0);
            self.blur_pass(&enc, src, rect, dir)?;
            enc.endEncoding();
        }
        {
            let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
            let dir = (0.0, BLUR_RADIUS / tmp.height().max(1) as f32);
            self.blur_pass(&enc, &tmp, [0.0, 0.0, 1.0, 1.0], dir)?;
            enc.endEncoding();
        }
        self.pool.give(tmp);
        Ok(out)
    }

    /// One blur pass: samples the source along `dir` (in source texels).
    fn blur_pass(
        &mut self,
        enc: &gpu::Encoder,
        src: &Texture,
        rect: [f32; 4],
        dir: (f32, f32),
    ) -> Result<(), Error> {
        let pipeline = self.gpu.blur_pipeline(1)?;
        enc.setRenderPipelineState(&pipeline);
        let mut u = [0f32; 24];
        u[..16].copy_from_slice(&FBO_MVP);
        u[16..20].copy_from_slice(&rect);
        u[20] = dir.0;
        u[21] = dir.1;
        let bytes: Vec<u8> = u.iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(enc, true, &bytes, 0);
        gpu::set_bytes(enc, false, &bytes, 0);
        gpu::set_bytes(
            enc,
            true,
            &quad_rect([0.0, 0.0, 1.0, 1.0]),
            shader::VERTEX_BUFFER_SLOT as usize,
        );
        // SAFETY: slot 0 exists in the blur shader; the texture outlives the encoder's use.
        unsafe {
            enc.setFragmentTexture_atIndex(Some(src), 0);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[0]), 0);
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4);
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn draw(
        &self,
        enc: &gpu::Encoder,
        item: &DrawItem,
        ctx: &DrawCtx,
        uv: [f32; 2],
        input: FrameInput,
        prev: Option<&Retained<Texture>>,
        named: &HashMap<String, Retained<Texture>>,
        tex0: Option<&Texture>,
    ) {
        enc.setRenderPipelineState(&item.pipeline);
        // Resolve textures first: their sizes feed the resolution uniforms.
        let mut bound: Vec<(u8, usize, &Texture, usize, [f32; 4])> = Vec::new();
        let mut sprite: Option<(Frame, [f32; 4])> = None;
        for (slot, index, src) in &item.textures {
            if let (0, Some(t)) = (*index, tex0) {
                let (w, h) = (t.width() as f32, t.height() as f32);
                bound.push((*slot, 0, t, 0, [w, h, w, h]));
                continue;
            }
            match src {
                TexSource::Image(t) => {
                    let mut img = 0;
                    if *index == 0 {
                        if let Some(f) = t.frame(input.time) {
                            img = f.image.min(t.images.len() - 1);
                            sprite = Some((*f, t.res));
                        }
                    }
                    bound.push((*slot, *index, &t.images[img], t.sampler, t.res));
                }
                TexSource::Target(name) => {
                    let tex = if name == "previous" {
                        prev
                    } else {
                        named.get(name)
                    };
                    let tex = tex.map(|t| &**t).unwrap_or(&*self.black.images[0]);
                    // The screen copy is real size; effect buffers report their native size.
                    let k = if name == "_rt_FullFrameBuffer" {
                        1.0
                    } else {
                        ctx.buffer_scale
                    };
                    let (w, h) = (tex.width() as f32 / k, tex.height() as f32 / k);
                    bound.push((*slot, *index, tex, 0, [w, h, w, h]));
                }
            }
        }
        let res = |n: usize| bound.iter().find(|b| b.1 == n).map_or([1.0; 4], |b| b.4);

        let mut vs = item.vs.clone();
        let mut fs = item.fs.clone();
        let mvp_inv = invert_affine_2d(&ctx.mvp);
        for (vertex, u, d) in &item.dynamic {
            let v: Vec<f32> = match d {
                Dyn::Mvp => ctx.mvp.to_vec(),
                Dyn::Model => ctx.model.to_vec(),
                Dyn::ModelInverse => invert_affine_2d(&ctx.model).to_vec(),
                Dyn::ViewProjection => ctx.view_projection.to_vec(),
                Dyn::MvpInverse => mvp_inv.to_vec(),
                Dyn::Identity => IDENTITY.to_vec(),
                Dyn::Time => vec![input.time],
                Dyn::FrameTime => vec![input.frame_time],
                Dyn::DayTime => vec![day_time()],
                Dyn::Screen => vec![
                    ctx.target[0],
                    ctx.target[1],
                    ctx.target[0] / ctx.target[1].max(1.0),
                ],
                Dyn::Pointer => input.pointer.to_vec(),
                Dyn::Parallax => vec![input.pointer[0] - 0.5, input.pointer[1] - 0.5],
                Dyn::TexResolution(n) => res(*n).to_vec(),
                Dyn::TexTexel(n) => {
                    let r = res(*n);
                    vec![1.0 / r[0].max(1.0), 1.0 / r[1].max(1.0), r[0], r[1]]
                }
                Dyn::TexelSize => vec![1.0 / ctx.target[0].max(1.0), 1.0 / ctx.target[1].max(1.0)],
                Dyn::TexelSizeHalf => {
                    vec![0.5 / ctx.target[0].max(1.0), 0.5 / ctx.target[1].max(1.0)]
                }
                Dyn::Color4 => vec![ctx.color[0], ctx.color[1], ctx.color[2], ctx.alpha],
                Dyn::Color3 => ctx.color.to_vec(),
                Dyn::Alpha => vec![ctx.alpha],
                Dyn::SpriteRotation => match sprite {
                    Some((f, r)) => vec![
                        f.width_x / r[0],
                        f.width_y / r[1],
                        f.height_x / r[0],
                        f.height_y / r[1],
                    ],
                    None => vec![1.0, 0.0, 0.0, 1.0],
                },
                Dyn::SpriteTranslation => match sprite {
                    Some((f, r)) => vec![f.x / r[0], f.y / r[1]],
                    None => vec![0.0, 0.0],
                },
            };
            write_uniform(if *vertex { &mut vs } else { &mut fs }, u, &v);
        }
        gpu::set_buffer_or_bytes(&self.gpu, enc, true, &vs, 0);
        gpu::set_buffer_or_bytes(&self.gpu, enc, false, &fs, 0);
        gpu::set_bytes(enc, true, &quad(uv), shader::VERTEX_BUFFER_SLOT as usize);
        for (slot, _, tex, sampler, _) in bound {
            let slot = slot as usize;
            // SAFETY: slots come from the program's own binding map; resources outlive the frame.
            unsafe {
                enc.setVertexTexture_atIndex(Some(tex), slot);
                enc.setFragmentTexture_atIndex(Some(tex), slot);
                enc.setVertexSamplerState_atIndex(Some(&self.gpu.samplers[sampler]), slot.min(15));
                enc.setFragmentSamplerState_atIndex(
                    Some(&self.gpu.samplers[sampler]),
                    slot.min(15),
                );
            }
        }
        // SAFETY: a 4-vertex strip from the bytes set above.
        unsafe {
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4)
        };
    }

    /// Whether frames differ over time. Static scenes draw once and then idle.
    pub fn is_animated(&self) -> bool {
        let items = self.layers.iter().flat_map(|l| {
            l.base.iter().chain(
                l.effects
                    .iter()
                    .flat_map(|e| e.passes.iter().map(|p| &p.item)),
            )
        });
        let moving = |d: &Dyn| d.moves();
        let sprites = self
            .layers
            .iter()
            .filter_map(|l| l.image.as_ref())
            .any(|t| t.frames.len() > 1);
        sprites
            || self.scene.parallax.is_some()
            || items
                .into_iter()
                .any(|i| i.dynamic.iter().any(|(_, _, d)| moving(d)))
    }

    pub fn texture_memory(&self) -> usize {
        self.textures
            .values()
            .flat_map(|t| &t.images)
            .map(|t| MTLAllocation::allocatedSize(&**t))
            .sum()
    }
}

/// Length of the world matrix's x and y axes, the larger one.
fn world_scale(m: &Mat4) -> f32 {
    m[0].hypot(m[1]).max(m[4].hypot(m[5]))
}

/// Centred unit quad as a triangle strip, y down; texcoord (0, 0) is the image's top-left.
fn quad(uv: [f32; 2]) -> Vec<u8> {
    quad_rect([0.0, 0.0, uv[0], uv[1]])
}

/// The same quad, but taking the part of the texture the rectangle names: left, top, right,
/// bottom in texture coordinates.
fn quad_rect(r: [f32; 4]) -> Vec<u8> {
    let (l, r_, b, t) = (-0.5f32, 0.5, 0.5, -0.5);
    let (u0, v0, u1, v1) = (r[0], r[1], r[2], r[3]);
    let v = [
        [l, b, 0.0, u0, v1],
        [r_, b, 0.0, u1, v1],
        [l, t, 0.0, u0, v0],
        [r_, t, 0.0, u1, v0],
    ];
    v.iter()
        .flatten()
        .flat_map(|f: &f32| f.to_le_bytes())
        .collect()
}

/// The part of a picture that covers a target of another shape: the wider axis is cropped.
fn cover_crop(content: f32, target: f32) -> [f32; 4] {
    if content > target {
        let d = (1.0 - target / content) / 2.0;
        [d, 0.0, 1.0 - d, 1.0]
    } else {
        let d = (1.0 - content / target) / 2.0;
        [0.0, d, 1.0, 1.0 - d]
    }
}

/// Matrix that maps the unit quad onto a rectangle of the target, in target pixels.
fn sub_rect_mvp(x: f32, y: f32, w: f32, h: f32, tw: f32, th: f32) -> Mat4 {
    // Metal's clip space has y up, the target's rows count from the top.
    let (nx0, nx1) = (2.0 * x / tw - 1.0, 2.0 * (x + w) / tw - 1.0);
    let (ny0, ny1) = (1.0 - 2.0 * (y + h) / th, 1.0 - 2.0 * y / th);
    let sx = (nx1 - nx0) / 2.0;
    let sy = (ny1 - ny0) / 2.0;
    let tx = (nx0 + nx1) / 2.0;
    let ty = (ny0 + ny1) / 2.0;
    mul(&scale(sx, sy, 1.0), &mul(&translate(tx, ty, 0.0), &FBO_MVP))
}

fn day_time() -> f32 {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    // shortcut: UTC day fraction; local time needs the time zone offset from Foundation.
    (secs % 86_400) as f32 / 86_400.0
}

/// Writes `v` into a std140 block slot, element by element.
fn write_uniform(bytes: &mut [u8], u: &Uniform, v: &[f32]) {
    let per = (u.rows * u.cols) as usize;
    if per == 0 || v.is_empty() {
        return;
    }
    let mut put = |offset: usize, x: f32| {
        if let Some(dst) = bytes.get_mut(offset..offset + 4) {
            let raw = if u.is_int {
                (x as i32).to_le_bytes()
            } else {
                x.to_le_bytes()
            };
            dst.copy_from_slice(&raw);
        }
    };
    // Matrices may come as 4x4 for smaller uniforms (mat3 from a mat4).
    let per_src = if u.cols > 1 && v.len() == 16 * u.count as usize {
        16
    } else {
        per
    };
    for e in 0..u.count as usize {
        let src = match v.get(e * per_src..(e + 1) * per_src) {
            Some(s) => s,
            None if e == 0 => v,
            None => break,
        };
        let base = u.offset as usize + e * u.stride as usize;
        if u.cols > 1 {
            // Source is column-major 4x4 when it has 16 values; take the top-left block.
            let src_rows = if src.len() == 16 { 4 } else { u.rows as usize };
            for c in 0..u.cols as usize {
                for r in 0..u.rows as usize {
                    if let Some(&x) = src.get(c * src_rows + r) {
                        put(base + c * u.col_stride as usize + r * 4, x);
                    }
                }
            }
        } else {
            for (r, &x) in src.iter().take(u.rows as usize).enumerate() {
                put(base + r * 4, x);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mat3_uniform_takes_top_left_of_mat4() {
        let u = Uniform {
            name: "m".into(),
            offset: 0,
            rows: 3,
            cols: 3,
            col_stride: 16,
            count: 1,
            stride: 0,
            is_int: false,
        };
        let mut bytes = vec![0u8; 48];
        let m: Vec<f32> = (0..16).map(|i| i as f32).collect();
        write_uniform(&mut bytes, &u, &m);
        let read = |o: usize| f32::from_le_bytes(bytes[o..o + 4].try_into().unwrap());
        assert_eq!(
            [read(0), read(4), read(8), read(16), read(32), read(40)],
            [0.0, 1.0, 2.0, 4.0, 8.0, 10.0]
        );
    }

    #[test]
    fn affine_inverse_round_trips() {
        let m = mul(
            &translate(3.0, 4.0, 0.0),
            &mul(&rotate_z(0.7), &scale(2.0, 5.0, 1.0)),
        );
        let p = mul(&m, &invert_affine_2d(&m));
        for (a, b) in p.iter().zip(IDENTITY.iter()) {
            assert!((a - b).abs() < 1e-5);
        }
    }
}
