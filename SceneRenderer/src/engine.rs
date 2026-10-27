//! Scene state on the GPU and the per-frame draw.
//!
//! Everything that only changes with user properties (textures, programs, pipelines, uniform
//! defaults and constants) is resolved once into `DrawItem`s; a frame only patches the few
//! engine-driven uniforms (matrices, time) and issues draws.

use std::collections::{BTreeMap, HashMap};
use std::ffi::c_void;
use std::ptr::NonNull;
use std::rc::Rc;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_metal::*;
use serde_json::Value;

use crate::anim_layer::{AnimLayer, Mode};
use crate::clip;
use crate::gpu::{self, Gpu, Pool, Texture, TARGET_FORMAT};
use crate::mat;
use crate::particles;
use crate::physics;
use crate::pose;
use crate::puppet;
use crate::light::Haze;
use crate::scene::{self, floats, Blend, Bound, Layer, Material, ParticleLayer, PuppetLayer, Scene};
use crate::shader::{self, Program, Uniform};
use crate::skin;
use crate::tex::Frame;
use crate::text::{self, TextRenderer, TextSpec};
use crate::video;
use crate::vfs::Vfs;
use crate::Error;

#[path = "engine_scripts.rs"]
mod scripts;

#[path = "engine_models.rs"]
mod models;

type Mat4 = [f32; 16];

const IDENTITY: Mat4 = [
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
];

/// Maps the unit model quad onto a whole render target (y down, like the texture).
const FBO_MVP: Mat4 = [
    2., 0., 0., 0., 0., -2., 0., 0., 0., 0., 0., 0., 0., 0., 0.5, 1.,
];

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
    TexProjectionInverse,
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
    /// Audio spectrum: right channel?, band count.
    Audio(bool, usize),
    /// The 3D scene's camera and lights (see `engine_models.rs`).
    View(models::ViewUniform),
    /// An input of the particle shaders, set per particle draw.
    Particle(particles::ShaderInput),
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
                | Self::Audio(..)
        )
    }
}

fn engine_uniform(name: &str) -> Option<Dyn> {
    if let Some(view) = models::ViewUniform::from_name(name) {
        return Some(Dyn::View(view));
    }
    Some(match name {
        "g_ModelViewProjectionMatrix" | "g_EffectModelViewProjectionMatrix" => Dyn::Mvp,
        "g_ModelMatrix" | "g_EffectModelMatrix" | "g_AltModelMatrix" => Dyn::Model,
        "g_ModelMatrixInverse" => Dyn::ModelInverse,
        "g_ViewProjectionMatrix" | "g_AltViewProjectionMatrix" => Dyn::ViewProjection,
        "g_ModelViewProjectionMatrixInverse" | "g_EffectModelViewProjectionMatrixInverse" => {
            Dyn::MvpInverse
        }
        "g_EffectTextureProjectionMatrixInverse" => Dyn::TexProjectionInverse,
        "g_EffectTextureProjectionMatrix" => Dyn::Identity,
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
        _ if name.starts_with("g_AudioSpectrum") => {
            let rest = name.strip_prefix("g_AudioSpectrum")?.strip_suffix("_v")?;
            let digits = rest.find(|c: char| !c.is_ascii_digit())?;
            Dyn::Audio(&rest[digits..] == "Right", rest[..digits].parse().ok()?)
        }
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
    /// For a text layer: where its bitmap sits and the scale it was rasterised at.
    text: Option<TextQuad>,
    /// The layer draws a skinned mesh instead of a quad.
    puppet: bool,
    /// The effect chain's output never changes (no time, pointer or sprite input), so it is
    /// rendered once and kept.
    still: bool,
    cached: Option<Retained<Texture>>,
    /// Drawn to the screen; a hidden layer is still built when another layer samples its output.
    shown: bool,
}

#[derive(Debug, Clone, Copy)]
struct Placed {
    world: Mat4,
    size: [f32; 2],
    color: [f32; 3],
    alpha: f32,
    compose: bool,
}

#[derive(Debug, Clone, Copy)]
struct TextQuad {
    /// The bitmap inside the layer box (`x, y, w, h`, y down), in design units.
    rect: [f32; 4],
    /// Bitmap pixels per design unit (see `text_raster_scale`).
    scale: f32,
}

/// A particle system bound to its scene layer.
struct ParticleGpu {
    /// Scene layer index, so particles draw in the same order as the other objects.
    layer: usize,
    sim: particles::Simulation,
    /// Per file of the system's tree (indexed like `sim.nodes()`), one draw per renderer.
    draws: Vec<Vec<ParticleDraw>>,
    /// The layer's transform, in design units.
    world: Mat4,
    /// Field of view of the camera perspective systems are drawn through, in radians.
    fov: f32,
    /// This frame's vertices, kept so the next frame reuses the allocation.
    vertices: Vec<f32>,
}

impl ParticleGpu {
    /// Some material samples the screen (refraction).
    fn reads_frame(&self) -> bool {
        self.draws.iter().flatten().any(|d| d.item.reads_frame)
    }
}

/// One renderer of a particle file: its material variant and the indices of its quads.
struct ParticleDraw {
    /// Index into the file's renderers.
    renderer: usize,
    layout: particles::Layout,
    item: DrawItem,
    sheet: Option<particles::SheetInfo>,
    /// Two triangles per quad, for as many quads as the renderer can need.
    indices: Retained<ProtocolObject<dyn MTLBuffer>>,
}

/// Where the particles of a frame are seen from.
struct ParticleView {
    view_projection: Mat4,
    /// The pointer and the view's centre, in design units.
    pointer: [f32; 2],
    center: [f32; 2],
    screen: [f32; 2],
    /// The scene's camera is perspective: systems flagged perspective need no camera of their own.
    perspective_scene: bool,
}

/// A puppet drawn as a skinned mesh.
struct PuppetGpu {
    /// Scene layer index.
    layer: usize,
    model: Rc<puppet::Puppet>,
    /// Inverse of each bone's bind-pose world matrix.
    bind_inverse: Vec<mat::M4>,
    /// Its animation layers, in blending order: the scene's, and those scripts create.
    animations: Vec<AnimLayer>,
    /// Layers that ended this frame (by uid), for scripts' ended callbacks.
    ended: Vec<u32>,
    /// The skeleton's pose, physics and inverse kinematics.
    rig: pose::Rig,
    /// Scene time the animations have played to.
    clock: f32,
    /// The mesh's index buffer, rebuilt when an animation reorders the parts.
    indices: Retained<ProtocolObject<dyn MTLBuffer>>,
    /// The index ranges in the order they are drawn.
    parts: Vec<usize>,
    texture: Option<Rc<TexEntry>>,
    blend: Blend,
    /// The blend map's mesh, drawn over the flat texture before effects.
    channels: Option<Channels>,
}

/// A puppet's blend map ready to draw: its index buffer, the channel atlas, the plain image when
/// its material names a second texture, and its blend.
struct Channels {
    indices: Retained<ProtocolObject<dyn MTLBuffer>>,
    atlas: Option<Rc<TexEntry>>,
    plain: Option<Rc<TexEntry>>,
    blend: Blend,
}

/// What a clipping mask pass draws: a puppet's skinned vertices and ordered indices.
struct MaskDraw<'a> {
    model: &'a puppet::Puppet,
    parts: &'a [usize],
    vb: &'a ProtocolObject<dyn MTLBuffer>,
    indices: &'a ProtocolObject<dyn MTLBuffer>,
    uniform: &'a [u8],
    tex: &'a Texture,
    sampler: usize,
}

/// Where layers draw: the frame's target, or a compose layer's buffer while its children draw.
struct Surface<'a> {
    tex: &'a Texture,
    msaa: Option<&'a Texture>,
    /// The open pass on it, if any.
    main: Option<Retained<gpu::Encoder>>,
    /// Design units to clip space.
    view_projection: Mat4,
    ortho_projection: Mat4,
    /// The part of the design on screen: left, right, top, bottom.
    view: [f32; 4],
    /// Surface pixels per design unit.
    fit: f32,
}

/// What a frame's layers share.
struct Shared {
    /// Screen copy for `_rt_FullFrameBuffer` readers, refreshed before each such draw.
    frame_copy: HashMap<String, Retained<Texture>>,
    /// Effect outputs other layers sample, by `_rt_imageLayerComposite_<id>_a` name. Those
    /// layers run their chain first, off screen; hidden ones never reach the screen.
    composites: HashMap<String, Retained<Texture>>,
    /// The frame's output size: `g_Screen` and the texel sizes in every pass.
    screen: [f32; 2],
}

/// Values a frame needs.
#[derive(Debug, Clone, Copy)]
pub struct FrameInput {
    pub time: f32,
    pub frame_time: f32,
    pub pointer: [f32; 2],
    pub pointer_down: bool,
}

#[derive(Debug, Clone, Copy)]
struct DrawCtx {
    mvp: Mat4,
    model: Mat4,
    view_projection: Mat4,
    /// The scene's output size in pixels. Wallpaper Engine gives `g_Screen`, `g_TexelSize` and
    /// `g_TexelSizeHalf` from it in every pass, effect passes into scaled buffers included.
    target: [f32; 2],
    color: [f32; 3],
    alpha: f32,
    /// Intermediate buffers are rendered at this fraction of the layer's native size;
    /// resolution uniforms still report native sizes, so texel-based kernels keep their look.
    buffer_scale: [f32; 2],
    /// The same for the effect's own buffers (its `fbos`); finer for text (see `text_fbo_scale`).
    fbo_scale: [f32; 2],
    /// The layer's own unit quad (y down) to the screen, and its size in design units. Effect
    /// passes draw a buffer-filling quad, but pointer effects unproject the cursor through these.
    screen_mvp: Mat4,
    size: [f32; 2],
    /// `g_NormalModelMatrix`: the identity for image layers.
    normal_model: Mat4,
    /// The scene's lights reach the draw (models); image layers keep to the ambient colours.
    lit: bool,
}

/// How the scene is placed on the target: Wallpaper Engine's alignment options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Alignment {
    /// Covers the target; the overflow is cropped and `position` picks the part that shows.
    Cover,
    /// Shows the whole scene; `position` places it between the bars this leaves.
    Fill,
    /// One design pixel per target pixel, placed by `x` and `y`.
    Center,
    /// The scene is stretched onto the target, ignoring the aspect ratio.
    Stretch,
    /// Like center, magnified by `zoom`; `x` and `y` can move the scene all the way off the target.
    Free,
}

/// Where and how big the scene is on the target.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Framing {
    pub alignment: Alignment,
    /// Cover and fill: the place along the axis that overflows or has bars, 0...1 (0 = left/top).
    pub position: f32,
    /// Center and free: horizontal and vertical placement, 0...1 (0.5 = centred).
    pub x: f32,
    pub y: f32,
    /// Free: magnification, 0...2 (1 = one design pixel per target pixel).
    pub zoom: f32,
    /// Mirrors the picture left to right.
    pub flip: bool,
    /// Bars the alignment leaves are filled with a blurred copy of the picture.
    pub blur_bars: bool,
}

impl Default for Framing {
    fn default() -> Self {
        Self {
            alignment: Alignment::Cover,
            position: 0.5,
            x: 0.5,
            y: 0.5,
            zoom: 1.0,
            flip: false,
            blur_bars: false,
        }
    }
}

/// The part of a `design`-sized picture a `target`-sized view shows when placed with `framing`, in the picture's
/// units (y down): left, right, top, bottom, with left and right swapped when the framing flips. For pictures the
/// renderer does not draw itself (the service's videos), so they are placed exactly like scenes.
#[uniffi::export]
pub fn framing_view(framing: Framing, design_width: f32, design_height: f32, target_width: f32, target_height: f32) -> Vec<f32> {
    let [l, r, t, b] = framed_view(&framing, [design_width, design_height], [target_width, target_height]);
    if framing.flip {
        vec![r, l, t, b]
    } else {
        vec![l, r, t, b]
    }
}

/// The part of a `design`-sized scene a `target`-sized view shows, in design units (y down):
/// left, right, top, bottom, before camera effects and mirroring. The placement rules and the
/// free zoom curve follow Wallpaper Engine's 2D camera.
fn framed_view(f: &Framing, design: [f32; 2], target: [f32; 2]) -> [f32; 4] {
    let ([w, h], [tw, th]) = (design, target);
    let (x0, y0, vw, vh) = match f.alignment {
        Alignment::Cover | Alignment::Fill => {
            let (sx, sy) = (tw / w, th / h);
            let s = if f.alignment == Alignment::Cover { sx.max(sy) } else { sx.min(sy) };
            let (vw, vh) = (tw / s, th / s);
            // Only one axis differs from the design; on the other one the product is zero.
            ((w - vw) * f.position, (h - vh) * f.position, vw, vh)
        }
        Alignment::Center => ((w - tw) * f.x, (h - th) * f.y, tw, th),
        Alignment::Free => {
            // At 0 or 1 the scene sits just beside the target; the view grows or shrinks around
            // the same placement. The zoom is steep: 2 (k = -0.99) is a hundredfold.
            let k = ((2.0 - f.zoom).powi(4) - 1.0).max(-0.99);
            let x0 = w - f.x * (w + tw) - tw * k * f.x;
            let y0 = h - f.y * (h + th) - th * k * f.y;
            (x0, y0, tw * (1.0 + k), th * (1.0 + k))
        }
        Alignment::Stretch => (0.0, 0.0, w, h),
    };
    [x0, x0 + vw, y0, y0 + vh]
}

/// Wallpaper Engine's colour options and image filter, as its settings store them.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ColorGrade {
    /// "Show colour options": the four sliders below apply.
    pub adjust: bool,
    /// The sliders as fractions of their range, 0...1, 0.5 = unchanged.
    pub brightness: f32,
    pub contrast: f32,
    pub saturation: f32,
    pub hue: f32,
    /// The image filter: a lookup table's name in `materials/lut` ("" = none), and how much of it
    /// is mixed in, 0...1.
    pub filter: String,
    pub filter_strength: f32,
}

/// The colour grade the final pass applies; nothing while both parts are off.
#[derive(Debug, Default)]
struct Grade {
    /// Value scale, contrast, saturation scale and hue shift (turns); `None` when off or neutral.
    adjust: Option<[f32; 4]>,
    /// The filter's lookup table, with its name and strength.
    filter: Option<(String, Retained<Texture>, f32)>,
}

impl Grade {
    fn active(&self) -> bool {
        self.adjust.is_some() || self.filter.is_some()
    }
}

pub struct Engine {
    pub gpu: Gpu,
    vfs: Vfs,
    pub scene: Scene,
    pub props: HashMap<String, Value>,
    textures: HashMap<String, Rc<TexEntry>>,
    /// Video textures and the textures their frames go to.
    videos: Vec<(Retained<Texture>, video::Video)>,
    sources: HashMap<String, Rc<shader::Source>>,
    programs: HashMap<(String, BTreeMap<String, i64>), Rc<Program>>,
    pipelines: HashMap<(usize, Blend, usize), Retained<gpu::Pipeline>>,
    layers: Vec<LayerGpu>,
    /// Layers whose effect output another layer samples as `_rt_imageLayerComposite_<id>_a`,
    /// with that name. X-ray scenes hide the revealed picture and sample it this way.
    composite_refs: Vec<(usize, String)>,
    pool: Pool,
    pub warnings: Vec<String>,
    samples: usize,
    msaa: Option<Retained<Texture>>,
    /// Multisampled attachments of compose layers' buffers, by size.
    compose_msaa: HashMap<(usize, usize), Retained<Texture>>,
    /// Puppet clipping masks, by size and slot.
    clip_masks: HashMap<(usize, usize, usize), Retained<Texture>>,
    white: Rc<TexEntry>,
    /// An identity lookup table, bound while the grade has no filter (its shader always has one).
    neutral_lut: Retained<Texture>,
    black: Rc<TexEntry>,
    /// How the scene is placed on the target.
    pub framing: Framing,
    /// Wallpaper Engine's colour options and image filter, applied by the final pass.
    grade: Grade,
    /// Off: camera parallax no longer follows the pointer (Wallpaper Engine's "mouse parallax"
    /// option); its point settles in the centre and the layers keep their offsets from it.
    pub parallax_enabled: bool,
    /// Text bitmaps, keyed by font, size and string.
    text: TextRenderer,
    /// Fonts by (name, point size).
    fonts: HashMap<(String, u32), Rc<text::Font>>,
    /// Screen pixels per design pixel of the latest frame (0 before the first); text layers
    /// rasterise for it.
    text_fit: f32,
    /// Hides text layers whose string a script computes, e.g. clocks, when a frame is recorded
    /// for a place that cannot update (the lock screen plays a fixed loop).
    pub hide_scripted_text: bool,
    /// Particle systems, one per visible particle layer.
    particles: Vec<ParticleGpu>,
    /// Skinned meshes, one per visible puppet layer.
    puppets: Vec<PuppetGpu>,
    /// Model layers, the camera and the lights.
    models: models::Models,
    /// Camera parallax: the point the camera eases towards the pointer, in design units (y up),
    /// and the scene time it was eased to; `None` before the first frame.
    parallax_point: Option<([f32; 2], f32)>,
    /// Scene time of the frame being drawn; keyframed values are sampled at it.
    time: f32,
    /// Every keyframed value has stopped changing, so layers need no placing every frame.
    timelines_settled: bool,
    /// Camera shake this frame: the view's offset, in design units.
    shake_offset: [f32; 2],
    /// The scene's SceneScript runtime; `None` when the scene has no scripts.
    script_host: Option<crate::script::Host>,
    /// Some script reads or changes puppets: each frame hands them the puppets' poses.
    scripts_use_puppets: bool,
    /// The user properties of type colour (scripts see them as vectors).
    color_properties: Vec<String>,
    /// The file that keeps the scripts' `localStorage` between runs.
    script_storage: Option<std::path::PathBuf>,
    /// Latest audio spectrum, left and right, 0..1 per band.
    pub audio: [Vec<f32>; 2],
    pub sounds: crate::sound::Sounds,
}

impl Engine {
    /// `props` are the user property values to start with; `color_properties` names the colours;
    /// `script_storage` is where scripts keep their `localStorage` (none: it lasts one run).
    pub fn load(
        vfs: Vfs,
        props: HashMap<String, Value>,
        color_properties: Vec<String>,
        script_storage: Option<std::path::PathBuf>,
    ) -> Result<Self, Error> {
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
        // 2x2x2: every corner of the colour cube maps to itself.
        let identity: Vec<u8> = (0..8u8)
            .flat_map(|i| [(i & 1) * 255, ((i >> 1) & 1) * 255, ((i >> 2) & 1) * 255, 255])
            .collect();
        let neutral_lut = gpu.upload_volume(&identity, 2)?;
        let sounds = crate::sound::Sounds::load(&vfs, &scene.sounds, &props, &mut warnings);
        let mut engine = Self {
            gpu,
            vfs,
            scene,
            props,
            textures: HashMap::new(),
            videos: Vec::new(),
            sources: HashMap::new(),
            programs: HashMap::new(),
            pipelines: HashMap::new(),
            layers: Vec::new(),
            composite_refs: Vec::new(),
            pool: Pool::default(),
            warnings,
            samples: 1,
            msaa: None,
            compose_msaa: HashMap::new(),
            clip_masks: HashMap::new(),
            white,
            black,
            framing: Framing::default(),
            grade: Grade::default(),
            parallax_enabled: true,
            neutral_lut,
            text: TextRenderer::new(),
            fonts: HashMap::new(),
            text_fit: 0.0,
            hide_scripted_text: false,
            particles: Vec::new(),
            puppets: Vec::new(),
            models: models::Models::default(),
            parallax_point: None,
            time: 0.0,
            timelines_settled: false,
            shake_offset: [0.0; 2],
            script_host: None,
            scripts_use_puppets: false,
            color_properties,
            script_storage,
            audio: [vec![0.0; 64], vec![0.0; 64]],
            sounds,
        };
        engine.rebuild();
        engine.start_scripts();
        Ok(engine)
    }

    /// A user property changed: materials, layers, sounds and scripts follow it.
    pub fn set_property(&mut self, name: String, value: Value) {
        let _ = self.props.insert(name.clone(), value.clone());
        self.rebuild();
        self.sounds.apply_props(&self.props);
        self.sync_script_layers();
        self.notify_scripts(&serde_json::Map::from_iter([(name, value)]));
    }

    /// Re-resolves materials after a property or antialiasing change. Textures, shader sources,
    /// programs and pipelines are cached, so only changed combos compile anything.
    pub fn rebuild(&mut self) {
        self.pack_lights();
        self.composite_refs = self.find_composite_refs();
        let layers = (0..self.scene.layers.len()).map(|i| self.build_layer(i)).collect();
        self.layers = layers;
        // Running simulations and loaded meshes survive a rebuild; only new layers load.
        let mut old_systems = std::mem::take(&mut self.particles);
        let mut old_puppets = std::mem::take(&mut self.puppets);
        let mut systems = Vec::new();
        let mut settings = None;
        for index in 0..self.scene.layers.len() {
            let Some(layer) = self.scene.layers[index].particles.clone() else {
                continue;
            };
            if !self.visible(index) {
                continue;
            }
            if let Some(i) = old_systems.iter().position(|p| p.layer == index) {
                // Properties may have changed its overrides, its materials' values or the
                // antialiasing its pipelines were made for.
                let mut kept = old_systems.swap_remove(i);
                kept.sim.set_overrides(self.particle_overrides(&layer));
                kept.draws = self.particle_draws(&kept.sim);
                systems.push(kept);
                continue;
            }
            let settings = *settings.get_or_insert_with(|| self.particle_settings());
            match self.particle_system(index, &layer, settings) {
                Ok(system) => systems.push(system),
                Err(e) => self.warnings.push(format!(
                    "layer {}: {e}; particles skipped",
                    self.scene.layers[index].name
                )),
            }
        }
        self.particles = systems;
        let mut puppets = Vec::new();
        for index in 0..self.scene.layers.len() {
            let Some(layer) = self.scene.layers[index].puppet.clone() else {
                continue;
            };
            if !self.visible(index) {
                continue;
            }
            if let Some(i) = old_puppets.iter().position(|p| p.layer == index) {
                let mut kept = old_puppets.swap_remove(i);
                // A property may have toggled one of its animation layers.
                kept.animations = self.puppet_animations(&kept.model, &layer, &kept.animations);
                puppets.push(kept);
                continue;
            }
            match self.puppet_mesh(index, &layer) {
                Ok(mesh) => puppets.push(mesh),
                Err(e) => {
                    // A model we cannot read still has its picture: draw that, unwarped, rather
                    // than leaving a hole in the scene.
                    self.layers[index].puppet = false;
                    self.warnings.push(format!(
                        "layer {}: {e}; drawn as a plain image",
                        self.scene.layers[index].name
                    ));
                }
            }
        }
        self.puppets = puppets;
        self.build_models();
        // Drop textures nothing draws any more (hidden by a property change).
        self.textures.retain(|_, t| Rc::strong_count(t) > 1);
        let mut seen = std::collections::HashSet::new();
        self.warnings.retain(|w| seen.insert(w.clone()));
    }

    /// Redraws the bitmaps of these text layers (new string) without touching the rest.
    pub fn refresh_texts(&mut self, indices: &[usize]) {
        for &i in indices {
            if i < self.layers.len() && self.scene.layers[i].text.is_some() {
                self.layers[i] = self.build_layer(i);
            }
        }
    }

    /// Re-rasterises the text layers whose on-screen scale moved to another step since their
    /// bitmap was made (a new target size or zoom, a scaled layer), before the frame draws them.
    fn fit_texts(&mut self, fit: f32) {
        self.text_fit = fit;
        for i in 0..self.layers.len().min(self.scene.layers.len()) {
            if self.layers[i].text.is_some_and(|t| t.scale != self.text_scale(i)) {
                self.layers[i] = self.build_layer(i);
            }
        }
    }

    /// Bitmap pixels per design unit for text layer `index` at the latest frame's zoom.
    fn text_scale(&self, index: usize) -> f32 {
        // Before the first frame the zoom is unknown; that frame re-rasterises if 1 was wrong.
        let fit = if self.text_fit > 0.0 { self.text_fit } else { 1.0 };
        text_raster_scale(fit * world_scale(&self.world(index, 0)))
    }

    /// Layers that visible layers' materials or effects sample as `_rt_imageLayerComposite_<id>_a`,
    /// directly or through another sampled layer, ordered so each comes before its readers. A
    /// layer in a cycle samples nothing prepared this frame.
    fn find_composite_refs(&self) -> Vec<(usize, String)> {
        // (layer index, buffer name) for every composite a layer samples.
        let sources = |i: usize| -> Vec<(usize, String)> {
            let layer = &self.scene.layers[i];
            let passes = layer.effects.iter().flat_map(|e| e.passes.iter().map(|p| &p.material));
            layer
                .material
                .iter()
                .chain(passes)
                .flat_map(|m| m.textures.iter().flatten())
                .filter_map(|name| {
                    let (id, _) = name.strip_prefix("_rt_imageLayerComposite_")?.rsplit_once('_')?;
                    let id = id.parse::<i64>().ok()?;
                    let target = self.scene.layers.iter().position(|l| l.id == id)?;
                    (target != i).then(|| (target, name.clone()))
                })
                .collect()
        };
        fn visit(
            node: (usize, String),
            sources: &dyn Fn(usize) -> Vec<(usize, String)>,
            visiting: &mut Vec<usize>,
            out: &mut Vec<(usize, String)>,
        ) {
            if visiting.contains(&node.0) || out.iter().any(|(_, n)| *n == node.1) {
                return;
            }
            visiting.push(node.0);
            for s in sources(node.0) {
                visit(s, sources, visiting, out);
            }
            let _ = visiting.pop();
            out.push(node);
        }
        let mut out = Vec::new();
        for i in (0..self.scene.layers.len()).filter(|&i| self.visible(i)) {
            for s in sources(i) {
                visit(s, &sources, &mut vec![i], &mut out);
            }
        }
        out
    }

    /// GPU state of one layer: its draw items, effect chain and placement.
    fn build_layer(&mut self, index: usize) -> LayerGpu {
        let layer = self.scene.layers[index].clone();
        let shown = self.visible(index);
        // Hidden layers load nothing unless another layer samples them; a property change that
        // shows them rebuilds.
        let visible = shown || self.composite_refs.iter().any(|(i, _)| *i == index);
        let text = if visible && layer.text.is_some() {
            self.text_material(&layer, self.text_scale(index))
        } else {
            None
        };
        let material = match (layer.material.as_ref().filter(|_| visible), text) {
            (Some(m), _) => Some((m.clone(), None)),
            (None, Some((m, quad))) => Some((m, Some(quad))),
            (None, None) => None,
        };
        let Some((material, text)) = material else {
            return LayerGpu {
                base: None,
                base_fx: None,
                image: None,
                effects: Vec::new(),
                blend: Blend::Translucent,
                placed: None,
                text: None,
                puppet: false,
                still: false,
                cached: None,
                shown,
            };
        };
        let material = &material;
        let has_effects = !layer.effects.is_empty();
        let image = material
            .textures
            .first()
            .and_then(|t| t.as_deref())
            .filter(|t| !t.starts_with("_rt_"))
            .and_then(|t| self.texture(t));
        let base = match self.draw_item(
            material,
            material.blend,
            TARGET_FORMAT,
            self.samples,
            &[],
            false,
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
            self.draw_item(&plain, Blend::Disabled, gpu::FBO_FORMAT, 1, &[], false, false)
                .ok()
        } else {
            None
        };
        // A colour blend mode on a layer whose own shader cannot blend (a solid layer's `flat`)
        // still applies: the finished effect result meets the screen through the stock image
        // shader, which does. Without this the blend is dropped and a black effect result shows.
        let base = if base_fx.is_some()
            && material.combos.get("BLENDMODE").is_some_and(|&m| m != 0)
            && base.as_ref().is_some_and(|b| !b.reads_frame)
        {
            let wrap = Material {
                shader: "genericimage2".into(),
                textures: vec![None],
                combos: material.combos.clone(),
                constants: HashMap::new(),
                ..material.clone()
            };
            self.draw_item(&wrap, wrap.blend, TARGET_FORMAT, self.samples, &[], false, false)
                .ok()
                .or(base)
        } else {
            base
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
                    false,
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
        LayerGpu {
            base,
            base_fx,
            image,
            effects,
            blend: material.blend,
            placed,
            text,
            puppet: layer.puppet.is_some(),
            still,
            cached: None,
            shown,
        }
    }

    /// Wallpaper Engine's colour options and image filter for the final pass. A filter that
    /// cannot be loaded is left out (with a warning); the colour options still apply.
    pub fn set_grade(&mut self, g: &ColorGrade) {
        // Wallpaper Engine's mapping of its 0...100 sliders (50 = unchanged): brightness scales
        // the HSV value by its square, contrast and saturation by their square roots.
        let (value, contrast, saturation) = (g.brightness * 2.0, g.contrast * 2.0, g.saturation * 2.0);
        let hue = g.hue - 0.5;
        let neutral = value == 1.0 && contrast == 1.0 && saturation == 1.0 && hue == 0.0;
        self.grade.adjust =
            (g.adjust && !neutral).then(|| [value * value, contrast.sqrt(), saturation.sqrt(), hue]);
        if g.filter.is_empty() || g.filter_strength <= 0.0 {
            self.grade.filter = None;
            return;
        }
        if let Some((name, _, strength)) = &mut self.grade.filter {
            if *name == g.filter {
                *strength = g.filter_strength.min(1.0);
                return;
            }
        }
        self.grade.filter = match self.lookup_table(&g.filter) {
            Ok(table) => Some((g.filter.clone(), table, g.filter_strength.min(1.0))),
            Err(e) => {
                self.warnings.push(format!("image filter {}: {e}", g.filter));
                None
            }
        };
    }

    /// One of Wallpaper Engine's colour lookup tables (`materials/lut/<name>.tex`, a volume).
    fn lookup_table(&self, name: &str) -> Result<Retained<Texture>, Error> {
        let path = format!("materials/lut/{name}.tex");
        let data = self.vfs.read(&path).ok_or(Error::Missing(path))?;
        let (size, rgba) = crate::tex::lookup_table(&data)?;
        self.gpu.upload_volume(&rgba, size)
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
        self.trim_models();
    }

    /// Rasterises a text layer at `scale` bitmap pixels per design unit and registers the bitmap
    /// as a texture. The returned material draws it like an image layer, so effects, colour and
    /// alpha work the same way they do for images.
    fn text_material(&mut self, layer: &Layer, scale: f32) -> Option<(Material, TextQuad)> {
        let t = layer.text.as_ref()?;
        let font = match self.font(&t.font, text::em_size(t.point_size)) {
            Ok(f) => f,
            Err(e) => {
                self.warnings
                    .push(format!("layer {}: {e}; text skipped", layer.name));
                return None;
            }
        };
        let spec = TextSpec {
            text: t.value.clone(),
            // The layer's colour and alpha uniforms tint the bitmap, as for image layers.
            color: [1.0; 4],
            opacity: 1.0,
            h_align: text::HAlign::from_scene(Some(&t.horizontal_align)),
            v_align: text::VAlign::from_scene(Some(&t.vertical_align)),
            line_spacing: 1.0,
            padding: t.padding,
            pixels_per_point: scale,
        };
        let bitmap = match self.text.render(&font, &spec) {
            Ok(b) => b,
            Err(e) => {
                self.warnings
                    .push(format!("layer {}: {e}; text skipped", layer.name));
                return None;
            }
        };
        if bitmap.is_empty() {
            return None;
        }
        let texture = match self.upload_bitmap(&bitmap) {
            Ok(t) => t,
            Err(e) => {
                self.warnings
                    .push(format!("layer {}: {e}; text skipped", layer.name));
                return None;
            }
        };
        let key = format!("@text/{}", layer.id);
        let (w, h) = (bitmap.width as f32, bitmap.height as f32);
        let entry = Rc::new(TexEntry {
            images: vec![texture],
            res: [w, h, w, h],
            frames: Vec::new(),
            sampler: 0,
        });
        let _ = self.textures.insert(key.clone(), entry);
        // `VERSION` makes the stock image shader tint by `g_Color4` (the layer's colour and alpha)
        // instead of its brightness and alpha constants, so the text is coloured before the layer's
        // colour blend mode blends it with what is behind it, as Wallpaper Engine does.
        let mut combos = BTreeMap::from([("VERSION".to_string(), 1)]);
        if t.color_blend_mode != 0 {
            let _ = combos.insert("BLENDMODE".to_string(), t.color_blend_mode);
        }
        let material = Material {
            shader: "genericimage2".into(),
            blend: Blend::Translucent,
            textures: vec![Some(key)],
            combos,
            constants: HashMap::new(),
            cull: scene::Cull::None,
            depth_test: false,
            depth_write: false,
        };
        Some((material, TextQuad { rect: bitmap.rect, scale }))
    }

    /// A font from the package or the system, cached per name and point size.
    fn font(&mut self, name: &str, point_size: f32) -> Result<Rc<text::Font>, Error> {
        let key = (name.to_string(), point_size.to_bits());
        if let Some(font) = self.fonts.get(&key) {
            return Ok(font.clone());
        }
        let source = text::FontSource::from_scene(&self.vfs, name);
        let font = Rc::new(text::Font::load(&source, point_size)?);
        let _ = self.fonts.insert(key, font.clone());
        Ok(font)
    }

    /// The puppet's animation layers with the user's property values applied: the scene's (each
    /// keeping its play state in `playing`) and, in their places, those scripts created.
    fn puppet_animations(
        &self,
        model: &puppet::Puppet,
        layer: &PuppetLayer,
        playing: &[AnimLayer],
    ) -> Vec<AnimLayer> {
        let num = |b: &scene::Bound, d: f32| floats(&b.get(&self.props)).first().copied().unwrap_or(d);
        let from_scene = |i: usize| {
            let a = &layer.animations[i];
            let mut out = playing.iter().find(|p| p.from_scene == Some(i)).cloned().unwrap_or_else(|| {
                let mut new = AnimLayer::new(i as u32, model.animations.iter().position(|anim| anim.id as i64 == a.id));
                new.from_scene = Some(i);
                new.blend_in = a.blend_in;
                new.blend_out = a.blend_out;
                new
            });
            out.rate = num(&a.rate, 1.0);
            out.blend = num(&a.blend, 1.0).clamp(0.0, 1.0);
            out.additive = a.additive;
            out.visible = a.visible.truthy(&self.props);
            out.blend_time = a.blend_time;
            out
        };
        if playing.is_empty() {
            return (0..layer.animations.len()).map(from_scene).collect();
        }
        playing
            .iter()
            .map(|p| match p.from_scene {
                Some(i) if i < layer.animations.len() => from_scene(i),
                _ => p.clone(),
            })
            .collect()
    }

    /// Applies a changed rate, blend or visibility of a layer's animation layers (a script sets
    /// them) without restarting the animations.
    pub(super) fn refresh_puppet_animations(&mut self, index: usize) {
        let Some(layer) = self.scene.layers.get(index).and_then(|l| l.puppet.clone()) else {
            return;
        };
        for i in 0..self.puppets.len() {
            if self.puppets[i].layer == index {
                let p = &self.puppets[i];
                let animations = self.puppet_animations(&p.model, &layer, &p.animations);
                self.puppets[i].animations = animations;
            }
        }
    }

    fn puppet_mesh(&mut self, index: usize, layer: &PuppetLayer) -> Result<PuppetGpu, Error> {
        let data = self
            .vfs
            .read(&layer.model)
            .ok_or_else(|| Error::Missing(layer.model.clone()))?;
        let model = Rc::new(puppet::Puppet::parse(&data)?);
        // The skinning transform undoes each bone's bind-pose world matrix.
        let bind_inverse = pose::bind_world(&model.bones).iter().map(mat::invert).collect();
        let animations = self.puppet_animations(&model, layer, &[]);
        let (texture_name, blend) = self
            .scene
            .layers
            .get(index)
            .and_then(|l| l.material.as_ref())
            .map(|m| {
                (
                    m.textures.first().cloned().flatten(),
                    m.blend,
                )
            })
            .unwrap_or((None, Blend::Translucent));
        let texture = texture_name.and_then(|name| self.texture(&name));
        let indices = index_buffer(&self.gpu, &model.indices)?;
        let channels = match &model.blend_map {
            Some(map) if !map.indices.is_empty() => {
                let material = Material::load(&self.vfs, &map.material)?;
                let indices = index_buffer(&self.gpu, &map.indices)?;
                let mut texture = |slot: usize| material.textures.get(slot).cloned().flatten().and_then(|t| self.texture(&t));
                let (atlas, plain) = (texture(0), texture(1));
                Some(Channels { indices, atlas, plain, blend: material.blend })
            }
            _ => None,
        };
        let mut puppet = PuppetGpu {
            layer: index,
            rig: pose::Rig::new(&model),
            parts: (0..model.segments.len()).collect(),
            model,
            bind_inverse,
            animations,
            ended: Vec::new(),
            clock: 0.0,
            indices,
            texture,
            blend,
            channels,
        };
        puppet.pose_bones(None);
        Ok(puppet)
    }

    /// Draws one puppet onto surface `s`: its mesh skinned on the CPU in the current pose, part
    /// by part in draw order where clipping groups mask some parts by others.
    ///
    /// `skin` replaces the puppet's own texture with a layer-sized buffer: the result of the
    /// layer's effects, which run on the flat image (as Wallpaper Engine runs them) so their masks
    /// stay on the parts they were painted on while the mesh moves.
    fn draw_puppet(
        &mut self,
        cb: &gpu::CommandBuffer,
        s: &mut Surface<'_>,
        index: usize,
        ctx: &DrawCtx,
        skin: Option<&Texture>,
    ) -> Result<(), Error> {
        let Some(pi) = self.puppets.iter().position(|p| p.layer == index) else {
            return Ok(());
        };
        if self.puppets[pi].reorder() {
            let indices = self.puppets[pi].ordered_indices();
            self.puppets[pi].indices = index_buffer(&self.gpu, &indices)?;
        }
        let (model, texture, blend, indices) = {
            let p = &self.puppets[pi];
            (p.model.clone(), p.texture.clone(), p.blend, p.indices.clone())
        };
        // Mesh uvs address the image, which a texture padded to a block size does not fill; an
        // effect buffer is the image alone.
        let uv_scale = match (skin, &texture) {
            (None, Some(t)) => [t.res[2] / t.res[0].max(1.0), t.res[3] / t.res[1].max(1.0)],
            _ => [1.0, 1.0],
        };
        let p = &self.puppets[pi];
        let verts = skin::vertices(&model, &p.bones(), &p.rig.world, &p.rig.extras, uv_scale, ctx.color, ctx.alpha);
        if verts.is_empty() || model.indices.is_empty() {
            return Ok(());
        }
        let parts = self.puppets[pi].parts.clone();
        let steps = clip::plan(&model, &parts);
        let ptr = NonNull::new(verts.as_ptr() as *mut c_void)
            .ok_or_else(|| Error::Format("puppet vertex buffer".into()))?;
        // SAFETY: the buffer copies `verts` immediately and outlives the draws.
        let vb = unsafe {
            self.gpu.device.newBufferWithBytes_length_options(
                ptr,
                verts.len(),
                MTLResourceOptions::StorageModeShared,
            )
        }
        .ok_or_else(|| Error::Metal("puppet vertex buffer".into()))?;
        let white = self.white.images[0].clone();
        let (tex, sampler) = match (skin, &texture) {
            (Some(buffer), _) => (buffer, 0),
            (None, Some(t)) => (&*t.images[0], t.sampler),
            (None, None) => (&*white, 0),
        };
        let uniform: Vec<u8> = ctx.mvp.iter().flat_map(|f| f.to_le_bytes()).collect();
        let (mw, mh) = (s.tex.width(), s.tex.height());
        let clip: Vec<u8> = [1.0 / mw as f32, 1.0 / mh as f32, 0.0, 0.0].iter().flat_map(|f| f.to_le_bytes()).collect();
        for step in steps {
            let (first, count, group) = match step {
                clip::Step::Mask(g) => {
                    self.draw_clip_mask(cb, s, &model, &parts, g, &vb, &indices, &uniform, tex, sampler)?;
                    continue;
                }
                clip::Step::Draw { first, count, group } => (first, count, group),
            };
            let enc = s.main.as_ref().ok_or_else(|| Error::Metal("main pass".into()))?;
            let (pass, blend) = match group {
                Some(g) if model.clip_groups[g].flags & 1 != 0 => (gpu::PuppetPass::Clipped, Blend::Additive),
                Some(_) => (gpu::PuppetPass::Clipped, blend),
                None => (gpu::PuppetPass::Plain, blend),
            };
            let pipeline = self.gpu.puppet_pipeline(blend, TARGET_FORMAT, self.samples, pass)?;
            enc.setRenderPipelineState(&pipeline);
            gpu::set_bytes(enc, true, &uniform, 0);
            if let Some(g) = group {
                let inverted = if model.clip_groups[g].flags & 2 != 0 { 1.0f32 } else { 0.0 };
                let mut clip = clip.clone();
                clip[8..12].copy_from_slice(&inverted.to_le_bytes());
                gpu::set_bytes(enc, false, &clip, 1);
                let mask = self.clip_mask(mw, mh, 0)?;
                // SAFETY: slot 1 exists in the clipped shader; the mask outlives the draw.
                unsafe { enc.setFragmentTexture_atIndex(Some(&mask), 1) };
            }
            // SAFETY: slot 0 exists in the mesh shaders; the buffers and texture outlive the draw.
            unsafe {
                enc.setVertexBuffer_offset_atIndex(Some(&vb), 0, shader::VERTEX_BUFFER_SLOT as usize);
                enc.setFragmentTexture_atIndex(Some(tex), 0);
                enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[sampler]), 0);
                enc.drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset(
                    MTLPrimitiveType::Triangle,
                    count,
                    MTLIndexType::UInt16,
                    &indices,
                    first * 2,
                );
            }
        }
        Ok(())
    }

    /// Draws puppet layer `index`'s blend map into `target` (its flat image of `size` units):
    /// each vertex shows its channel by its animated blend value. Does nothing for a puppet
    /// without one.
    fn draw_channels(&mut self, cb: &gpu::CommandBuffer, index: usize, target: &Texture, size: [f32; 2], tint: [f32; 4]) -> Result<(), Error> {
        let Some(p) = self.puppets.iter().find(|p| p.layer == index) else { return Ok(()) };
        let (Some(map), Some(c)) = (&p.model.blend_map, &p.channels) else { return Ok(()) };
        let white = self.white.images[0].clone();
        let atlas = c.atlas.as_ref().map_or(white.clone(), |t| t.images[0].clone());
        let sampler = c.atlas.as_ref().map_or(0, |t| t.sampler);
        // The plain image's uvs address the image, which its texture may pad.
        let ratio = c.plain.as_ref().map_or([1.0, 1.0], |t| [t.res[2] / t.res[0].max(1.0), t.res[3] / t.res[1].max(1.0)]);
        let values = &p.rig.extras.blend_values;
        let mut verts = Vec::with_capacity(map.vertices.len() * 32);
        for v in &map.vertices {
            let z = values.get(usize::from(v.bone_indices[0])).copied().unwrap_or(0.0);
            // Flat image pixels, y down, to clip space.
            let (x, y) = (v.position[0] / size[0].max(1.0) * 2.0 - 1.0, 1.0 - v.position[1] / size[1].max(1.0) * 2.0);
            for f in [x, y, v.uv[0], v.uv[1], v.uv2[0] * ratio[0], v.uv2[1] * ratio[1], z, 0.0] {
                verts.extend_from_slice(&f.to_le_bytes());
            }
        }
        let (indices, count, blend) = (c.indices.clone(), map.indices.len(), c.blend);
        let plain = c.plain.as_ref().map(|t| t.images[0].clone());
        let ptr = NonNull::new(verts.as_ptr() as *mut c_void).ok_or_else(|| Error::Format("blend map vertices".into()))?;
        // SAFETY: the buffer copies the vertices immediately.
        let vb = unsafe { self.gpu.device.newBufferWithBytes_length_options(ptr, verts.len(), MTLResourceOptions::StorageModeShared) }
            .ok_or_else(|| Error::Metal("blend map vertex buffer".into()))?;
        let pass = if plain.is_some() { gpu::PuppetPass::ChannelsOverPlain } else { gpu::PuppetPass::Channels };
        let pipeline = self.gpu.puppet_pipeline(blend, gpu::FBO_FORMAT, 1, pass)?;
        let enc = gpu::begin(cb, target, None, None)?;
        enc.setRenderPipelineState(&pipeline);
        let identity: Vec<u8> = IDENTITY.iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(&enc, true, &identity, 0);
        let tint: Vec<u8> = tint.iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(&enc, false, &tint, 1);
        // SAFETY: the slots exist in the channel shaders; buffers and textures outlive the draw.
        unsafe {
            enc.setVertexBuffer_offset_atIndex(Some(&vb), 0, shader::VERTEX_BUFFER_SLOT as usize);
            enc.setFragmentTexture_atIndex(Some(&atlas), 0);
            if let Some(plain) = &plain {
                enc.setFragmentTexture_atIndex(Some(plain), 1);
            }
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[sampler]), 0);
            enc.drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset(
                MTLPrimitiveType::Triangle,
                count,
                MTLIndexType::UInt16,
                &indices,
                0,
            );
        }
        enc.endEncoding();
        Ok(())
    }

    /// Renders clipping group `g`'s mask in a buffer the size of the surface, as Wallpaper
    /// Engine does: a nested group's ancestors render first, nearest first, each further one and
    /// then the group itself into a second buffer that is multiplied in. The surface's pass ends
    /// and reopens around it.
    #[allow(clippy::too_many_arguments)]
    fn draw_clip_mask(
        &mut self,
        cb: &gpu::CommandBuffer,
        s: &mut Surface<'_>,
        model: &puppet::Puppet,
        parts: &[usize],
        g: usize,
        vb: &ProtocolObject<dyn MTLBuffer>,
        indices: &ProtocolObject<dyn MTLBuffer>,
        uniform: &[u8],
        tex: &Texture,
        sampler: usize,
    ) -> Result<(), Error> {
        if let Some(enc) = s.main.take() {
            enc.endEncoding();
        }
        let (w, h) = (s.tex.width(), s.tex.height());
        let mask = self.clip_mask(w, h, 0)?;
        let chain = clip::ancestors(&clip::parents(model), g);
        let draw = MaskDraw { model, parts, vb, indices, uniform, tex, sampler };
        if chain.is_empty() {
            self.mask_pass(cb, &mask, &draw, g)?;
        } else {
            let between = self.clip_mask(w, h, 1)?;
            for (k, &a) in chain.iter().enumerate() {
                if k == 0 {
                    self.mask_pass(cb, &mask, &draw, a)?;
                } else {
                    self.mask_pass(cb, &between, &draw, a)?;
                    self.multiply_mask(cb, &between, &mask)?;
                }
            }
            self.mask_pass(cb, &between, &draw, g)?;
            self.multiply_mask(cb, &between, &mask)?;
        }
        s.main = Some(gpu::begin(cb, s.tex, s.msaa, None)?);
        Ok(())
    }

    /// One group's mask parts into `target`: cleared to 0 (1 for an inverted group), then each
    /// part's coverage blended in translucently.
    fn mask_pass(&mut self, cb: &gpu::CommandBuffer, target: &Texture, d: &MaskDraw<'_>, g: usize) -> Result<(), Error> {
        let group = &d.model.clip_groups[g];
        let inverted = if group.flags & 2 != 0 { 1.0f32 } else { 0.0 };
        let texture = Some(group.texture.as_str()).filter(|t| !t.is_empty()).and_then(|t| self.texture(t));
        let white = self.white.images[0].clone();
        let through = texture.as_ref().map_or(&*white, |t| &*t.images[0]);
        let c = f64::from(inverted);
        let enc = gpu::begin(cb, target, None, Some([c, c, c, c]))?;
        let pipeline = self.gpu.puppet_pipeline(Blend::Translucent, gpu::MASK_FORMAT, 1, gpu::PuppetPass::Mask)?;
        enc.setRenderPipelineState(&pipeline);
        gpu::set_bytes(&enc, true, d.uniform, 0);
        let clip: Vec<u8> = [0.0, 0.0, inverted, 0.0f32].iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(&enc, false, &clip, 1);
        // SAFETY: slots 0 and 1 exist in the mask shader; buffers and textures outlive the draws.
        unsafe {
            enc.setVertexBuffer_offset_atIndex(Some(d.vb), 0, shader::VERTEX_BUFFER_SLOT as usize);
            enc.setFragmentTexture_atIndex(Some(d.tex), 0);
            enc.setFragmentTexture_atIndex(Some(through), 1);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[d.sampler]), 0);
            for (first, count) in clip::mask_ranges(d.model, d.parts, g) {
                enc.drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset(
                    MTLPrimitiveType::Triangle,
                    count,
                    MTLIndexType::UInt16,
                    d.indices,
                    first * 2,
                );
            }
        }
        enc.endEncoding();
        Ok(())
    }

    /// Multiplies mask `from` into mask `into`.
    fn multiply_mask(&mut self, cb: &gpu::CommandBuffer, from: &Texture, into: &Texture) -> Result<(), Error> {
        // A full-target quad in clip space: x, y, u, v, then white.
        let mut quad = Vec::with_capacity(4 * 32);
        for (x, y, u, v) in [(-1.0f32, 1.0f32, 0.0f32, 0.0f32), (1.0, 1.0, 1.0, 0.0), (-1.0, -1.0, 0.0, 1.0), (1.0, -1.0, 1.0, 1.0)] {
            for f in [x, y, u, v, 1.0, 1.0, 1.0, 1.0] {
                quad.extend_from_slice(&f.to_le_bytes());
            }
        }
        let ptr = NonNull::new(quad.as_ptr() as *mut c_void).ok_or_else(|| Error::Format("mask quad".into()))?;
        // SAFETY: the buffer copies the quad immediately.
        let vb = unsafe { self.gpu.device.newBufferWithBytes_length_options(ptr, quad.len(), MTLResourceOptions::StorageModeShared) }
            .ok_or_else(|| Error::Metal("mask quad buffer".into()))?;
        let enc = gpu::begin(cb, into, None, None)?;
        let pipeline = self.gpu.puppet_pipeline(Blend::Disabled, gpu::MASK_FORMAT, 1, gpu::PuppetPass::MaskMultiply)?;
        enc.setRenderPipelineState(&pipeline);
        let identity: Vec<u8> = IDENTITY.iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(&enc, true, &identity, 0);
        // SAFETY: slot 0 exists in the multiply shader; the buffer and texture outlive the draw.
        unsafe {
            enc.setVertexBuffer_offset_atIndex(Some(&vb), 0, shader::VERTEX_BUFFER_SLOT as usize);
            enc.setFragmentTexture_atIndex(Some(from), 0);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[0]), 0);
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4);
        }
        enc.endEncoding();
        Ok(())
    }

    /// Clipping mask buffer `slot` (the mask, or the one a nested group renders into first) for
    /// a surface of `w`x`h`.
    fn clip_mask(&mut self, w: usize, h: usize, slot: usize) -> Result<Retained<Texture>, Error> {
        if let Some(t) = self.clip_masks.get(&(w, h, slot)) {
            return Ok(t.clone());
        }
        let t = self.gpu.render_target(w, h, gpu::MASK_FORMAT, 1)?;
        let _ = self.clip_masks.insert((w, h, slot), t.clone());
        Ok(t)
    }

    /// How the scene sets up particle files: whether they take their 2D defaults (the scene has
    /// an orthographic projection), and the field of view perspective systems are seen through.
    fn particle_settings(&self) -> (bool, f32) {
        let Ok(scene) = self.vfs.json("scene.json") else {
            return (true, 50f32.to_radians());
        };
        let general = &scene["general"];
        let ortho = &general["orthogonalprojection"];
        let two_d = ortho["auto"].as_bool() == Some(true)
            || ortho["width"].as_f64().is_some_and(|w| w != 0.0)
            || ortho["height"].as_f64().is_some_and(|h| h != 0.0);
        let fov = general["perspectiveoverridefov"]
            .as_f64()
            .or_else(|| general["fov"].as_f64())
            .unwrap_or(50.0) as f32;
        (two_d, fov.to_radians())
    }

    /// The layer's instance overrides, with user properties resolved.
    fn particle_overrides(&self, layer: &ParticleLayer) -> particles::InstanceOverride {
        layer
            .instance_override
            .as_ref()
            .and_then(|o| {
                particles::InstanceOverride::from_json(&scene::resolve_user_values(o, &self.props))
            })
            .unwrap_or_default()
    }

    /// Loads a particle layer's system: its file, the child files it starts and the layer's
    /// instance overrides, and the draws of every renderer.
    fn particle_system(
        &mut self,
        index: usize,
        layer: &ParticleLayer,
        (two_d, fov): (bool, f32),
    ) -> Result<ParticleGpu, Error> {
        let root = particles::Definition::from_json(&self.vfs.json(&layer.system)?, two_d)?;
        let mut problems = Vec::new();
        let vfs = &self.vfs;
        let tree = particles::Tree::new(root, &mut |name| {
            match vfs
                .json(name)
                .and_then(|j| particles::Definition::from_json(&j, two_d))
            {
                Ok(def) => Some(def),
                Err(e) => {
                    problems.push(format!("child system {name}: {e}"));
                    None
                }
            }
        });
        for node in &tree.nodes {
            problems.extend(node.base.unknown.iter().map(|c| format!("{c} is not supported")));
        }
        let name = &self.scene.layers[index].name;
        self.warnings
            .extend(problems.into_iter().map(|p| format!("layer {name}: {p}")));
        // A fixed seed per layer keeps a frozen frame, and the golden harness, reproducible.
        let seed = 0x9E37_79B9_7F4A_7C15u64.wrapping_mul(index as u64 + 1);
        let sim = particles::Simulation::new(tree, self.particle_overrides(layer), seed);
        let draws = self.particle_draws(&sim);
        Ok(ParticleGpu {
            layer: index,
            sim,
            draws,
            world: self.world(index, 0),
            fov,
            vertices: Vec::new(),
        })
    }

    /// A draw for every renderer of every file of the system; a renderer whose material fails
    /// is skipped with a warning.
    fn particle_draws(&mut self, sim: &particles::Simulation) -> Vec<Vec<ParticleDraw>> {
        let mut all = Vec::new();
        for node in sim.nodes() {
            let def = &node.def;
            let mut draws = Vec::new();
            match Material::load(&self.vfs, &def.material) {
                Ok(material) => {
                    for (r, renderer) in def.renderers.iter().enumerate() {
                        match self.particle_draw(&material, def, r) {
                            Ok(draw) => draws.push(draw),
                            Err(e) => self.warnings.push(format!(
                                "particles {}: {} renderer skipped: {e}",
                                def.material,
                                renderer_name(&renderer.kind)
                            )),
                        }
                    }
                }
                Err(e) => self
                    .warnings
                    .push(format!("particles {}: {e}", def.material)),
            }
            all.push(draws);
        }
        all
    }

    /// The material variant one renderer draws with: the combos the engine sets for the
    /// renderer kind and the texture, and the vertex layout the renderer fills.
    fn particle_draw(
        &mut self,
        material: &Material,
        def: &particles::Definition,
        renderer: usize,
    ) -> Result<ParticleDraw, Error> {
        use particles::RendererKind;
        let r = &def.renderers[renderer];
        let texture = material
            .textures
            .first()
            .and_then(|t| t.as_deref())
            .filter(|t| !t.starts_with("_rt_"))
            .and_then(|t| self.texture(t));
        let sheet = texture.as_deref().and_then(sheet_info);
        let layout = particles::Layout::for_renderer(def, r, sheet.is_some());
        let mut m = material.clone();
        let mut combo = |name: &str, value: i64| {
            let _ = m.combos.insert(name.into(), value);
        };
        // A one-channel texture is uploaded as grey with full alpha; the shader's conversion for
        // that format turns it into white with the channel as alpha. A two-channel texture is
        // uploaded as grey and alpha already, which is what the shader would make of it, so it
        // needs no combo.
        if texture
            .as_ref()
            .is_some_and(|t| t.images[0].pixelFormat() == MTLPixelFormat::R8Unorm)
        {
            combo("TEX0FORMAT", 9);
        }
        if layout == particles::Layout::SpriteThick {
            combo("THICKFORMAT", 1);
            if let (Some(_), Some(t)) = (sheet, texture.as_ref()) {
                combo("SPRITESHEET", 1);
                let blend = def.flags & 0x2 == 0;
                combo("SPRITESHEETBLEND", i64::from(blend));
                combo("SPRITESHEETBLENDNPOT", i64::from(t.res[2] < t.res[0]));
            }
        }
        match r.kind {
            RendererKind::Sprite => {}
            RendererKind::SpriteTrail { .. } => combo("TRAILRENDERER", 1),
            RendererKind::Rope { .. } => {
                combo("THICKFORMAT", 1);
                combo("ORIENTATION", i64::from(r.orientation));
            }
            RendererKind::RopeTrail {
                fade_alpha,
                fade_size,
                ..
            } => {
                combo("TRAILRENDERER", 1);
                combo("ORIENTATION", i64::from(r.orientation));
                combo("TRAILSCROLLALPHA", i64::from(def.trail_scrolling));
                combo("TRAILFADEALPHA", i64::from(fade_alpha));
                combo("TRAILFADESIZE", i64::from(fade_size));
            }
        }
        if matches!(r.kind, RendererKind::Rope { .. } | RendererKind::RopeTrail { .. }) {
            m.shader = ROPE_SHADER.into();
            self.load_rope_shader()?;
        }
        let item = self.build_item(
            &m,
            m.blend,
            TARGET_FORMAT,
            self.samples,
            &[],
            false,
            false,
            Some(layout.vertex()),
        )?;
        let indices = particles::quad_indices(layout.max_quads(r, def.max_count).max(1));
        let ptr = NonNull::new(indices.as_ptr() as *mut c_void)
            .ok_or_else(|| Error::Format("particle index buffer".into()))?;
        // SAFETY: the buffer copies `indices.len()` u32 values immediately.
        let indices = unsafe {
            self.gpu.device.newBufferWithBytes_length_options(
                ptr,
                indices.len() * 4,
                MTLResourceOptions::StorageModeShared,
            )
        }
        .ok_or_else(|| Error::Metal("particle index buffer".into()))?;
        Ok(ParticleDraw {
            renderer,
            layout,
            item,
            sheet,
            indices,
        })
    }

    /// Puts a fixed copy of the rope shader into the source cache before anything compiles it.
    /// Its vertex stage (the one used without a geometry stage) widens the strip by
    /// `right * uvs.x * 2.0 - 1.0`, which subtracts 1 from every coordinate instead of centring
    /// the width on the line, and its size fade writes `.w` of a float, which does not compile.
    /// Only particle ropes use this shader.
    fn load_rope_shader(&mut self) -> Result<(), Error> {
        if self.sources.contains_key(ROPE_SHADER) {
            return Ok(());
        }
        let mut source = shader::Source::load(&self.vfs, ROPE_SHADER)?;
        source.vert = source
            .vert
            .replace("right * uvs.x * 2.0 - 1.0", "right * (uvs.x * 2.0 - 1.0)")
            .replace("sizeStart.w *=", "sizeStart *=")
            .replace("sizeEnd.w *=", "sizeEnd *=");
        let _ = self.sources.insert(ROPE_SHADER.into(), Rc::new(source));
        Ok(())
    }

    /// Draws one particle layer: advances its simulation to `input.time`, builds every
    /// instance's vertices into one buffer and draws each renderer of each instance.
    fn draw_particles(
        &mut self,
        enc: &gpu::Encoder,
        index: usize,
        view: &ParticleView,
        input: FrameInput,
        named: &HashMap<String, Retained<Texture>>,
    ) -> Result<(), Error> {
        let height = self.scene.height;
        // Particle systems work y up from the scene's bottom-left, like the files.
        let to_design = mul(&translate(0.0, height, 0.0), &scale(1.0, -1.0, 1.0));
        let (vertices, batches) = {
            let p = &mut self.particles[index];
            let placement = mul(&to_design, &mul(&p.world, &scale(1.0, -1.0, 1.0)));
            p.sim.set_placement(particles::Affine::from_mat4(&placement));
            p.sim.set_pointer(particles::Vec3::new(
                view.pointer[0],
                height - view.pointer[1],
                0.0,
            ));
            p.sim.set_audio(&self.audio[0], &self.audio[1]);
            p.sim.set_canvas(self.scene.width, height);
            p.sim.set_time_of_day(day_time());
            p.sim.advance_to(input.time);
            let mut vertices = std::mem::take(&mut p.vertices);
            vertices.clear();
            let mut batches = Vec::new();
            let nodes = p.sim.nodes();
            let draws = &p.draws;
            p.sim.visit(&mut |inst| {
                if inst.alive == 0 {
                    return;
                }
                let def = &nodes[inst.node].def;
                for (d, draw) in draws[inst.node].iter().enumerate() {
                    let renderer = &def.renderers[draw.renderer];
                    let built = particles::build(nodes, inst, renderer, draw.layout, &mut vertices);
                    if built.quads > 0 {
                        let var0 = particles::render_var0(def, renderer, inst);
                        batches.push((inst.node, d, built, inst.model(nodes), var0));
                    }
                }
            });
            (vertices, batches)
        };
        if !batches.is_empty() {
            let ptr = NonNull::new(vertices.as_ptr() as *mut c_void)
                .ok_or_else(|| Error::Format("particle vertex buffer".into()))?;
            // SAFETY: the buffer copies the vertices immediately and outlives the draws.
            let buffer = unsafe {
                self.gpu.device.newBufferWithBytes_length_options(
                    ptr,
                    vertices.len() * 4,
                    MTLResourceOptions::StorageModeShared,
                )
            }
            .ok_or_else(|| Error::Metal("particle vertex buffer".into()))?;
            let p = &self.particles[index];
            let nodes = p.sim.nodes();
            for (node, d, built, model, var0) in batches {
                let draw = &p.draws[node][d];
                let def = &nodes[node].def;
                let renderer = &def.renderers[draw.renderer];
                let mut model_mat = model.to_mat4();
                if def.perspective() && !view.perspective_scene {
                    model_mat = mul(&perspective(self.scene.width, height, p.fov), &model_mat);
                }
                let model_design = mul(&to_design, &model_mat);
                let mvp = mul(&view.view_projection, &model_design);
                let ctx = DrawCtx {
                    mvp,
                    model: model_design,
                    view_projection: view.view_projection,
                    target: view.screen,
                    color: [1.0; 3],
                    alpha: 1.0,
                    buffer_scale: [1.0, 1.0],
                    fbo_scale: [1.0, 1.0],
                    screen_mvp: mvp,
                    size: [1.0, 1.0],
                    normal_model: IDENTITY,
                    lit: false,
                };
                let values = particles::ShaderValues {
                    orientation: particles::orientation(&model, renderer),
                    view_up: particles::Vec3::Y,
                    view_right: particles::Vec3::X,
                    // The camera of a 2D scene, above the view's centre.
                    eye: particles::Vec3::new(view.center[0], view.center[1], 2000.0),
                    render_var0: var0,
                    render_var1: draw
                        .sheet
                        .map_or([0.0; 4], |s| [s.frame[0], s.frame[1], s.count, s.aspect]),
                };
                self.bind(enc, &draw.item, &ctx, input, None, named, None, Some(&values));
                // SAFETY: the vertex range and the index buffer hold `quads` quads; both outlive
                // the draw.
                unsafe {
                    enc.setVertexBuffer_offset_atIndex(
                        Some(&buffer),
                        built.start * 4,
                        shader::VERTEX_BUFFER_SLOT as usize,
                    );
                    enc.drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset(
                        MTLPrimitiveType::Triangle,
                        built.quads * 6,
                        MTLIndexType::UInt32,
                        &draw.indices,
                        0,
                    );
                }
            }
        }
        self.particles[index].vertices = vertices;
        Ok(())
    }

    /// Text bitmaps arrive premultiplied; the blend state multiplies by alpha, so divide it out.
    fn upload_bitmap(&self, bitmap: &text::TextBitmap) -> Result<Retained<Texture>, Error> {
        let (w, h) = (bitmap.width as usize, bitmap.height as usize);
        let mut data = bitmap.pixels.clone();
        for p in data.as_chunks_mut::<4>().0 {
            let a = p[3] as u32;
            if a > 0 && a < 255 {
                for c in &mut p[..3] {
                    *c = (((*c as u32) * 255 + a / 2) / a).min(255) as u8;
                }
            }
        }
        let tex = crate::tex::Tex {
            texture_width: w,
            texture_height: h,
            image_width: w,
            image_height: h,
            format: crate::tex::Format::Rgba8,
            clamp: true,
            nearest: false,
            images: vec![vec![crate::tex::Mip {
                width: w,
                height: h,
                data,
            }]],
            frames: Vec::new(),
            video: None,
        };
        self.gpu.upload(&tex, 0, false)
    }

    /// Copies each video texture's frame for scene time `time` into its texture, when it
    /// changed, ahead of the frame's draws on the same command buffer.
    fn update_videos(&mut self, cb: &gpu::CommandBuffer, time: f32) -> Result<(), Error> {
        let mut blit: Option<Retained<ProtocolObject<dyn MTLBlitCommandEncoder>>> = None;
        for (texture, clip) in &mut self.videos {
            let Some(picture) = clip.seek(time) else { continue };
            let (w, h) = (picture.width.min(texture.width()), picture.height.min(texture.height()));
            let ptr = NonNull::new(picture.pixels.as_ptr() as *mut c_void)
                .ok_or_else(|| Error::Format("empty video frame".into()))?;
            // SAFETY: the buffer copies the frame's pixels immediately.
            let buffer = unsafe {
                self.gpu.device.newBufferWithBytes_length_options(
                    ptr,
                    picture.pixels.len(),
                    MTLResourceOptions::StorageModeShared,
                )
            }
            .ok_or_else(|| Error::Metal("video frame buffer".into()))?;
            if blit.is_none() {
                blit = Some(cb.blitCommandEncoder().ok_or_else(|| Error::Metal("blit encoder".into()))?);
            }
            let enc = blit.as_ref().ok_or_else(|| Error::Metal("blit encoder".into()))?;
            // SAFETY: the copy stays inside both the buffer (rows of `width * 4` bytes) and the
            // texture.
            unsafe {
                enc.copyFromBuffer_sourceOffset_sourceBytesPerRow_sourceBytesPerImage_sourceSize_toTexture_destinationSlice_destinationLevel_destinationOrigin(
                    &buffer,
                    0,
                    picture.width * 4,
                    picture.width * 4 * picture.height,
                    MTLSize { width: w, height: h, depth: 1 },
                    texture,
                    0,
                    0,
                    MTLOrigin { x: 0, y: 0, z: 0 },
                );
            }
        }
        if let Some(enc) = blit {
            enc.endEncoding();
        }
        Ok(())
    }

    /// A texture drawn as a picture: layer images, sprites, slot 0 of a material.
    fn texture(&mut self, name: &str) -> Option<Rc<TexEntry>> {
        self.texture_as(name, true)
    }

    /// `color` decides how one- and two-channel files read; see `Gpu::upload`.
    fn texture_as(&mut self, name: &str, color: bool) -> Option<Rc<TexEntry>> {
        let key = if color { name.to_string() } else { format!("{name}#raw") };
        if let Some(t) = self.textures.get(&key) {
            return Some(t.clone());
        }
        let loaded = (|| -> Result<(TexEntry, Option<video::Video>), Error> {
            let path = format!("materials/{name}.tex");
            let data = self.vfs.read(&path).ok_or(Error::Missing(path))?;
            let tex = crate::tex::decode(&data)?;
            // A video plays into one texture, which `update_videos` refreshes every frame.
            let clip = match &tex.video {
                Some(mp4) => Some(video::Video::open(mp4, name)?),
                None => None,
            };
            let images = if clip.is_some() {
                vec![self.gpu.video_target(tex.texture_width, tex.texture_height)?]
            } else {
                (0..tex.images.len())
                    .map(|i| self.gpu.upload(&tex, i, color))
                    .collect::<Result<Vec<_>, _>>()?
            };
            let sampler = usize::from(!tex.clamp) + 2 * usize::from(tex.nearest);
            let entry = TexEntry {
                images,
                res: [
                    tex.texture_width as f32,
                    tex.texture_height as f32,
                    tex.image_width as f32,
                    tex.image_height as f32,
                ],
                frames: tex.frames,
                sampler,
            };
            Ok((entry, clip))
        })();
        match loaded {
            Ok((entry, clip)) => {
                if let Some(clip) = clip {
                    self.videos.push((entry.images[0].clone(), clip));
                }
                let entry = Rc::new(entry);
                let _ = self.textures.insert(key, entry.clone());
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

    /// The render pipeline for `program`, made once per program, blend, format and sample count.
    fn pipeline(
        &mut self,
        program: &Rc<Program>,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        mesh: bool,
        layout: Option<&'static particles::VertexLayout>,
    ) -> Result<Retained<gpu::Pipeline>, Error> {
        if let Some(layout) = layout {
            return self.gpu.particle_program_pipeline(program, blend, format, samples, layout);
        }
        let key = (
            Rc::as_ptr(program) as usize,
            blend,
            samples * 1000 + format.0 + usize::from(mesh) * 1_000_000,
        );
        if let Some(p) = self.pipelines.get(&key) {
            return Ok(p.clone());
        }
        let p = if mesh {
            let inputs = models::mesh_inputs(program);
            self.gpu.mesh_pipeline(program, blend, format, samples, &inputs)?
        } else {
            self.gpu.pipeline(program, blend, format, samples)?
        };
        let _ = self.pipelines.insert(key, p.clone());
        Ok(p)
    }

    /// `mesh`: the item draws a model mesh in a model pass (see `engine_models.rs`).
    #[allow(clippy::too_many_arguments)]
    fn draw_item(
        &mut self,
        material: &Material,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        binds: &[(String, usize)],
        effect: bool,
        mesh: bool,
    ) -> Result<DrawItem, Error> {
        self.build_item(material, blend, format, samples, binds, effect, mesh, None)
    }

    /// `draw_item`, or with `layout` a particle draw: its pipeline reads that vertex layout and
    /// the particle shaders' own inputs become dynamic uniforms.
    #[allow(clippy::too_many_arguments)]
    fn build_item(
        &mut self,
        material: &Material,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        binds: &[(String, usize)],
        effect: bool,
        mesh: bool,
        layout: Option<&'static particles::VertexLayout>,
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
                } else if let Some(t) = self.texture_as(name, i == 0) {
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
        if mesh {
            combos.extend(self.light_combos().map(|(k, v)| (k.to_string(), v)));
        }
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
        let (mut program, _) = self.program(&shader_name, &combos)?;
        let pipeline = match self.pipeline(&program, blend, format, samples, mesh, layout) {
            Ok(p) => p,
            // Some shaders carry a leaner branch for Wallpaper Engine's OpenGL builds
            // (`#ifdef GLSL`), written for GPUs with fewer interpolators than Direct3D's 32.
            // Metal allows fewer still, and its compiler fails on the Direct3D branch, so that
            // branch is the fallback.
            Err(e)
                if !combos.contains_key("GLSL")
                    && (source.vert.contains("GLSL") || source.frag.contains("GLSL")) =>
            {
                let _ = combos.insert("GLSL".into(), 1);
                program = self.program(&shader_name, &combos)?.0;
                self.pipeline(&program, blend, format, samples, mesh, layout).map_err(|_| e)?
            }
            Err(e) => return Err(e),
        };

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
                            self.texture_as(default, index == 0).unwrap_or_else(|| self.black.clone()),
                        )
                    }
                }
            };
            textures.push((slot, index, src));
        }

        let mut dynamic = Vec::new();
        let mut stage_bytes = |code: &shader::StageCode, vertex: bool| -> Vec<u8> {
            let mut bytes = vec![0u8; code.ubo_size as usize];
            for u in &code.uniforms {
                let particle = layout
                    .and_then(|_| particles::ShaderInput::from_name(&u.name))
                    .map(Dyn::Particle);
                if let Some(d) = engine_uniform(&u.name).or(particle) {
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
                        .filter(|v| !v.is_null())
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
        // Wallpaper Engine draws a text layer's glyphs in its plain colour unless the scene is
        // HDR; only then does the brightness scale it.
        let plain = layer.text.is_some() && !self.scene.hdr;
        let brightness = if plain { 1.0 } else { layer.brightness };
        let mut color = [1.0f32; 3];
        for (o, v) in color.iter_mut().zip(floats(&layer.color.at(&self.props, self.time))) {
            *o = v * brightness;
        }
        Some(Placed {
            world: self.world(index, 0),
            size,
            color,
            alpha: floats(&layer.alpha.at(&self.props, self.time))
                .first()
                .copied()
                .unwrap_or(1.0),
            compose: layer
                .material
                .as_ref()
                .is_some_and(|m| m.shader == "composelayer"),
        })
    }

    /// Moves the parallax point and plays the puppets on to this frame. Wallpaper Engine poses
    /// puppets before scripts run, so scripts read this frame's bones and override them for it.
    fn pose_puppets(&mut self, input: FrameInput) {
        self.time = input.time;
        let now = self.parallax_now();
        self.parallax_point = now.map(|p| self.ease_parallax(&p, input));
        // Physics lags behind where its puppet is placed this frame.
        let objects: Vec<Mat4> = self.puppets.iter().map(|p| self.world(p.layer, 0)).collect();
        for (puppet, object) in self.puppets.iter_mut().zip(&objects) {
            puppet.advance(input.time, Some(object));
        }
    }

    /// Re-places layers that move every frame: those hanging off a puppet attachment (the bones
    /// move) and, with camera parallax, all of them (the pointer moves).
    fn follow_motion(&mut self, input: FrameInput) {
        let now = self.parallax_now();
        // Keyframed values move layers and fade them; once they all hold, placing stops.
        if !self.timelines_settled {
            self.timelines_settled = self.scene.settled(input.time);
            self.replace_layers();
        }
        let all = now.is_some();
        self.shake_offset = match self.scene.shake.now(&self.props) {
            Some(shake) => camera_shake(shake, input.time, self.scene.height),
            None => [0.0; 2],
        };
        for i in 0..self.layers.len().min(self.scene.layers.len()) {
            if self.layers[i].placed.is_none() || !(all || self.attached(i)) {
                continue;
            }
            let world = self.world(i, 0);
            if let Some(p) = &mut self.layers[i].placed {
                p.world = world;
            }
        }
        for i in 0..self.particles.len() {
            let layer = self.particles[i].layer;
            if all || self.attached(layer) {
                self.particles[i].world = self.world(layer, 0);
            }
        }
    }

    /// The scene's camera parallax with the user's property values applied; `None` when the
    /// scene has none or is seen through a perspective camera (its layers never move).
    pub fn parallax_now(&self) -> Option<scene::ParallaxNow> {
        self.scene.parallax.now(&self.props).filter(|_| !self.perspective())
    }

    /// The parallax point for this frame. Wallpaper Engine mixes the pointer (clamped to the
    /// screen, y up, mirrored with the picture) with the centre by the mouse influence, and eases
    /// towards it by `min((1 - delay / 3) * 10 * dt, 1)`; with the "mouse parallax" option off
    /// the influence is 0, so the point settles in the centre and layers keep their offsets.
    fn ease_parallax(&self, p: &scene::ParallaxNow, input: FrameInput) -> ([f32; 2], f32) {
        let (w, h) = (self.scene.width, self.scene.height);
        let influence = if self.parallax_enabled { p.mouse_influence } else { 0.0 };
        let mut mx = input.pointer[0].clamp(0.0, 1.0);
        let my = 1.0 - input.pointer[1].clamp(0.0, 1.0);
        if self.framing.flip {
            mx = 1.0 - mx;
        }
        let target = [
            w * 0.5 * (1.0 - influence) + w * mx * influence,
            h * 0.5 * (1.0 - influence) + h * my * influence,
        ];
        // Every display draws the same frame: a time already reached moves nothing. The first
        // frame starts at the target instead of sliding in.
        let Some((point, clock)) = self.parallax_point else {
            return (target, input.time);
        };
        let dt = (input.time - clock).max(0.0);
        let k = if p.delay > 0.0 { ((1.0 - p.delay / 3.0) * 10.0 * dt).min(1.0) } else { 1.0 };
        ([0, 1].map(|i| point[i] + (target[i] - point[i]) * k), input.time.max(clock))
    }

    /// `g_ParallaxPosition`: the parallax point in 0...1 of the scene (y up, mirrored back with
    /// the picture), or 0 without camera parallax.
    fn parallax_position(&self) -> [f32; 2] {
        let Some((point, _)) = self.parallax_point else { return [0.0; 2] };
        let x = (point[0] / self.scene.width.max(1.0)).clamp(0.0, 1.0);
        let y = (point[1] / self.scene.height.max(1.0)).clamp(0.0, 1.0);
        [if self.framing.flip { 1.0 - x } else { x }, y]
    }

    /// The layer or one of its parents follows a puppet attachment.
    fn attached(&self, index: usize) -> bool {
        let mut layer = self.scene.layers.get(index);
        for _ in 0..32 {
            let Some(l) = layer else { return false };
            if l.attachment.is_some() {
                return true;
            }
            layer = l.parent.and_then(|p| self.scene.layers.iter().find(|x| x.id == p));
        }
        false
    }

    /// Layer world matrix including parents, camera parallax and the layer's alignment, in design
    /// pixels (y down). In a perspective scene, the layer's 3D placement instead.
    fn world(&self, index: usize, depth: u32) -> Mat4 {
        if self.perspective() {
            return self.perspective_world(index);
        }
        let base = self.base_world(index, depth);
        let [ax, ay] = self.scene.layers[index].alignment;
        if ax == 0.0 && ay == 0.0 {
            return base;
        }
        // Wallpaper Engine moves the box by whole units of its size, y up, in the layer's own
        // space; the renderer is y down.
        let [w, h] = match self.scene.layers[index].size {
            [w, h] if w > 0.0 && h > 0.0 => [w, h],
            _ => self.layers.get(index).and_then(|l| l.image.as_ref()).map_or([0.0; 2], |t| [t.res[2], t.res[3]]),
        };
        mul(&base, &translate(ax * w.trunc(), -ay * h.trunc(), 0.0))
    }

    /// Layer world matrix without its alignment, which its children do not inherit.
    fn base_world(&self, index: usize, depth: u32) -> Mat4 {
        let layer = &self.scene.layers[index];
        let o = floats(&layer.origin.at(&self.props, self.time));
        let s = floats(&layer.scale.at(&self.props, self.time));
        let a = floats(&layer.angles.at(&self.props, self.time));
        let get = |v: &[f32], i: usize, d: f32| v.get(i).copied().unwrap_or(d);
        let parent = layer
            .parent
            .and_then(|p| self.scene.layers.iter().position(|l| l.id == p));
        // The file is y up from the design's bottom-left (a child's origin is an offset from its
        // parent, also y up); the renderer works y down from the top-left, like Metal textures.
        let y = get(&o, 1, 0.0);
        let y = if parent.is_some() { -y } else { self.scene.height - y };
        let local = mul(
            &mul(
                &translate(get(&o, 0, 0.0), y, 0.0),
                &rotate_z(-get(&a, 2, 0.0)),
            ),
            &scale(get(&s, 0, 1.0), get(&s, 1, 1.0), 1.0),
        );
        // A layer attached to a puppet follows the attachment point as the bones move.
        let attached = parent.zip(layer.attachment.as_deref()).and_then(|(p, name)| {
            let puppet = self.puppets.iter().find(|g| g.layer == p)?;
            puppet.attachment(name)
        });
        let local = match attached {
            Some(a) => mul(&a, &local),
            None => local,
        };
        let world = match parent {
            Some(p) if depth < 32 => mul(&self.base_world(p, depth + 1), &local),
            _ => local,
        };
        // Camera parallax moves a whole tree by its root's offset, in design units after every
        // transform; a child moves with its parent and its own depth plays no part.
        if parent.is_some() {
            return world;
        }
        let [dx, dy] = self.parallax_shift([get(&o, 0, 0.0), get(&o, 1, 0.0)], &layer.parallax_depth);
        if dx == 0.0 && dy == 0.0 {
            return world;
        }
        // The offset is y up, like the file; the renderer is y down.
        mul(&translate(dx, -dy, 0.0), &world)
    }

    /// Camera parallax's offset this frame (design units, y up) of a tree whose root is at
    /// `origin` (y up) with parallax depth `depth`.
    pub(super) fn parallax_shift(&self, origin: [f32; 2], depth: &Bound) -> [f32; 2] {
        let (Some((point, _)), Some(p)) = (self.parallax_point, self.parallax_now()) else {
            return [0.0; 2];
        };
        let depth = floats(&depth.get(&self.props));
        let depth = [depth.first().copied().unwrap_or(1.0), depth.get(1).copied().unwrap_or(1.0)];
        parallax_offset(origin, point, p.amount, depth)
    }

    /// Whether the layer is text whose string a script sets, so it changes between frames.
    fn has_scripted_text(&self, index: usize) -> bool {
        let Some(layer) = self.scene.layers.get(index) else { return false };
        layer.text.is_some()
            && self.scene.scripts.iter().any(|s| s.layer_id == layer.id && s.field.starts_with("text"))
    }

    fn visible(&self, index: usize) -> bool {
        if self.hide_scripted_text && self.has_scripted_text(index) {
            return false;
        }
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

    /// The part of the design that is on screen, in design units: left, right, top, bottom. The
    /// framing decides it; the parallax zoom and the camera shake act on top. A flipped picture
    /// has its left and right swapped, which mirrors everything drawn through this view.
    fn view_rect(&self, tw: f32, th: f32) -> (f32, f32, f32, f32) {
        // A perspective camera fills the target whatever the alignment (see `camera.rs`); the
        // design is the target itself, mirroring and shake act on the camera.
        if self.perspective() {
            return (0.0, tw, 0.0, th);
        }
        let [mut l, mut r, mut t, mut b] =
            framed_view(&self.framing, [self.scene.width, self.scene.height], [tw, th]);
        // The scene's own zoom (keyframed in some intros) narrows the view like the parallax
        // margin does.
        let zoom = floats(&self.scene.zoom.at(&self.props, self.time));
        let zoom = zoom.first().copied().unwrap_or(1.0);
        let z = zoom.max(0.01);
        if z != 1.0 {
            let (cx, cy) = ((l + r) / 2.0, (t + b) / 2.0);
            let (hw, hh) = ((r - l) / (2.0 * z), (b - t) / (2.0 * z));
            (l, r, t, b) = (cx - hw, cx + hw, cy - hh, cy + hh);
        }
        let [sx, sy] = self.shake_offset;
        let (l, r) = if self.framing.flip { (r + sx, l + sx) } else { (l + sx, r + sx) };
        (l, r, t + sy, b + sy)
    }

    /// The rectangle the design itself covers on the target, in target pixels: x, y, width,
    /// height. Where it leaves bars, `blur_bars` fills them with a blurred copy of the picture.
    fn content_rect(&self, tw: f32, th: f32) -> (f32, f32, f32, f32) {
        let (l, r, t, b) = self.view_rect(tw, th);
        let (xa, xb) = ((0.0 - l) / (r - l) * tw, (self.scene.width - l) / (r - l) * tw);
        let (ya, yb) = ((0.0 - t) / (b - t) * th, (self.scene.height - t) / (b - t) * th);
        (xa.min(xb), ya.min(yb), (xb - xa).abs(), (yb - ya).abs())
    }

    /// Renders one frame into `target` (a drawable or offscreen texture) on `cb`.
    pub fn encode(
        &mut self,
        cb: &gpu::CommandBuffer,
        target: &Texture,
        input: FrameInput,
    ) -> Result<(), Error> {
        let (tw, th) = (target.width() as f32, target.height() as f32);
        if self.perspective() {
            // A perspective scene has no design size of its own: its 2D parts span the target.
            (self.scene.width, self.scene.height) = (tw, th);
        }
        // Scripts may start keyframed animations, at this frame's time.
        self.pose_puppets(input);
        self.run_scripts(input, [tw, th]);
        self.follow_motion(input);
        self.update_videos(cb, input.time)?;
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
        let ortho_projection = ortho(l, r, b, t);
        self.update_view(input.time, [tw, th], [l, r, t, b]);
        let perspective = self.perspective();
        // Layers placed in 3D are seen through the camera.
        let view_projection = if perspective { self.models.view.view_projection } else { ortho_projection };
        // Screen pixels per design pixel (a flipped view has r < l).
        let fit = tw / (r - l).abs().max(0.001);
        self.fit_texts(fit);

        let mut c = [0.0f32; 3];
        for (o, v) in c.iter_mut().zip(floats(&self.scene.clear_color.get(&self.props))) {
            *o = v;
        }
        // Blurred bars need the scene in a texture first: the empty part of the target is then
        // filled with a blurred copy of the same picture.
        let blurred = self.framing.blur_bars && leaves_gaps(self.content_rect(tw, th), tw, th);
        let bloom = self.scene.bloom.enabled.truthy(&self.props);
        // The colour grade is applied while the finished scene is copied onto the target.
        let scene_tex = if blurred || bloom || self.grade.active() {
            Some(self.pool.take(&self.gpu, target.width(), target.height())?)
        } else {
            None
        };
        let scene_target: &Texture = scene_tex.as_ref().map_or(target, |t| &**t);
        let order: Vec<(usize, Option<String>)> = self
            .composite_refs
            .iter()
            .map(|(i, name)| (*i, Some(name.clone())))
            .chain((0..self.layers.len()).map(|i| (i, None)))
            .collect();
        // The clear colour goes to the frame's first pass: the 2D pass, or a model pass when a
        // model draws first (no empty pass then).
        let mut clear = Some([c[0] as f64, c[1] as f64, c[2] as f64, 1.0]);
        let models_first = self.composite_refs.is_empty()
            && order
                .iter()
                .find(|(i, _)| self.model_at(*i).is_some() || self.layer_draws(*i))
                .is_some_and(|(i, _)| self.model_at(*i).is_some());
        let mut main = if models_first {
            None
        } else {
            Some(gpu::begin(cb, scene_target, msaa.as_deref(), clear.take())?)
        };
        // The open model pass, while consecutive model layers draw.
        let mut model_pass: Option<Retained<gpu::Encoder>> = None;
        let mut depth_cleared = false;
        let screen = [tw, th];
        let mut shared = Shared { frame_copy: HashMap::new(), composites: HashMap::new(), screen };
        // Volumetric light glows, each added just before the layer that follows its light.
        let (hazes, haze_inverse) = self.hazes();
        let mut haze_next = 0;

        for (li, composite) in order {
            while composite.is_none() {
                let Some(batch) = due_hazes(&hazes, &mut haze_next, li) else { break };
                if let Some(enc) = model_pass.take() {
                    enc.endEncoding();
                }
                if let Some(enc) = main.take() {
                    enc.endEncoding();
                }
                main = Some(self.draw_haze(cb, &batch, &haze_inverse, scene_target, msaa.as_deref(), clear.take())?);
            }
            if composite.is_none() && (!self.layers[li].shown || self.inside_compose(li)) {
                continue;
            }
            if composite.is_none() {
                // A run of model layers draws as a whole when the order reaches its first layer;
                // its other layers have drawn then.
                if let Some(run) = self.run_at(li) {
                    if model_pass.is_none() {
                        if let Some(enc) = main.take() {
                            enc.endEncoding();
                        }
                        let first = !depth_cleared;
                        model_pass = Some(self.begin_model_pass(cb, scene_target, msaa.as_deref(), clear.take(), first)?);
                        depth_cleared = true;
                    }
                    if let Some(enc) = &model_pass {
                        self.draw_run(enc, run, input, screen, &shared.frame_copy);
                    }
                    continue;
                }
                if self.model_at(li).is_some() {
                    continue;
                }
                if self.layer_draws(li) {
                    if let Some(enc) = model_pass.take() {
                        enc.endEncoding();
                        main = Some(gpu::begin(cb, scene_target, msaa.as_deref(), None)?);
                    }
                }
            }
            let mut surface = Surface {
                tex: scene_target,
                msaa: msaa.as_deref(),
                main: main.take(),
                view_projection,
                ortho_projection,
                view: [l, r, t, b],
                fit,
            };
            self.draw_layer(cb, li, composite, &mut surface, &mut shared, input)?;
            main = surface.main;
        }
        while let Some(batch) = due_hazes(&hazes, &mut haze_next, usize::MAX) {
            if let Some(enc) = model_pass.take() {
                enc.endEncoding();
            }
            if let Some(enc) = main.take() {
                enc.endEncoding();
            }
            main = Some(self.draw_haze(cb, &batch, &haze_inverse, scene_target, msaa.as_deref(), clear.take())?);
        }
        if let Some(enc) = model_pass {
            enc.endEncoding();
        }
        if let Some(enc) = main {
            enc.endEncoding();
        }
        // Nothing drew: the target still gets the clear colour.
        if let Some(c) = clear {
            gpu::begin(cb, scene_target, msaa.as_deref(), Some(c))?.endEncoding();
        }
        for (_, t) in shared.composites {
            self.pool.give(t);
        }
        if let Some(scene_tex) = scene_tex.as_ref().filter(|_| bloom) {
            let glow = self.bloom(cb, scene_tex)?;
            let tint = floats(&self.scene.bloom.tint.get(&self.props));
            let tint = [0, 1, 2].map(|i| tint.get(i).copied().unwrap_or(1.0));
            let enc = gpu::begin(cb, scene_tex, None, None)?;
            self.composite_rect(&enc, &glow, 0, Blend::Additive, 1, FBO_MVP, [0.0, 0.0, 1.0, 1.0], tint, 1.0)?;
            enc.endEncoding();
            self.pool.give(glow);
        }
        if let Some(scene_tex) = scene_tex.clone().filter(|_| !blurred) {
            let enc = gpu::begin(cb, target, None, None)?;
            self.present_rect(&enc, &scene_tex, Blend::Disabled, FBO_MVP, [0.0, 0.0, 1.0, 1.0])?;
            enc.endEncoding();
            self.pool.give(scene_tex);
        } else if let Some(scene_tex) = scene_tex {
            // The scene is on its own texture; put a blurred copy of it behind and the sharp
            // picture on top, so the empty part of the target is not bare.
            let (x, y, cw, ch) = self.content_rect(tw, th);
            let bg = self.blur_frame(cb, &scene_tex, [x / tw, y / th, cw / tw, ch / th])?;
            let enc = gpu::begin(cb, target, None, Some([0.0, 0.0, 0.0, 1.0]))?;
            // The blurred copy covers the whole target.
            let crop = cover_crop(cw / ch, tw / th);
            self.present_rect(&enc, &bg, Blend::Normal, FBO_MVP, crop)?;
            // The picture itself keeps its place.
            let mvp = sub_rect_mvp(x, y, cw, ch, tw, th);
            let rect = [x / tw, y / th, (x + cw) / tw, (y + ch) / th];
            self.present_rect(&enc, &scene_tex, Blend::Normal, mvp, rect)?;
            enc.endEncoding();
            self.pool.give(bg);
            self.pool.give(scene_tex);
        }
        for (_, t) in shared.frame_copy {
            self.pool.give(t);
        }
        self.pool.end_frame(&self.gpu);
        Ok(())
    }

    /// Draws layer `li` onto surface `s`: its particle systems, then its image, puppet or text
    /// through its effects. With `composite` set the layer runs its chain off screen into the
    /// named buffer other layers sample.
    fn draw_layer(
        &mut self,
        cb: &gpu::CommandBuffer,
        li: usize,
        composite: Option<String>,
        s: &mut Surface<'_>,
        shared: &mut Shared,
        input: FrameInput,
    ) -> Result<(), Error> {
        let perspective = self.perspective();
        let view_projection = s.view_projection;
        let ortho_projection = s.ortho_projection;
        let [l, r, t, b] = s.view;
        let fit = s.fit;
        let screen = shared.screen;
        let [tw, th] = screen;
        // Particle layers have no image draw of their own; draw their systems in layer order.
        for pi in 0..self.particles.len() {
            if composite.is_some() {
                break;
            }
            if self.particles[pi].layer != li {
                continue;
            }
            if self.particles[pi].reads_frame() {
                s.main = Some(self.copy_frame(
                    cb,
                    s.main.take(),
                    s.tex,
                    s.msaa,
                    &mut shared.frame_copy,
                )?);
            }
            let enc = s.main
                .as_ref()
                .ok_or_else(|| Error::Metal("main pass".into()))?;
            let view = ParticleView {
                // A perspective scene's camera, with the layer's depth (see `particle_view_projection`).
                view_projection: if perspective {
                    self.particle_view_projection(&self.particles[pi].world)
                } else {
                    view_projection
                },
                pointer: [
                    l + input.pointer[0] * (r - l),
                    t + input.pointer[1] * (b - t),
                ],
                center: [(l + r) / 2.0, (t + b) / 2.0],
                screen,
                perspective_scene: perspective,
            };
            self.draw_particles(enc, pi, &view, input, &shared.frame_copy)?;
            if let Some(t) = shared.frame_copy.remove("_rt_FullFrameBuffer") {
                self.pool.give(t);
            }
        }
        let Some(Placed {
            world,
            size,
            color,
            alpha,
            compose,
        }) = self.layers[li].placed
        else {
            return Ok(());
        };
        // A fullscreen layer of a perspective scene covers the target, at the target's size.
        let fullscreen = perspective && self.scene.layers[li].fullscreen;
        let (world, size, view_projection) = if fullscreen {
            (translate(tw / 2.0, th / 2.0, 0.0), screen, ortho_projection)
        } else {
            (world, size, view_projection)
        };
        if self.layers[li].base.is_none() && self.layers[li].image.is_none() {
            return Ok(());
        }
        let image = self.layers[li].image.clone();
        let is_puppet = self.layers[li].puppet;
        // A text layer draws its bitmap, which overflows or underfills the box in the file as
        // the string changes ("DAY" in the editor, "WEDNESDAY" at runtime). Its effects run on
        // that quad, so from here on the layer's size is the bitmap's: effect buffers sized by
        // the box would squeeze a longer string and stretch it back, blocky.
        let (model, size) = match self.layers[li].text.map(|t| t.rect) {
            Some([x, y, w, h]) => {
                // The quad is centred on the model origin; `rect` is measured from the layer
                // origin, which the text is anchored to (the box in the file plays no part).
                let (ox, oy) = (x + w / 2.0, y + h / 2.0);
                let (w, h) = (w.max(0.001), h.max(0.001));
                (mul(&mul(&world, &translate(ox, oy, 0.0)), &scale(w, h, 1.0)), [w, h])
            }
            None => (mul(&world, &scale(size[0], size[1], 1.0)), size),
        };
        // Exactly the full-target quad, which the draw then gives in clip space.
        let mvp = if fullscreen { FBO_MVP } else { mul(&view_projection, &model) };
        let ctx = DrawCtx {
            mvp,
            model,
            view_projection,
            target: screen,
            color,
            alpha,
            buffer_scale: [1.0, 1.0],
            fbo_scale: [1.0, 1.0],
            screen_mvp: mvp,
            size,
            normal_model: IDENTITY,
            lit: false,
        };
        // Nothing of the layer reaches the target: its effects and draw would be wasted. The
        // test assumes an orthographic view.
        if !is_puppet && !perspective && off_target(&ctx.mvp) {
            return Ok(());
        }
        // Puppet vertices are in design units, y up: the layer transform without the box
        // scale, flipped into the y-down design space.
        let puppet_ctx = DrawCtx {
            mvp: mul(&view_projection, &mul(&world, &scale(1.0, -1.0, 1.0))),
            ..ctx
        };
        let uv = image.as_ref().map_or([1.0, 1.0], |t| {
            [t.res[2] / t.res[0].max(1.0), t.res[3] / t.res[1].max(1.0)]
        });
        let visible_effects: Vec<usize> = (0..self.layers[li].effects.len()).collect();
        // A compose layer's children draw into its buffer instead of onto the surface.
        let children = if composite.is_none() && !perspective && self.scene.layers[li].passthrough {
            self.children(li)
        } else {
            Vec::new()
        };

        if (visible_effects.is_empty() || self.layers[li].base_fx.is_none()) && children.is_empty() {
            // A sampled layer without effects offers its plain image.
            if let (Some(name), Some(t)) = (composite.as_ref(), image.as_ref()) {
                let k = self.buffer_scale(li, &world, fit, size);
                let (fw, fh) = (
                    (size[0] * k[0]).round().max(1.0) as usize,
                    (size[1] * k[1]).round().max(1.0) as usize,
                );
                if let Some(enc) = s.main.take() {
                    enc.endEncoding();
                }
                let out = self.pool.take(&self.gpu, fw, fh)?;
                let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
                let rect = [0.0, 0.0, uv[0], uv[1]];
                self.composite_rect(&enc, &t.images[0], t.sampler, Blend::Disabled, 1, FBO_MVP, rect, [1.0; 3], 1.0)?;
                enc.endEncoding();
                let _ = shared.frame_copy.insert(name.clone(), out.clone());
                let _ = shared.composites.insert(name.clone(), out);
                s.main = Some(gpu::begin(cb, s.tex, s.msaa, None)?);
                return Ok(());
            }
            // A compose layer without effects would redraw what is already behind it.
            if compose || composite.is_some() {
                return Ok(());
            }
            if self.layers[li].base.as_ref().is_some_and(|b| b.reads_frame) {
                s.main = Some(self.copy_frame(
                    cb,
                    s.main.take(),
                    s.tex,
                    s.msaa,
                    &mut shared.frame_copy,
                )?);
            }
            if is_puppet {
                // A blend map draws over the flat image first, which the mesh then shows.
                let channels = self.puppets.iter().any(|p| p.layer == li && p.channels.is_some());
                if let (true, Some(t)) = (channels, image.as_ref()) {
                    let k = self.buffer_scale(li, &world, fit, size);
                    let (fw, fh) = ((size[0] * k[0]).round().max(1.0) as usize, (size[1] * k[1]).round().max(1.0) as usize);
                    if let Some(enc) = s.main.take() {
                        enc.endEncoding();
                    }
                    let flat = self.pool.take(&self.gpu, fw, fh)?;
                    let enc = gpu::begin(cb, &flat, None, Some([0.0; 4]))?;
                    let rect = [0.0, 0.0, uv[0], uv[1]];
                    self.composite_rect(&enc, &t.images[0], t.sampler, Blend::Disabled, 1, FBO_MVP, rect, [1.0; 3], 1.0)?;
                    enc.endEncoding();
                    self.draw_channels(cb, li, &flat, size, [1.0; 4])?;
                    s.main = Some(gpu::begin(cb, s.tex, s.msaa, None)?);
                    self.draw_puppet(cb, s, li, &puppet_ctx, Some(&flat))?;
                    self.pool.give(flat);
                    return Ok(());
                }
                return self.draw_puppet(cb, s, li, &puppet_ctx, None);
            }
            let enc = s.main
                .as_ref()
                .ok_or_else(|| Error::Metal("main pass".into()))?;
            match &self.layers[li].base {
                Some(item) if visible_effects.is_empty() => {
                    self.draw(enc, item, &ctx, uv, input, None, &shared.frame_copy, None);
                    // Copied again by the next reader, so it need not stay alive meanwhile.
                    if let Some(t) = shared.frame_copy.remove("_rt_FullFrameBuffer") {
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
            return Ok(());
        }

        let k = self.buffer_scale(li, &world, fit, size);
        let (fw, fh) = (
            (size[0] * k[0]).round().max(1.0) as usize,
            (size[1] * k[1]).round().max(1.0) as usize,
        );
        if let Some(cached) = self.layers[li]
            .cached
            .clone()
            .filter(|c| composite.is_none() && children.is_empty() && c.width() == fw && c.height() == fh)
        {
            if is_puppet {
                return self.draw_puppet(cb, s, li, &puppet_ctx, Some(&cached));
            }
            let enc = s.main
                .as_ref()
                .ok_or_else(|| Error::Metal("main pass".into()))?;
            self.composite(enc, &cached, 0, self.layers[li].blend, &ctx, [1.0, 1.0])?;
            return Ok(());
        }

        // Effects: base -> A, each pass A -> B (or a named buffer), swap; then composite A.
        let reads_frame = if children.is_empty() {
            self.layers[li].base_fx.as_ref().is_some_and(|b| b.reads_frame)
        } else {
            self.scene.layers[li].copy_background && self.layers[li].base.as_ref().is_some_and(|b| b.reads_frame)
        };
        if reads_frame {
            s.main = Some(self.copy_frame(
                cb,
                s.main.take(),
                s.tex,
                s.msaa,
                &mut shared.frame_copy,
            )?);
        }
        if let Some(enc) = s.main.take() {
            enc.endEncoding();
        }
        let mut prev = self.pool.take(&self.gpu, fw, fh)?;
        // Effects only need to run where the layer can show, plus a margin for effects that
        // sample a little way off; a cached layer keeps all of it, the view may change later.
        let clip = if is_puppet || self.layers[li].still || perspective {
            [0.0, 0.0, 1.0, 1.0]
        } else {
            visible_uv(&ctx.mvp, 1.25)
        };
        let fbo_ctx = DrawCtx {
            mvp: FBO_MVP,
            model: IDENTITY,
            view_projection: IDENTITY,
            color,
            alpha: 1.0,
            buffer_scale: k,
            fbo_scale: k,
            ..ctx
        };
        if children.is_empty() {
            {
                let enc = gpu::begin(cb, &prev, None, Some([0.0; 4]))?;
                scissor(&enc, &prev, clip);
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
                    self.draw(&enc, item, &base_ctx, uv, input, None, &shared.frame_copy, None);
                }
                enc.endEncoding();
            }
        } else {
            self.pool.give(prev);
            prev = self.compose(cb, li, &children, [fw, fh], &ctx, &world, uv, s, shared, input)?;
        }
        if let Some(t) = shared.frame_copy.remove("_rt_FullFrameBuffer") {
            self.pool.give(t);
        }
        // A puppet's blend map draws over its flat image before the effects.
        if is_puppet {
            self.draw_channels(cb, li, &prev, size, [1.0; 4])?;
        }
        for &ei in &visible_effects {
            let effect = &self.layers[li].effects[ei];
            let fk = match self.layers[li].text {
                Some(_) => text_fbo_scale(k, &effect.fbos),
                None => k,
            };
            let mut named = shared.frame_copy.clone();
            for (name, div) in &effect.fbos {
                let (w, h) = (
                    (size[0] * fk[0] / div).round().max(1.0) as usize,
                    (size[1] * fk[1] / div).round().max(1.0) as usize,
                );
                let _ = named.insert(name.clone(), self.pool.take(&self.gpu, w, h)?);
            }
            let fbo_ctx = DrawCtx { fbo_scale: fk, ..fbo_ctx };
            for pass in &effect.passes {
                let out = match &pass.target {
                    Some(name) => named
                        .get(name)
                        .cloned()
                        .ok_or_else(|| Error::Format(format!("unknown buffer {name}")))?,
                    None => self.pool.take(&self.gpu, fw, fh)?,
                };
                let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
                scissor(&enc, &out, clip);
                self.draw(
                    &enc,
                    &pass.item,
                    &fbo_ctx,
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
        if let Some(name) = composite {
            // Materials and effects of later layers find it among the frame's named buffers.
            let _ = shared.frame_copy.insert(name.clone(), prev.clone());
            let _ = shared.composites.insert(name, prev);
            s.main = Some(gpu::begin(cb, s.tex, s.msaa, None)?);
            return Ok(());
        }
        // With a colour blend mode, the layer's own material blends the result with the screen.
        // A compose layer's own shader covers the whole target, so its result is composited
        // into the layer's box instead.
        let blended = self.layers[li].base.as_ref().filter(|b| b.reads_frame && !compose);
        let enc = match blended {
            Some(_) => {
                self.copy_frame(cb, None, s.tex, s.msaa, &mut shared.frame_copy)?
            }
            None => gpu::begin(cb, s.tex, s.msaa, None)?,
        };
        if is_puppet {
            s.main = Some(enc);
            self.draw_puppet(cb, s, li, &puppet_ctx, Some(&prev))?;
            self.pool.give(prev);
            return Ok(());
        }
        match &self.layers[li].base {
            Some(item) if item.reads_frame && !compose => {
                self.draw(
                    &enc,
                    item,
                    &ctx,
                    [1.0, 1.0],
                    input,
                    None,
                    &shared.frame_copy,
                    Some(&prev),
                );
                if let Some(t) = shared.frame_copy.remove("_rt_FullFrameBuffer") {
                    self.pool.give(t);
                }
            }
            _ => self.composite(&enc, &prev, 0, self.layers[li].blend, &ctx, [1.0, 1.0])?,
        }
        self.pool.give(prev);
        s.main = Some(enc);
        Ok(())
    }

    /// Draws compose layer `li`'s children into a buffer of `size` pixels, as Wallpaper Engine
    /// composes them: the buffer starts from what is behind the layer (`copybackground`) or
    /// empty, and each child (with its own children, unless it composes them itself) draws where
    /// it sits relative to the layer's box, through the box's own projection.
    #[allow(clippy::too_many_arguments)]
    fn compose(
        &mut self,
        cb: &gpu::CommandBuffer,
        li: usize,
        children: &[usize],
        [fw, fh]: [usize; 2],
        ctx: &DrawCtx,
        world: &Mat4,
        uv: [f32; 2],
        s: &Surface<'_>,
        shared: &mut Shared,
        input: FrameInput,
    ) -> Result<Retained<Texture>, Error> {
        let out = self.pool.take(&self.gpu, fw, fh)?;
        // The children's pipelines are built for the frame's sample count.
        let msaa = if self.samples > 1 {
            let key = (fw, fh);
            if !self.compose_msaa.contains_key(&key) {
                let t = self.gpu.render_target(fw, fh, TARGET_FORMAT, self.samples)?;
                let _ = self.compose_msaa.insert(key, t);
            }
            self.compose_msaa.get(&key).cloned()
        } else {
            None
        };
        let enc = gpu::begin(cb, &out, msaa.as_deref(), Some([0.0; 4]))?;
        if self.scene.layers[li].copy_background {
            if let Some(item) = &self.layers[li].base {
                self.draw(&enc, item, &DrawCtx { color: [1.0; 3], ..*ctx }, uv, input, None, &shared.frame_copy, None);
            }
        }
        let [w, h] = ctx.size;
        let view_projection = mul(&ortho(-w / 2.0, w / 2.0, h / 2.0, -h / 2.0), &models::inverse(world));
        let mut sub = Surface {
            tex: &out,
            msaa: msaa.as_deref(),
            main: Some(enc),
            view_projection,
            ortho_projection: view_projection,
            view: s.view,
            fit: fw as f32 / (w * axis_scale(world)[0]).max(0.001),
        };
        for &child in children {
            self.draw_subtree(cb, child, &mut sub, shared, input)?;
        }
        if let Some(enc) = sub.main.take() {
            enc.endEncoding();
        }
        Ok(out)
    }

    /// Draws layer `li` and, unless it composes them itself, its children onto `s`.
    fn draw_subtree(
        &mut self,
        cb: &gpu::CommandBuffer,
        li: usize,
        s: &mut Surface<'_>,
        shared: &mut Shared,
        input: FrameInput,
    ) -> Result<(), Error> {
        if !self.layers[li].shown {
            return Ok(());
        }
        self.draw_layer(cb, li, None, s, shared, input)?;
        if !self.scene.layers[li].passthrough {
            for child in self.children(li) {
                self.draw_subtree(cb, child, s, shared, input)?;
            }
        }
        Ok(())
    }

    /// The layers whose parent is `li`, in file order.
    fn children(&self, li: usize) -> Vec<usize> {
        let id = self.scene.layers[li].id;
        (0..self.scene.layers.len()).filter(|&i| self.scene.layers[i].parent == Some(id)).collect()
    }

    /// Whether a compose layer above `li` draws it into its own buffer.
    fn inside_compose(&self, li: usize) -> bool {
        if self.perspective() {
            return false;
        }
        let mut parent = self.scene.layers[li].parent;
        for _ in 0..32 {
            let Some(p) = parent.and_then(|id| self.scene.layers.iter().find(|l| l.id == id)) else { return false };
            if p.passthrough {
                return true;
            }
            parent = p.parent;
        }
        false
    }

    /// Effect buffer pixels per layer pixel, per axis, so a layer stretched in one direction gets
    /// a buffer of its screen shape. Effects never need more detail than the screen shows, nor
    /// more than the layer has: one buffer pixel per image pixel, or the text bitmap's scale. A
    /// buffer of a layer `size` units large also stays within the GPU's texture size.
    fn buffer_scale(&self, li: usize, world: &Mat4, fit: f32, size: [f32; 2]) -> [f32; 2] {
        let finest = self.layers[li].text.map_or(1.0, |t| t.scale);
        let fits = MAX_BUFFER_EDGE / size[0].max(size[1]).max(1.0);
        axis_scale(world).map(|s| (fit * s).min(finest).min(fits).max(0.05))
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
            || self.particles.iter().any(ParticleGpu::reads_frame)
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

    /// Draws a part of the finished scene onto the target (one sample per pixel), through the
    /// colour grade when it is on.
    fn present_rect(
        &mut self,
        enc: &gpu::Encoder,
        tex: &Texture,
        blend: Blend,
        mvp: Mat4,
        rect: [f32; 4],
    ) -> Result<(), Error> {
        if !self.grade.active() {
            return self.composite_rect(enc, tex, 0, blend, 1, mvp, rect, [1.0; 3], 1.0);
        }
        let pipeline = self.gpu.grade(blend, TARGET_FORMAT)?;
        enc.setRenderPipelineState(&pipeline);
        // Matches `G` in the grade shader: mvp, colour, params, grade.
        let mut u = [0f32; 28];
        u[..16].copy_from_slice(&mvp);
        u[16..20].copy_from_slice(&[1.0; 4]);
        if let Some(params) = self.grade.adjust {
            u[20..24].copy_from_slice(&params);
            u[24] = 1.0;
        }
        let lut = match &self.grade.filter {
            Some((_, table, strength)) => {
                u[25] = *strength;
                table
            }
            None => &self.neutral_lut,
        };
        let bytes: Vec<u8> = u.iter().flat_map(|f| f.to_le_bytes()).collect();
        gpu::set_bytes(enc, true, &bytes, 0);
        gpu::set_bytes(enc, false, &bytes, 0);
        gpu::set_bytes(enc, true, &quad_rect(rect), shader::VERTEX_BUFFER_SLOT as usize);
        // SAFETY: slots 0 and 1 exist in the grade shader; the textures outlive the encoder's use.
        unsafe {
            enc.setFragmentTexture_atIndex(Some(tex), 0);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[0]), 0);
            enc.setFragmentTexture_atIndex(Some(lut), 1);
            enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[0]), 1);
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4);
        }
        Ok(())
    }

    /// The scene's glow: bright parts at a quarter of the size, blurred twice. Bloom is
    /// low-frequency, so the small buffers lose nothing visible.
    fn bloom(&mut self, cb: &gpu::CommandBuffer, src: &Texture) -> Result<Retained<Texture>, Error> {
        let b = &self.scene.bloom;
        let num = |v: Value, d: f32| floats(&v).first().copied().unwrap_or(d);
        let threshold = num(b.threshold.get(&self.props), 0.65);
        let strength = num(b.strength.get(&self.props), 2.0);
        let (w, h) = ((src.width() / 4).max(1), (src.height() / 4).max(1));
        let a = self.pool.take(&self.gpu, w, h)?;
        let enc = gpu::begin(cb, &a, None, Some([0.0; 4]))?;
        let texel = (1.0 / src.width().max(1) as f32, 1.0 / src.height().max(1) as f32);
        self.blur_library_pass(&enc, "wm_bright_fs", src, [0.0, 0.0, 1.0, 1.0], texel, [threshold, strength])?;
        enc.endEncoding();
        let out = a;
        for radius in [1.0f32, 2.5] {
            let tmp = self.pool.take(&self.gpu, w, h)?;
            let enc = gpu::begin(cb, &tmp, None, Some([0.0; 4]))?;
            self.blur_pass(&enc, &out, [0.0, 0.0, 1.0, 1.0], (radius / w as f32, 0.0))?;
            enc.endEncoding();
            let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
            self.blur_pass(&enc, &tmp, [0.0, 0.0, 1.0, 1.0], (0.0, radius / h as f32))?;
            enc.endEncoding();
            self.pool.give(tmp);
        }
        Ok(out)
    }

    /// A blurred copy of the part of `src` the rectangle names. The picture is halved four
    /// times, each step averaging a 4x4 block so nothing aliases, then blurred at that size;
    /// drawn back up with linear filtering it gives a soft, even backdrop.
    fn blur_frame(
        &mut self,
        cb: &gpu::CommandBuffer,
        src: &Texture,
        rect: [f32; 4],
    ) -> Result<Retained<Texture>, Error> {
        let mut w = (src.width() as f32 * rect[2]).round().max(1.0) as usize;
        let mut h = (src.height() as f32 * rect[3]).round().max(1.0) as usize;
        let mut cur: Option<Retained<Texture>> = None;
        for _ in 0..4 {
            (w, h) = ((w / 2).max(1), (h / 2).max(1));
            let next = self.pool.take(&self.gpu, w, h)?;
            let (input, area): (&Texture, [f32; 4]) = match &cur {
                Some(t) => (t, [0.0, 0.0, 1.0, 1.0]),
                None => (src, rect),
            };
            let texel = (1.0 / input.width().max(1) as f32, 1.0 / input.height().max(1) as f32);
            let enc = gpu::begin(cb, &next, None, Some([0.0; 4]))?;
            self.blur_library_pass(&enc, "wm_bright_fs", input, area, texel, [0.0, 1.0])?;
            enc.endEncoding();
            if let Some(t) = cur.replace(next) {
                self.pool.give(t);
            }
        }
        let out = cur.ok_or_else(|| Error::Metal("blur".into()))?;
        for radius in [1.0f32, 2.0] {
            let tmp = self.pool.take(&self.gpu, w, h)?;
            let enc = gpu::begin(cb, &tmp, None, Some([0.0; 4]))?;
            self.blur_pass(&enc, &out, [0.0, 0.0, 1.0, 1.0], (radius / w as f32, 0.0))?;
            enc.endEncoding();
            let enc = gpu::begin(cb, &out, None, Some([0.0; 4]))?;
            self.blur_pass(&enc, &tmp, [0.0, 0.0, 1.0, 1.0], (0.0, radius / h as f32))?;
            enc.endEncoding();
            self.pool.give(tmp);
        }
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
        self.blur_library_pass(enc, "wm_blur_fs", src, rect, dir, [0.0; 2])
    }

    #[allow(clippy::too_many_arguments)]
    fn blur_library_pass(
        &mut self,
        enc: &gpu::Encoder,
        fragment: &'static str,
        src: &Texture,
        rect: [f32; 4],
        dir: (f32, f32),
        tp: [f32; 2],
    ) -> Result<(), Error> {
        let mut u = [0f32; 24];
        u[..16].copy_from_slice(&FBO_MVP);
        u[16..20].copy_from_slice(&rect);
        u[20] = dir.0;
        u[21] = dir.1;
        u[22] = tp[0];
        u[23] = tp[1];
        let bytes: Vec<u8> = u.iter().flat_map(|f| f.to_le_bytes()).collect();
        self.blur_library_draw(enc, fragment, &bytes, &bytes, Some(src))
    }

    /// Draws a blur-library fragment function over the whole target, with its vertex and fragment
    /// uniforms; the vertex shader reads the full-target transform from the start of `vertex`.
    fn blur_library_draw(
        &mut self,
        enc: &gpu::Encoder,
        fragment: &'static str,
        vertex: &[u8],
        uniforms: &[u8],
        src: Option<&Texture>,
    ) -> Result<(), Error> {
        let pipeline = self.gpu.blur_pipeline(fragment, 1)?;
        enc.setRenderPipelineState(&pipeline);
        gpu::set_bytes(enc, true, vertex, 0);
        gpu::set_bytes(enc, false, uniforms, 0);
        gpu::set_bytes(
            enc,
            true,
            &quad_rect([0.0, 0.0, 1.0, 1.0]),
            shader::VERTEX_BUFFER_SLOT as usize,
        );
        // SAFETY: slot 0 exists in the blur shaders; the texture outlives the encoder's use.
        unsafe {
            if let Some(src) = src {
                enc.setFragmentTexture_atIndex(Some(src), 0);
                enc.setFragmentSamplerState_atIndex(Some(&self.gpu.samplers[0]), 0);
            }
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4);
        }
        Ok(())
    }

    /// Adds the glow of up to `Haze::BATCH` volumetric lights onto `target` (see `light::Haze`):
    /// marched at an eighth of the size, blurred with `blur_k3` across and then down, and drawn
    /// back up additively. Returns the open pass on `target`, which starts with `clear` if given.
    #[allow(clippy::too_many_arguments)]
    fn draw_haze(
        &mut self,
        cb: &gpu::CommandBuffer,
        lights: &[Haze],
        inverse_view_projection: &Mat4,
        target: &Texture,
        msaa: Option<&Texture>,
        clear: Option<[f64; 4]>,
    ) -> Result<Retained<gpu::Encoder>, Error> {
        let (w, h) = ((target.width() / 8).max(1), (target.height() / 8).max(1));
        let glow = self.pool.take(&self.gpu, w, h)?;
        let tmp = self.pool.take(&self.gpu, w, h)?;
        let mut vertex = [0f32; 24];
        vertex[..16].copy_from_slice(&FBO_MVP);
        let vertex: Vec<u8> = vertex.iter().flat_map(|f| f.to_le_bytes()).collect();
        let enc = gpu::begin(cb, &glow, None, Some([0.0, 0.0, 0.0, 1.0]))?;
        let uniforms = Haze::uniforms(lights, inverse_view_projection);
        self.blur_library_draw(&enc, "wm_haze_fs", &vertex, &uniforms, None)?;
        enc.endEncoding();
        let whole = [0.0, 0.0, 1.0, 1.0];
        let enc = gpu::begin(cb, &tmp, None, None)?;
        self.blur_library_pass(&enc, "wm_k3_fs", &glow, whole, (1.0 / w as f32, 0.0), [0.0; 2])?;
        enc.endEncoding();
        let enc = gpu::begin(cb, &glow, None, None)?;
        self.blur_library_pass(&enc, "wm_k3_fs", &tmp, whole, (0.0, 1.0 / h as f32), [0.0; 2])?;
        enc.endEncoding();
        let enc = gpu::begin(cb, target, msaa, clear)?;
        self.composite_rect(&enc, &glow, 0, Blend::Additive, self.samples, FBO_MVP, whole, [1.0; 3], 1.0)?;
        self.pool.give(glow);
        self.pool.give(tmp);
        Ok(enc)
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
        let full_target = self.bind(enc, item, ctx, input, prev, named, tex0, None);
        let verts = if full_target { clip_quad(uv) } else { quad(uv) };
        gpu::set_bytes(enc, true, &verts, shader::VERTEX_BUFFER_SLOT as usize);
        // SAFETY: a 4-vertex strip from the bytes set above.
        unsafe {
            enc.drawPrimitives_vertexStart_vertexCount(MTLPrimitiveType::TriangleStrip, 0, 4)
        };
    }

    /// Sets a draw item's pipeline, textures and uniforms; `particle` holds the particle
    /// shaders' own inputs for a particle draw. Returns whether the draw covers the whole target,
    /// whose quad is then given in clip space.
    #[allow(clippy::too_many_arguments)]
    fn bind(
        &self,
        enc: &gpu::Encoder,
        item: &DrawItem,
        ctx: &DrawCtx,
        input: FrameInput,
        prev: Option<&Retained<Texture>>,
        named: &HashMap<String, Retained<Texture>>,
        tex0: Option<&Texture>,
        particle: Option<&particles::ShaderValues>,
    ) -> bool {
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
                        [1.0, 1.0]
                    } else if name == "previous" || name.starts_with("_rt_imageLayerComposite_") {
                        ctx.buffer_scale
                    } else {
                        ctx.fbo_scale
                    };
                    let (w, h) = (tex.width() as f32 / k[0], tex.height() as f32 / k[1]);
                    bound.push((*slot, *index, tex, 0, [w, h, w, h]));
                }
            }
        }
        let res = |n: usize| bound.iter().find(|b| b.1 == n).map_or([1.0; 4], |b| b.4);

        let mut vs = item.vs.clone();
        let mut fs = item.fs.clone();
        // Effect passes draw a full-target quad. Some effect shaders skip the matrix and use
        // the position as clip space, so the quad is given in clip space with an identity matrix.
        let full_target = ctx.mvp == FBO_MVP;
        let mvp = if full_target { IDENTITY } else { ctx.mvp };
        // In an effect pass the pointer is unprojected into the layer: its pixels (y up, centred)
        // for the model-view-projection inverse, its [-1, 1] square (y up) for the texture
        // projection inverse. Both are the identity for a layer that exactly fills the view.
        let [w, h] = ctx.size.map(|s| s.max(0.001));
        let (mvp_inv, tex_proj_inv) = if full_target {
            (
                invert_affine_2d(&mul(&ctx.screen_mvp, &scale(1.0 / w, -1.0 / h, 1.0))),
                invert_affine_2d(&mul(&ctx.screen_mvp, &scale(0.5, -0.5, 1.0))),
            )
        } else {
            (invert_affine_2d(&mvp), IDENTITY)
        };
        for (vertex, u, d) in &item.dynamic {
            let v: Vec<f32> = match d {
                Dyn::View(which) => {
                    write_uniform(if *vertex { &mut vs } else { &mut fs }, u, self.view_uniform(*which, ctx));
                    continue;
                }
                Dyn::Mvp => mvp.to_vec(),
                Dyn::Model => ctx.model.to_vec(),
                Dyn::ModelInverse => models::inverse(&ctx.model).to_vec(),
                Dyn::ViewProjection => ctx.view_projection.to_vec(),
                Dyn::MvpInverse => mvp_inv.to_vec(),
                Dyn::TexProjectionInverse => tex_proj_inv.to_vec(),
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
                Dyn::Parallax => self.parallax_position().to_vec(),
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
                Dyn::Audio(right, n) => bands(&self.audio[*right as usize], *n),
                Dyn::Particle(p) => match particle {
                    Some(values) => values.get(*p).to_vec(),
                    None => continue,
                },
            };
            write_uniform(if *vertex { &mut vs } else { &mut fs }, u, &v);
        }
        gpu::set_buffer_or_bytes(&self.gpu, enc, true, &vs, 0);
        gpu::set_buffer_or_bytes(&self.gpu, enc, false, &fs, 0);
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
        full_target
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
            || !self.particles.is_empty()
            || self
                .puppets
                .iter()
                .any(|p| p.animations.iter().any(|a| a.visible && a.animation.is_some()))
            || !self.timelines_settled
            || self.scripts_animated()
            || self.parallax_now().is_some()
            || self.models_animated()
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

/// A spectrum regrouped into `n` bands, each the mean of the bins it covers.
pub(crate) fn bands(src: &[f32], n: usize) -> Vec<f32> {
    let m = src.len();
    (0..n)
        .map(|i| {
            if m == 0 {
                return 0.0;
            }
            let a = i * m / n;
            let b = ((i + 1) * m / n).max(a + 1).min(m);
            src[a..b].iter().sum::<f32>() / (b - a) as f32
        })
        .collect()
}

/// Length of the world matrix's x and y axes, the larger one.
fn world_scale(m: &Mat4) -> f32 {
    let [x, y] = axis_scale(m);
    x.max(y)
}

/// Length of the matrix's x and y axes: how much it scales each.
fn axis_scale(m: &Mat4) -> [f32; 2] {
    [m[0].hypot(m[1]), m[4].hypot(m[5])]
}

/// The scale of a text layer's own effect buffers (`fbos`, each `1/div` of the layer) when its
/// main buffers are at `k` of the layer's size. A quarter-size blur buffer holds a quarter of the
/// layer's pixels; text has no pixel size of its own, and once the screen magnifies such a buffer
/// the glyphs turn blocky and soft. So the smallest divided buffer is as fine as the main buffers
/// and its siblings keep their size relative to it. The blur keeps its width: kernels step by
/// the native sizes that the resolution uniforms report.
fn text_fbo_scale(k: [f32; 2], fbos: &[(String, f32)]) -> [f32; 2] {
    let div = fbos.iter().map(|(_, d)| *d).reduce(f32::min).unwrap_or(1.0);
    k.map(|k| k * div)
}

/// Text raster scales are powers of 2^(1/8), about 9 % apart.
const TEXT_SCALE_STEPS_PER_OCTAVE: f32 = 8.0;
/// The finest text raster scale, for a view zoomed far in. The text module also keeps a bitmap
/// within the texture size, so a long string is not lost at this scale.
const TEXT_MAX_SCALE: f32 = 16.0;
/// The longest edge, in pixels, of an effect buffer: the GPU's texture size limit.
const MAX_BUFFER_EDGE: f32 = 16_384.0;

/// Bitmap pixels per design unit for a text layer that shows at `on_screen` screen pixels per
/// design unit. Rounding up to the next step means the bitmap is never magnified (blurry) and
/// never shrunk by more than one step (bilinear sampling without mipmaps aliases when it shrinks
/// much more), and a layer whose scale animates rasterises once per step instead of every frame.
fn text_raster_scale(on_screen: f32) -> f32 {
    if !(on_screen.is_finite() && on_screen > 0.0) {
        return 1.0;
    }
    // The bias keeps a scale that sits on a step (1, 2) from rounding up through float error.
    let step = (on_screen.log2() * TEXT_SCALE_STEPS_PER_OCTAVE - 1e-3).ceil();
    (step / TEXT_SCALE_STEPS_PER_OCTAVE).exp2().min(TEXT_MAX_SCALE)
}

/// The part of the centred unit quad that `mvp` puts inside clip space grown to `reach` (1 is the
/// target itself), as texture coordinates `[u0, v0, u1, v1]` of the quad.
fn visible_uv(mvp: &Mat4, reach: f32) -> [f32; 4] {
    let inv = invert_affine_2d(mvp);
    let p = [[-reach, -reach], [reach, -reach], [-reach, reach], [reach, reach]]
        .map(|[x, y]| [inv[0] * x + inv[4] * y + inv[12] + 0.5, inv[1] * x + inv[5] * y + inv[13] + 0.5]);
    let lo = |a: usize| p.iter().map(|c| c[a]).fold(f32::INFINITY, f32::min).clamp(0.0, 1.0);
    let hi = |a: usize| p.iter().map(|c| c[a]).fold(f32::NEG_INFINITY, f32::max).clamp(0.0, 1.0);
    [lo(0), lo(1), hi(0), hi(1)]
}

/// Limits drawing to the `uv` part of the target.
fn scissor(enc: &gpu::Encoder, target: &Texture, uv: [f32; 4]) {
    let (w, h) = (target.width() as f32, target.height() as f32);
    let x = (uv[0] * w).floor() as usize;
    let y = (uv[1] * h).floor() as usize;
    let x1 = ((uv[2] * w).ceil() as usize).clamp(x + 1, target.width());
    let y1 = ((uv[3] * h).ceil() as usize).clamp(y + 1, target.height());
    let x = x.min(target.width() - 1);
    let y = y.min(target.height() - 1);
    enc.setScissorRect(MTLScissorRect { x, y, width: x1 - x, height: y1 - y });
}

/// Whether the centred unit quad, put through `mvp` (an orthographic one), lies wholly outside
/// clip space.
fn off_target(mvp: &Mat4) -> bool {
    let corners = [[-0.5f32, -0.5], [0.5, -0.5], [-0.5, 0.5], [0.5, 0.5]]
        .map(|[x, y]| [mvp[0] * x + mvp[4] * y + mvp[12], mvp[1] * x + mvp[5] * y + mvp[13]]);
    (0..2).any(|a| corners.iter().all(|c| c[a] > 1.0) || corners.iter().all(|c| c[a] < -1.0))
}

/// The rope shader; particle ropes draw with it whatever shader their material names.
const ROPE_SHADER: &str = "genericropeparticle";

/// A sprite sheet as the particle shaders read it: frame 0's size in texture coordinates, the
/// frame count and a frame's height over its width.
fn sheet_info(t: &TexEntry) -> Option<particles::SheetInfo> {
    let f = t.frames.first()?;
    let w = f.width_x.hypot(f.width_y);
    let h = f.height_x.hypot(f.height_y);
    Some(particles::SheetInfo {
        frame: [w / t.res[0].max(1.0), h / t.res[1].max(1.0)],
        count: t.frames.len() as f32,
        aspect: if w > 0.0 { h / w } else { 1.0 },
    })
}

fn renderer_name(kind: &particles::RendererKind) -> &'static str {
    match kind {
        particles::RendererKind::Sprite => "sprite",
        particles::RendererKind::SpriteTrail { .. } => "spritetrail",
        particles::RendererKind::Rope { .. } => "rope",
        particles::RendererKind::RopeTrail { .. } => "ropetrail",
    }
}

/// The camera perspective particle systems are seen through, in scene space (y up): looking
/// down -z at the scene's centre from where the z = 0 plane fills the view exactly as the
/// orthographic view does, so depth alone moves and scales a particle.
fn perspective(width: f32, height: f32, fov: f32) -> Mat4 {
    let d = height / (2.0 * (fov * 0.5).tan());
    let (cx, cy) = (width * 0.5, height * 0.5);
    [
        1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -cx / d, -cy / d, 1.0, -1.0 / d, 0.0, 0.0, 0.0, 1.0,
    ]
}

/// Centred unit quad as a triangle strip, y down; texcoord (0, 0) is the image's top-left.
fn quad(uv: [f32; 2]) -> Vec<u8> {
    quad_rect([0.0, 0.0, uv[0], uv[1]])
}

/// The unit quad already in clip space: what `FBO_MVP` would make of it.
fn clip_quad(uv: [f32; 2]) -> Vec<u8> {
    let (l, r, b, t) = (-1.0f32, 1.0, -1.0, 1.0);
    let v = [
        [l, b, 0.0, 0.0, uv[1]],
        [r, b, 0.0, uv[0], uv[1]],
        [l, t, 0.0, 0.0, 0.0],
        [r, t, 0.0, uv[0], 0.0],
    ];
    v.iter()
        .flatten()
        .flat_map(|f: &f32| f.to_le_bytes())
        .collect()
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

/// Whether the design, placed at `rect` (x, y, width, height in target pixels), leaves part of the
/// `tw`×`th` target empty. Half a pixel of slack keeps a rounded exact fit from counting as a gap.
fn leaves_gaps(rect: (f32, f32, f32, f32), tw: f32, th: f32) -> bool {
    let (x, y, w, h) = rect;
    x > 0.5 || y > 0.5 || x + w < tw - 0.5 || y + h < th - 0.5
}


/// The 2D camera's offset at `time` for a scene's shake settings (amplitude, roughness, speed), in
/// design units: Wallpaper Engine's shake loop (`camera::shake`) in the image plane, a hundredth of
/// the scene's height per unit of amplitude.
fn camera_shake([amplitude, roughness, speed]: [f32; 3], time: f32, height: f32) -> [f32; 2] {
    // `camera::shake` scales the loop by a tenth of its amplitude.
    let v = crate::camera::shake([10.0, roughness, speed], time);
    let k = amplitude * 0.01 * height;
    [v[0] * k, v[1] * k]
}

/// A root layer's camera parallax offset, as Wallpaper Engine computes it: its origin's distance
/// from the parallax point times the amount and its depth, in design units (y up). Nothing
/// clamps it and the view does not zoom, so a far layer can uncover an edge, as there.
/// The next volumetric lights, at most a pass's worth, that are due before layer `layer`.
fn due_hazes(hazes: &[(usize, Haze)], next: &mut usize, layer: usize) -> Option<Vec<Haze>> {
    let batch: Vec<Haze> = hazes[*next..]
        .iter()
        .take_while(|(place, _)| *place <= layer)
        .take(Haze::BATCH)
        .map(|(_, h)| *h)
        .collect();
    *next += batch.len();
    (!batch.is_empty()).then_some(batch)
}

fn parallax_offset(origin: [f32; 2], point: [f32; 2], amount: f32, depth: [f32; 2]) -> [f32; 2] {
    [0, 1].map(|i| (origin[i] - point[i]) * amount * depth[i])
}

fn day_time() -> f32 {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let offset = objc2_foundation::NSTimeZone::localTimeZone().secondsFromGMT() as i64;
    (secs + offset).rem_euclid(86_400) as f32 / 86_400.0
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


/// Where an animation is after `t` seconds, by its play mode: `mirror` plays forward then back,
/// `single` plays once and holds the last frame, anything else loops.
/// A shared buffer holding `indices`.
fn index_buffer(gpu: &Gpu, indices: &[u16]) -> Result<Retained<ProtocolObject<dyn MTLBuffer>>, Error> {
    let ptr = NonNull::new(indices.as_ptr() as *mut c_void)
        .ok_or_else(|| Error::Format("puppet has no indices".into()))?;
    // SAFETY: the buffer copies `indices.len()` u16 values immediately.
    unsafe {
        gpu.device.newBufferWithBytes_length_options(ptr, indices.len() * 2, MTLResourceOptions::StorageModeShared)
    }
    .ok_or_else(|| Error::Metal("puppet index buffer".into()))
}

impl PuppetGpu {
    /// Plays the animations on to scene time `time` and poses the skeleton; `object` is the
    /// layer's placement, which the bones' physics lags behind. Every display draws the same
    /// frame, so a time already reached plays nothing; a time before it (the scene restarted)
    /// starts over. Hidden, paused and finished layers hold their place; a layer a script played
    /// once goes at its first ended event.
    fn advance(&mut self, time: f32, object: Option<&Mat4>) {
        let mut dt = time - self.clock;
        self.clock = time;
        if dt < 0.0 {
            self.rig.reset(&self.model);
            for a in &mut self.animations {
                a.restart();
            }
            dt = time;
        }
        self.ended.clear();
        let model = Rc::clone(&self.model);
        let mut gone = Vec::new();
        for a in &mut self.animations {
            let Some(animation) = a.animation.and_then(|i| model.animations.get(i)) else { continue };
            if a.advance(dt, animation.duration_seconds(), Mode::of(&animation.flag)) {
                self.ended.push(a.uid);
                if a.once {
                    gone.push(a.uid);
                }
            }
        }
        self.animations.retain(|a| !gone.contains(&a.uid));
        self.pose_bones(object.map(|o| (dt.max(0.0), o)));
    }

    /// Poses the skeleton for the animation layers' current places (see `pose`), stepping
    /// physics by `step` (seconds and the layer's placement).
    fn pose_bones(&mut self, step: Option<(f32, &Mat4)>) {
        let model = Rc::clone(&self.model);
        let layers: Vec<pose::Layer<'_>> = self
            .animations
            .iter()
            .filter(|a| a.visible)
            .filter_map(|a| {
                let animation = model.animations.get(a.animation?)?;
                Some(pose::Layer {
                    animation,
                    time: a.time,
                    weight: a.weight(animation.duration_seconds()),
                    additive: a.additive,
                })
            })
            .collect();
        // Puppet space is y up; the layer's placement is y down, like the draw's.
        let flip = [[1.0, 0.0, 0.0, 0.0], [0.0, -1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]];
        let object = step.map(|(_, o)| mat::mul(&flip, &std::array::from_fn(|r| std::array::from_fn(|c| o[r * 4 + c]))));
        let step = step.zip(object.as_ref()).map(|((dt, _), object)| physics::Step { dt, object });
        self.rig.pose(&model, &layers, step);
    }

    /// Sorts the parts again when an animation moved bones in the draw order: by each part's
    /// order (its bone's rest order plus its offset) plus the bone's current order, a stable sort
    /// of last frame's order. Wallpaper Engine adds the rest order twice for a bone no animation
    /// moves; so does this. Returns whether the order changed.
    fn reorder(&mut self) -> bool {
        let e = &self.rig.extras;
        if !e.resort || e.orders.is_empty() {
            return false;
        }
        let m = &self.model;
        let key = |p: usize| {
            let s = &m.segments[p];
            let bone = s.bone as usize;
            let base = m.rest_orders.get(bone).copied().unwrap_or(0) + s.order;
            (base as f32 + e.orders.get(bone).copied().unwrap_or(0.0)) as i32
        };
        if self.parts.windows(2).all(|w| key(w[0]) <= key(w[1])) {
            return false;
        }
        self.parts.sort_by_key(|&p| key(p));
        true
    }

    /// The index buffer's contents in the current part order.
    fn ordered_indices(&self) -> Vec<u16> {
        let m = &self.model;
        let mut out = Vec::with_capacity(m.indices.len());
        for &p in &self.parts {
            let s = &m.segments[p];
            let first = s.first_index as usize;
            out.extend_from_slice(&m.indices[first..first + s.index_count as usize]);
        }
        out
    }

    /// Skinning matrices for the current pose: each bone's world matrix after undoing its
    /// bind-pose world with `bind_inverse`.
    fn bones(&self) -> Vec<mat::M4> {
        self.rig
            .world
            .iter()
            .zip(&self.bind_inverse)
            .map(|(world, inverse)| mat::mul(inverse, world))
            .collect()
    }

    /// Animated world matrix of a named attachment point, in the puppet's design units.
    fn attachment(&self, name: &str) -> Option<Mat4> {
        let att = self.model.attachments.iter().find(|a| a.name == name)?;
        let bone = self.rig.world.get(att.bone).copied().unwrap_or(mat::IDENTITY);
        let m = mat::mul(&att.matrix, &bone);
        // Row-vector rows laid end to end are the column-major array the engine uses.
        let mut out = [0.0f32; 16];
        for (i, v) in m.iter().flatten().enumerate() {
            out[i] = *v;
        }
        // Puppet space is y up; mirror the matrix into the y-down render space.
        out[1] = -out[1];
        out[4] = -out[4];
        out[13] = -out[13];
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blurred_backdrop_only_when_the_design_leaves_gaps() {
        // 16:9 design on a 16:9 target: no gap, no blur needed.
        assert!(!leaves_gaps((0.0, 0.0, 1920.0, 1080.0), 1920.0, 1080.0));
        // The same design fitted to a 16:10 target is letterboxed top and bottom.
        assert!(leaves_gaps((0.0, 38.5, 1728.0, 972.0), 1728.0, 1117.0));
        // ... and pillarboxed on a portrait target.
        assert!(leaves_gaps((0.0, 656.25, 1080.0, 607.5), 1080.0, 1920.0));
        // Zoomed in or panned past the edges: covered, unless the pan opens a gap.
        assert!(!leaves_gaps((-100.0, -50.0, 2120.0, 1180.0), 1920.0, 1080.0));
        assert!(leaves_gaps((100.0, -50.0, 2120.0, 1180.0), 1920.0, 1080.0));
    }

    #[test]
    fn framing_follows_the_alignments() {
        let design = [1920.0, 1080.0];
        let framing = |alignment, position, x, y, zoom| Framing {
            alignment,
            position,
            x,
            y,
            zoom,
            ..Framing::default()
        };
        let close = |a: [f32; 4], b: [f32; 4]| a.iter().zip(b).all(|(a, b)| (a - b).abs() < 1e-2);
        // Cover on a 16:10 target: the sides overflow and the position picks the part shown.
        let cover = |p| framed_view(&framing(Alignment::Cover, p, 0.5, 0.5, 1.0), design, [1728.0, 1080.0]);
        assert!(close(cover(0.0), [0.0, 1728.0, 0.0, 1080.0]), "{:?}", cover(0.0));
        assert!(close(cover(1.0), [192.0, 1920.0, 0.0, 1080.0]), "{:?}", cover(1.0));
        // Fill shows everything; the bars go above and below.
        let fill = framed_view(&framing(Alignment::Fill, 0.5, 0.5, 0.5, 1.0), design, [1728.0, 1080.0]);
        assert!(close(fill, [0.0, 1920.0, -60.0, 1140.0]), "{fill:?}");
        // Center is one design pixel per target pixel, placed by x and y.
        let center = framed_view(&framing(Alignment::Center, 0.5, 0.0, 1.0, 1.0), design, [960.0, 540.0]);
        assert!(close(center, [0.0, 960.0, 540.0, 1080.0]), "{center:?}");
        // Free at zoom 1 and centred is the same as center; at x 0 the scene is left of the view.
        let free = |x, zoom| framed_view(&framing(Alignment::Free, 0.5, x, 0.5, zoom), design, [960.0, 540.0]);
        assert!(close(free(0.5, 1.0), [480.0, 1440.0, 270.0, 810.0]), "{:?}", free(0.5, 1.0));
        assert!(free(0.0, 1.0)[0] >= 1920.0);
        // Zoom 2 magnifies a hundredfold around the same placement; zoom 0 shows 16 times more.
        let near = free(0.5, 2.0);
        assert!(((near[1] - near[0]) - 9.6).abs() < 1e-2 && ((near[0] + near[1]) / 2.0 - 960.0).abs() < 1e-2);
        let far = free(0.5, 0.0);
        assert!(((far[1] - far[0]) - 960.0 * 16.0).abs() < 1e-2);
        let stretch = framed_view(&framing(Alignment::Stretch, 0.5, 0.5, 0.5, 1.0), design, [500.0, 900.0]);
        assert!(close(stretch, [0.0, 1920.0, 0.0, 1080.0]));
    }

    #[test]
    fn camera_shake_is_bounded_and_zero_without_amplitude() {
        assert_eq!(camera_shake([0.0, 1.0, 3.0], 2.0, 1080.0), [0.0, 0.0]);
        let mut moved = false;
        for i in 0..200 {
            let o = camera_shake([0.5, 1.0, 3.0], i as f32 * 0.1, 1080.0);
            // A unit loop scaled to 0.5% of the height.
            assert!(o[0].abs() <= 5.4 + 1e-3 && o[1].abs() <= 5.4 + 1e-3, "{o:?}");
            moved |= o[0] != 0.0;
        }
        assert!(moved);
    }

    #[test]
    fn parallax_and_shake_follow_user_properties() {
        let json: Value = serde_json::json!({
            "cameraparallax": {"user": "p", "value": true},
            "cameraparallaxamount": {"user": "amt", "value": 0.2},
            "camerashake": {"user": "s", "value": false},
        });
        let bound = |k: &str, d: Value| scene::Bound::parse(json.get(k), d);
        let parallax = scene::Parallax {
            enabled: bound("cameraparallax", Value::Bool(false)),
            amount: bound("cameraparallaxamount", Value::from(0.5)),
            delay: bound("cameraparallaxdelay", Value::from(0.1)),
            mouse_influence: bound("cameraparallaxmouseinfluence", Value::from(1.0)),
        };
        let mut props = HashMap::new();
        // Defaults from the file: on, amount 0.2, influence 1 when absent.
        let on = parallax.now(&props).expect("default is on");
        assert!((on.amount - 0.2).abs() < 1e-6 && (on.mouse_influence - 1.0).abs() < 1e-6);
        // The user switches it off and moves the slider.
        props.insert("p".into(), Value::Bool(false));
        assert!(parallax.now(&props).is_none());
        props.insert("p".into(), Value::Bool(true));
        props.insert("amt".into(), Value::from(0.9));
        assert!((parallax.now(&props).unwrap().amount - 0.9).abs() < 1e-6);
    }

    #[test]
    fn parallax_moves_layers_by_their_distance_from_the_point() {
        // A centred layer and a centred point: nothing moves.
        assert_eq!(parallax_offset([960.0, 540.0], [960.0, 540.0], 0.5, [1.0, 1.0]), [0.0, 0.0]);
        // The point at the right edge: the layer moves against it by amount * depth * distance.
        let o = parallax_offset([960.0, 540.0], [1920.0, 540.0], 0.21, [1.0, 1.0]);
        assert!((o[0] + 201.6).abs() < 1e-3 && o[1] == 0.0, "{o:?}");
        // Depth 0 stays; a layer left of the centre spreads outward even with the point centred.
        assert_eq!(parallax_offset([0.0, 540.0], [1920.0, 540.0], 0.21, [0.0, 0.0]), [0.0, 0.0]);
        assert!(parallax_offset([100.0, 540.0], [960.0, 540.0], 0.5, [1.0, 1.0])[0] < 0.0);
    }

    #[test]
    fn text_rasterises_at_the_next_step_above_its_screen_scale() {
        let step = 2f32.powf(1.0 / TEXT_SCALE_STEPS_PER_OCTAVE);
        for on_screen in [0.05, 0.42, 0.75, 1.0, 1.5, 1.72, 2.0, 3.0, 4.0] {
            let s = text_raster_scale(on_screen);
            // Never magnified, never shrunk by more than one step.
            let ratio = s / on_screen;
            assert!((0.9999..=step * 1.0001).contains(&ratio), "{on_screen} -> {s}");
        }
        // A scale on a step keeps it; one just above takes the next.
        assert_eq!(text_raster_scale(2.0), 2.0);
        assert!(text_raster_scale(2.01) > 2.0);
        // Nearby scales share a step, so a slowly scaling layer reuses its bitmap.
        assert_eq!(text_raster_scale(1.45), text_raster_scale(1.5));
        // A huge zoom stops at the limit; a broken scale falls back to 1.
        assert_eq!(text_raster_scale(100.0), TEXT_MAX_SCALE);
        assert_eq!(text_raster_scale(f32::NAN), 1.0);
        assert_eq!(text_raster_scale(0.0), 1.0);
    }

    #[test]
    fn text_effect_buffers_are_as_fine_as_the_screen() {
        let fbos = |divs: &[f32]| -> Vec<(String, f32)> {
            divs.iter().enumerate().map(|(i, d)| (format!("_rt_Buffer{i}"), *d)).collect()
        };
        let (quarters, mixed) = (fbos(&[4.0, 4.0]), fbos(&[2.0, 4.0]));
        // A quarter-size buffer gets the main buffers' pixels: size * k * 4 / 4.
        assert_eq!(text_fbo_scale([0.42, 0.4], &quarters), [1.68, 1.6]);
        // With mixed sizes the half buffer matches the main buffers, the quarter is half of that.
        assert_eq!(text_fbo_scale([1.5, 1.5], &mixed), [3.0, 3.0]);
        assert_eq!(text_fbo_scale([0.5, 0.5], &[]), [0.5, 0.5]);
    }

    #[test]
    fn visible_part_of_a_layer_hanging_off_the_right() {
        // Quad spanning clip x 0..2: its left half shows.
        let m = mul(&translate(1.0, 0.0, 0.0), &scale(2.0, 2.0, 1.0));
        let uv = visible_uv(&m, 1.0);
        assert!((uv[0] - 0.0).abs() < 1e-5 && (uv[2] - 0.5).abs() < 1e-5, "{uv:?}");
        assert!((uv[1] - 0.0).abs() < 1e-5 && (uv[3] - 1.0).abs() < 1e-5, "{uv:?}");
        assert_eq!(visible_uv(&FBO_MVP, 1.0), [0.0, 0.0, 1.0, 1.0]);
    }

    #[test]
    fn a_layer_wholly_beside_the_target_is_off_target() {
        // Unit quad scaled to 0.1 wide, centred at x = 1.1 in clip space: entirely right of it.
        let beside = mul(&translate(1.1, 0.0, 0.0), &scale(0.1, 1.0, 1.0));
        assert!(off_target(&beside));
        // Overlapping the right edge by a little still counts as on target.
        let edge = mul(&translate(0.98, 0.0, 0.0), &scale(0.1, 1.0, 1.0));
        assert!(!off_target(&edge));
        assert!(!off_target(&FBO_MVP));
    }

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