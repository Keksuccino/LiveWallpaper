//! Model objects in the frame: their meshes and materials on the GPU, the camera they are seen
//! through, the scene's lights, and the depth-buffered passes they draw in.
//!
//! A model layer draws within the scene's layer order. Consecutive model layers form a run that
//! shares one render pass with a depth buffer; the 2D layers around them keep their passes without
//! one (their pipelines, the particle one among them, carry no depth format). When all model
//! layers follow each other, the depth buffer lives within that one pass and takes no memory on
//! Apple GPUs.
//!
//! Within a run the opaque parts draw first, in layer order, then the blended ones from the
//! farthest model to the nearest. Wallpaper Engine's previews need that: `neon_sunset` lists its
//! sun (a quad that writes depth even where it is clear) before the terrain behind it, yet its
//! preview shows the far terrain through the clear part of the quad.

use std::collections::HashMap;
use std::rc::Rc;

use objc2::rc::Retained;
use objc2_metal::*;

use super::{mul, scale, DrawCtx, DrawItem, Engine, FrameInput, Mat4, IDENTITY};
use crate::camera;
use crate::gpu::{self, Texture, TARGET_FORMAT};
use crate::light::{Haze, Kind, LightSpec, Lights};
use crate::mat;
use crate::model;
use crate::scene::{floats, Blend, Bound, Cull, Material};
use crate::shader::{self, Program};
use crate::Error;

/// One material's part of a model.
pub(super) struct Part {
    item: DrawItem,
    depth: Retained<gpu::DepthState>,
    cull: Cull,
    /// Draws without blending, before the blended parts of its run.
    opaque: bool,
    submesh: model::Submesh,
}

/// A visible model layer, ready to draw.
pub(super) struct ModelGpu {
    /// Scene layer index, so the model draws in layer order.
    layer: usize,
    mesh: Rc<model::Buffers>,
    parts: Vec<Part>,
    /// World matrix (y up, as the scene file places the object) and its normal matrix.
    world: Mat4,
    normal: Mat4,
    color: [f32; 3],
    alpha: f32,
}

/// The camera of the current frame.
#[derive(Debug, Clone, Copy)]
pub(super) struct View {
    /// World space to clip space, for everything placed in 3D.
    pub(super) view_projection: Mat4,
    /// `g_EyePosition`: the camera in world space. An orthographic scene's camera sits over the
    /// design's centre, 2000 units in front of it (the engine's place for it).
    eye: [f32; 3],
    /// The picture is mirrored left to right, which turns the triangles' winding around.
    mirrored: bool,
}

impl Default for View {
    fn default() -> Self {
        Self {
            view_projection: IDENTITY,
            eye: [0.0; 3],
            mirrored: false,
        }
    }
}

/// The 3D state of a scene; empty for a scene without models and lights.
#[derive(Default)]
pub(super) struct Models {
    items: Vec<ModelGpu>,
    /// Meshes by file, loaded once and shared by the layers that place the same file.
    meshes: HashMap<String, Rc<model::Buffers>>,
    lights: Lights,
    ambient: [f32; 3],
    skylight: [f32; 3],
    pub(super) view: View,
    depth: Option<Retained<Texture>>,
    /// Runs of consecutive model layers: one depth pass each per frame.
    runs: Vec<Run>,
}

/// Model layers that draw in one depth pass, as (model, part) pairs.
struct Run {
    /// The scene layer of its first model: the run draws when the layer order reaches it.
    first_layer: usize,
    /// Opaque parts, in layer order.
    opaque: Vec<(usize, usize)>,
    /// Blended parts, sorted farthest first for the current camera (see `update_view`).
    blended: Vec<(usize, usize)>,
}

/// Engine uniforms of the 3D scene: the camera and the lights.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ViewUniform {
    Eye,
    NormalModel,
    Ambient,
    Skylight,
    LegacyPosition,
    LegacyColorRadius,
    PointOrigin,
    PointColor,
    SpotOrigin,
    SpotDirection,
    SpotColor,
    SpotExponent,
    TubeOriginA,
    TubeOriginB,
    TubeColor,
    DirectionalDirection,
    DirectionalColor,
}

impl ViewUniform {
    /// The uniform an engine shader name stands for; names found in our own asset shaders and in
    /// the light arrays of the `LightingV1` chunk.
    pub(super) fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "g_EyePosition" => Self::Eye,
            "g_NormalModelMatrix" | "g_AltNormalModelMatrix" => Self::NormalModel,
            "g_LightAmbientColor" => Self::Ambient,
            "g_LightSkylightColor" => Self::Skylight,
            "g_LightsPosition" => Self::LegacyPosition,
            "g_LightsColorRadius" => Self::LegacyColorRadius,
            "g_LPoint_Origin" => Self::PointOrigin,
            "g_LPoint_Color" => Self::PointColor,
            "g_LSpot_Origin" => Self::SpotOrigin,
            "g_LSpot_Direction" => Self::SpotDirection,
            "g_LSpot_Color" => Self::SpotColor,
            "g_LSpot_Exponent" => Self::SpotExponent,
            "g_LTube_OriginA" => Self::TubeOriginA,
            "g_LTube_OriginB" => Self::TubeOriginB,
            "g_LTube_Color" => Self::TubeColor,
            "g_LDirectional_Direction" => Self::DirectionalDirection,
            "g_LDirectional_Color" => Self::DirectionalColor,
            _ => return None,
        })
    }
}

/// The legacy light slots of a draw the scene's lights do not reach: black, radius 1.
static UNLIT: Lights = Lights {
    legacy_position: [0.0; 12],
    legacy_color_radius: [
        0., 0., 0., 1., 0., 0., 0., 1., 0., 0., 0., 1., 0., 0., 0., 1.,
    ],
    point_origin: Vec::new(),
    point_color: Vec::new(),
    spot_origin: Vec::new(),
    spot_direction: Vec::new(),
    spot_color: Vec::new(),
    spot_exponent: Vec::new(),
    tube_origin_a: Vec::new(),
    tube_origin_b: Vec::new(),
    tube_color: Vec::new(),
    directional_direction: Vec::new(),
    directional_color: Vec::new(),
};

/// The vertex inputs of a model material's program, by the attribute names its shader declares.
pub(super) fn mesh_inputs(program: &Program) -> Vec<gpu::MeshInput> {
    program
        .attributes
        .iter()
        .map(|(name, location)| {
            let (format, offset, constant) = match model::attribute(name) {
                Some((format, offset)) => (format, offset, false),
                None => {
                    let (format, offset) = model::constant_attribute(name);
                    (format, offset, true)
                }
            };
            gpu::MeshInput {
                location: *location,
                format,
                offset,
                constant,
            }
        })
        .collect()
}

/// The inverse of an affine matrix (column-major).
pub(super) fn inverse(m: &Mat4) -> Mat4 {
    // A column-major array read as rows is the transpose, whose inverse is the transposed
    // inverse: the same reading of the result gives the inverse back.
    flatten(mat::invert(&rows(m)))
}

fn rows(m: &Mat4) -> mat::M4 {
    std::array::from_fn(|r| std::array::from_fn(|c| m[r * 4 + c]))
}

fn flatten(m: mat::M4) -> Mat4 {
    std::array::from_fn(|i| m[i / 4][i % 4])
}

/// The matrix normals go through: the inverse transpose of the world matrix's rotation and scale.
fn normal_matrix(world: &Mat4) -> Mat4 {
    let inv = inverse(world);
    let mut out = IDENTITY;
    for c in 0..3 {
        for r in 0..3 {
            out[c * 4 + r] = inv[r * 4 + c];
        }
    }
    out
}

impl Engine {
    /// Whether the scene is seen through a perspective camera.
    pub(super) fn perspective(&self) -> bool {
        self.scene.camera.perspective
    }

    /// Packs the scene's lights and ambient colours. They are fixed until a property changes, and
    /// a model material's program depends on how many lights of each kind there are.
    pub(super) fn pack_lights(&mut self) {
        let color = |b: &Bound| {
            let f = floats(&b.get(&self.props));
            [0, 1, 2].map(|i| f.get(i).copied().unwrap_or(0.0))
        };
        self.models.ambient = color(&self.scene.ambient);
        self.models.skylight = color(&self.scene.skylight);
        let lights = Lights::pack(&self.scene.lights, &self.props, |s| self.light_world(s));
        self.models.lights = lights;
    }

    /// Loads the visible model layers: meshes (kept across rebuilds), material draw items and
    /// placement.
    pub(super) fn build_models(&mut self) {
        let mut items = Vec::new();
        for index in 0..self.scene.layers.len() {
            let Some(path) = self.scene.layers[index].model.clone() else {
                continue;
            };
            if !self.visible(index) {
                continue;
            }
            match self.model_gpu(index, &path) {
                Ok(model) => items.push(model),
                Err(e) => self.warnings.push(format!(
                    "model {}: {e}; not drawn",
                    self.scene.layers[index].name
                )),
            }
        }
        self.models.items = items;
        self.models.meshes.retain(|_, m| Rc::strong_count(m) > 1);
        // A run ends at a 2D layer that draws; hidden layers and groups do not split it.
        let mut runs: Vec<Run> = Vec::new();
        let mut in_run = false;
        for i in 0..self.scene.layers.len() {
            if let Some(m) = self.model_at(i) {
                if !in_run {
                    runs.push(Run {
                        first_layer: i,
                        opaque: Vec::new(),
                        blended: Vec::new(),
                    });
                }
                in_run = true;
                let run = runs.last_mut().expect("a run was just started");
                for (p, part) in self.models.items[m].parts.iter().enumerate() {
                    if part.opaque {
                        &mut run.opaque
                    } else {
                        &mut run.blended
                    }
                    .push((m, p));
                }
            } else if self.layer_draws(i) {
                in_run = false;
            }
        }
        if runs.is_empty() {
            self.models.depth = None;
        }
        self.models.runs = runs;
    }

    fn model_gpu(&mut self, index: usize, path: &str) -> Result<ModelGpu, Error> {
        let mesh = match self.models.meshes.get(path) {
            Some(m) => m.clone(),
            None => {
                let data = self
                    .vfs
                    .read(path)
                    .ok_or_else(|| Error::Missing(path.to_string()))?;
                let mesh = Rc::new(model::Buffers::upload(
                    &self.gpu.device,
                    model::parse(&data)?,
                )?);
                let _ = self.models.meshes.insert(path.to_string(), mesh.clone());
                mesh
            }
        };
        let mut parts = Vec::new();
        for submesh in &mesh.submeshes {
            let built = Material::load_blended(&self.vfs, &submesh.material, Blend::Normal)
                .and_then(|material| {
                    let item = self.draw_item(
                        &material,
                        material.blend,
                        TARGET_FORMAT,
                        self.samples,
                        &[],
                        false,
                        true,
                    )?;
                    let depth = self
                        .gpu
                        .depth_state(material.depth_test, material.depth_write)?;
                    Ok(Part {
                        item,
                        depth,
                        cull: material.cull,
                        opaque: matches!(material.blend, Blend::Normal | Blend::Disabled),
                        submesh: submesh.clone(),
                    })
                });
            match built {
                Ok(part) => parts.push(part),
                Err(e) => self.warnings.push(format!(
                    "model {}: {}: {e}; part not drawn",
                    self.scene.layers[index].name, submesh.material
                )),
            }
        }
        let layer = &self.scene.layers[index];
        let mut color = [1.0f32; 3];
        for (o, v) in color.iter_mut().zip(floats(&layer.color.get(&self.props))) {
            *o = v * layer.brightness;
        }
        let world = self.world3d(index, 0);
        Ok(ModelGpu {
            layer: index,
            mesh,
            parts,
            world,
            normal: normal_matrix(&world),
            color,
            alpha: floats(&layer.alpha.get(&self.props))
                .first()
                .copied()
                .unwrap_or(1.0),
        })
    }

    /// Translation, rotation (radians; about x first, then y, then z) and scale of an object, as
    /// a column-major matrix.
    fn local3d(&self, origin: &Bound, angles: &Bound, scale: &Bound) -> Mat4 {
        let v = |b: &Bound, d: f32| {
            let f = floats(&b.get(&self.props));
            [0, 1, 2].map(|i| f.get(i).copied().unwrap_or(d))
        };
        // `from_trs` is row-vector style; its rows laid end to end are this column-major matrix.
        flatten(mat::from_trs(v(origin, 0.0), v(angles, 0.0), v(scale, 1.0)))
    }

    /// A layer's world matrix in the scene's own space (y up), through its parents.
    pub(super) fn world3d(&self, index: usize, depth: u32) -> Mat4 {
        let layer = &self.scene.layers[index];
        let local = self.local3d(&layer.origin, &layer.angles, &layer.scale);
        mul(&self.parent_world3d(layer.parent, depth), &local)
    }

    fn parent_world3d(&self, parent: Option<i64>, depth: u32) -> Mat4 {
        match parent.and_then(|p| self.scene.layers.iter().position(|l| l.id == p)) {
            Some(p) if depth < 32 => self.world3d(p, depth + 1),
            _ => IDENTITY,
        }
    }

    fn light_world(&self, light: &LightSpec) -> Mat4 {
        let local = self.local3d(&light.origin, &light.angles, &light.scale);
        mul(&self.parent_world3d(light.parent, 0), &local)
    }

    /// Where a light is this frame: its world position, moved with its tree by camera parallax.
    fn light_position(&self, light: &LightSpec) -> [f32; 3] {
        let m = self.light_world(light);
        let mut root = None;
        let mut parent = light.parent;
        for _ in 0..32 {
            let Some(i) = parent.and_then(|p| self.scene.layers.iter().position(|l| l.id == p)) else {
                break;
            };
            root = Some(i);
            parent = self.scene.layers[i].parent;
        }
        let (origin, depth) = match root {
            Some(i) => (&self.scene.layers[i].origin, &self.scene.layers[i].parallax_depth),
            None => (&light.origin, &light.parallax_depth),
        };
        let o = floats(&origin.at(&self.props, self.time));
        let o = [o.first().copied().unwrap_or(0.0), o.get(1).copied().unwrap_or(0.0)];
        let [dx, dy] = self.parallax_shift(o, depth);
        [m[12] + dx, m[13] + dy, m[14]]
    }

    /// The world-space point on the camera's axis at normalised depth `z` (0 near, 1 far), through
    /// the inverse view-projection `inv`.
    fn unproject_axis(inv: &Mat4, z: f32) -> [f32; 3] {
        let v: [f32; 4] = std::array::from_fn(|r| inv[8 + r] * z + inv[12 + r]);
        [v[0] / v[3], v[1] / v[3], v[2] / v[3]]
    }

    /// This frame's volumetric point lights, each with the index of the layer it is added before
    /// (the layer count: after every layer), in that order; and the inverse view-projection the
    /// haze pass casts its rays through.
    pub(super) fn hazes(&self) -> (Vec<(usize, Haze)>, Mat4) {
        let props = &self.props;
        let lights: Vec<&LightSpec> = self
            .scene
            .lights
            .iter()
            .filter(|l| l.kind == Kind::Point && l.volumetrics.truthy(props) && l.visible.truthy(props))
            .collect();
        if lights.is_empty() {
            return (Vec::new(), IDENTITY);
        }
        let inv = inverse(&self.models.view.view_projection);
        // The engine's test of whether the eye is inside a light: a fifth of a unit forward.
        let (near, far) = (Self::unproject_axis(&inv, 0.0), Self::unproject_axis(&inv, 1.0));
        let axis: [f32; 3] = std::array::from_fn(|i| far[i] - near[i]);
        let len = axis.iter().map(|v| v * v).sum::<f32>().sqrt().max(1e-6);
        let eye = self.models.view.eye;
        let probe: [f32; 3] = std::array::from_fn(|i| eye[i] + 0.2 * axis[i] / len);
        let mut out: Vec<(usize, Haze)> = Vec::with_capacity(lights.len());
        for light in lights {
            let num = |b: &Bound, d: f32| floats(&b.get(props)).first().copied().unwrap_or(d);
            let rgb = floats(&light.color.get(props));
            let center = self.light_position(light);
            let radius = num(&light.radius, 1.0);
            let inside = (0..3).map(|i| (probe[i] - center[i]).powi(2)).sum::<f32>();
            let place = light
                .before
                .and_then(|id| self.scene.layers.iter().position(|l| l.id == id))
                .unwrap_or(self.scene.layers.len());
            out.push((
                place,
                Haze {
                    center,
                    radius,
                    color: [0, 1, 2].map(|i| rgb.get(i).copied().unwrap_or(0.0)),
                    intensity: num(&light.intensity, 0.0),
                    density: num(&light.density, 2.0),
                    exponent: num(&light.volumetrics_exponent, 1.0),
                    shadow: light.shadow.truthy(props),
                    fullscreen: inside < radius * radius,
                },
            ));
        }
        out.sort_by_key(|(place, _)| *place);
        (out, inv)
    }

    /// The model drawn for scene layer `layer`, if it is one.
    pub(super) fn model_at(&self, layer: usize) -> Option<usize> {
        self.models.items.iter().position(|m| m.layer == layer)
    }

    /// The run that draws when the layer order reaches `layer`.
    pub(super) fn run_at(&self, layer: usize) -> Option<usize> {
        self.models.runs.iter().position(|r| r.first_layer == layer)
    }

    /// Whether a non-model layer draws anything (a particle system or a placed image).
    pub(super) fn layer_draws(&self, layer: usize) -> bool {
        self.particles.iter().any(|p| p.layer == layer)
            || self.layers.get(layer).is_some_and(|l| {
                l.shown && l.placed.is_some() && (l.base.is_some() || l.image.is_some())
            })
    }

    /// Sets this frame's camera. `view` is the visible part of the design in the 2D renderer's
    /// terms (left, right, top, bottom), which an orthographic scene's models are drawn through.
    pub(super) fn update_view(&mut self, time: f32, target: [f32; 2], view: [f32; 4]) {
        let camera = &self.scene.camera;
        self.models.view = if camera.perspective {
            let pose = camera.pose_at(time);
            let shake = self
                .scene
                .shake
                .now(&self.props)
                .map_or([0.0; 3], |s| camera::shake(s, time));
            let eye = [0, 1, 2].map(|i| pose.eye[i] + shake[i]);
            let center = [0, 1, 2].map(|i| pose.center[i] + shake[i]);
            let aspect = target[0] / target[1].max(1.0);
            let projection = camera::perspective(
                camera.fov,
                aspect,
                camera.near,
                camera.far,
                self.framing.flip,
            );
            View {
                view_projection: mul(&projection, &camera::look_at(eye, center, pose.up)),
                eye,
                mirrored: self.framing.flip,
            }
        } else {
            let (w, h) = (self.scene.width, self.scene.height);
            View {
                view_projection: camera::orthographic(view, h),
                eye: [w / 2.0, h / 2.0, 2000.0],
                // A flipped view has its left and right swapped.
                mirrored: view[1] < view[0],
            }
        };
        // Farthest first; the sort is stable, so equal distances keep the layer order.
        let eye = self.models.view.eye;
        let items = &self.models.items;
        let distance = |&(m, _): &(usize, usize)| {
            let w = &items[m].world;
            (w[12] - eye[0]).powi(2) + (w[13] - eye[1]).powi(2) + (w[14] - eye[2]).powi(2)
        };
        for run in &mut self.models.runs {
            run.blended
                .sort_by(|a, b| distance(b).total_cmp(&distance(a)));
        }
        if !self.models.runs.is_empty() {
            self.ensure_depth(target);
        }
    }

    fn ensure_depth(&mut self, target: [f32; 2]) {
        let (w, h) = (target[0] as usize, target[1] as usize);
        let fits = self.models.depth.as_ref().is_some_and(|d| {
            d.width() == w.max(1) && d.height() == h.max(1) && d.sampleCount() == self.samples
        });
        if fits {
            return;
        }
        self.models.depth =
            match self
                .gpu
                .depth_target(w, h, self.samples, self.models.runs.len() == 1)
            {
                Ok(d) => Some(d),
                Err(e) => {
                    self.warnings.push(format!("models: {e}"));
                    None
                }
            };
    }

    /// Begins a model pass on the scene target: the frame's clear colour when nothing has drawn
    /// yet, the depth buffer cleared on the frame's first model pass.
    pub(super) fn begin_model_pass(
        &self,
        cb: &gpu::CommandBuffer,
        target: &Texture,
        msaa: Option<&Texture>,
        clear: Option<[f64; 4]>,
        first: bool,
    ) -> Result<Retained<gpu::Encoder>, Error> {
        let depth = self
            .models
            .depth
            .as_ref()
            .ok_or_else(|| Error::Metal("no depth buffer".into()))?;
        gpu::begin_depth(
            cb,
            target,
            msaa,
            clear,
            depth,
            first,
            self.models.runs.len() > 1,
        )
    }

    /// Draws a run of models: each part with its material, culling and depth state.
    pub(super) fn draw_run(
        &self,
        enc: &gpu::Encoder,
        run: usize,
        input: FrameInput,
        screen: [f32; 2],
        named: &HashMap<String, Retained<Texture>>,
    ) {
        enc.setFrontFacingWinding(if self.models.view.mirrored {
            MTLWinding::Clockwise
        } else {
            MTLWinding::CounterClockwise
        });
        let run = &self.models.runs[run];
        let vp = self.models.view.view_projection;
        for &(mi, pi) in run.opaque.iter().chain(&run.blended) {
            let m = &self.models.items[mi];
            let part = &m.parts[pi];
            let mvp = mul(&vp, &m.world);
            let ctx = DrawCtx {
                mvp,
                model: m.world,
                view_projection: vp,
                target: screen,
                color: m.color,
                alpha: m.alpha,
                buffer_scale: [1.0, 1.0],
                fbo_scale: [1.0, 1.0],
                screen_mvp: mvp,
                size: [1.0, 1.0],
                normal_model: m.normal,
                lit: true,
            };
            enc.setDepthStencilState(Some(&part.depth));
            enc.setCullMode(match part.cull {
                Cull::Back => MTLCullMode::Back,
                Cull::Front => MTLCullMode::Front,
                Cull::None => MTLCullMode::None,
            });
            let _ = self.bind(enc, &part.item, &ctx, input, None, named, None, None);
            gpu::set_bytes(
                enc,
                true,
                &model::CONSTANT_ATTRIBUTES,
                gpu::CONSTANT_BUFFER_SLOT,
            );
            let s = &part.submesh;
            // SAFETY: the buffers hold the submesh's vertices and indices (checked when parsed);
            // the offsets are multiples of four bytes; the buffers outlive the frame.
            unsafe {
                enc.setVertexBuffer_offset_atIndex(
                    Some(&m.mesh.vertices),
                    s.first_vertex * model::VERTEX_STRIDE,
                    shader::VERTEX_BUFFER_SLOT as usize,
                );
                enc.drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset(
                    MTLPrimitiveType::Triangle,
                    s.index_count,
                    MTLIndexType::UInt16,
                    &m.mesh.indices,
                    s.first_index * 2,
                );
            }
        }
    }

    /// The value of a 3D engine uniform for a draw. Image layers are not lit by the scene's
    /// lights (`DrawCtx::lit`); they keep to the ambient colours.
    pub(super) fn view_uniform<'a>(&'a self, which: ViewUniform, ctx: &'a DrawCtx) -> &'a [f32] {
        let lights = if ctx.lit { &self.models.lights } else { &UNLIT };
        match which {
            ViewUniform::Eye => &self.models.view.eye,
            ViewUniform::NormalModel => &ctx.normal_model,
            ViewUniform::Ambient => &self.models.ambient,
            ViewUniform::Skylight => &self.models.skylight,
            ViewUniform::LegacyPosition => &lights.legacy_position,
            ViewUniform::LegacyColorRadius => &lights.legacy_color_radius,
            ViewUniform::PointOrigin => &lights.point_origin,
            ViewUniform::PointColor => &lights.point_color,
            ViewUniform::SpotOrigin => &lights.spot_origin,
            ViewUniform::SpotDirection => &lights.spot_direction,
            ViewUniform::SpotColor => &lights.spot_color,
            ViewUniform::SpotExponent => &lights.spot_exponent,
            ViewUniform::TubeOriginA => &lights.tube_origin_a,
            ViewUniform::TubeOriginB => &lights.tube_origin_b,
            ViewUniform::TubeColor => &lights.tube_color,
            ViewUniform::DirectionalDirection => &lights.directional_direction,
            ViewUniform::DirectionalColor => &lights.directional_color,
        }
    }

    /// The combos sizing a model material's light arrays.
    pub(super) fn light_combos(&self) -> impl Iterator<Item = (&'static str, i64)> + '_ {
        self.models.lights.combos()
    }

    /// The view-projection a particle layer draws with in a perspective scene. Particles are
    /// simulated and placed in their layer's plane (see `world`), so the layer's depth along z is
    /// added here.
    pub(super) fn particle_view_projection(&self, layer_world: &Mat4) -> Mat4 {
        mul(
            &self.models.view.view_projection,
            &super::translate(0.0, 0.0, layer_world[14]),
        )
    }

    /// The 2D world matrix of a layer in a perspective scene: its 3D placement, with the y flip
    /// the 2D renderer's quads and particles (y down) need.
    pub(super) fn perspective_world(&self, index: usize) -> Mat4 {
        mul(&self.world3d(index, 0), &scale(1.0, -1.0, 1.0))
    }

    /// Whether the 3D content changes between frames: a moving or shaking perspective camera, or
    /// a model material with time-driven uniforms.
    pub(super) fn models_animated(&self) -> bool {
        let camera = &self.scene.camera;
        (camera.perspective && (camera.moves() || self.scene.shake.now(&self.props).is_some()))
            || self
                .models
                .items
                .iter()
                .flat_map(|m| &m.parts)
                .any(|p| p.item.dynamic.iter().any(|(_, _, d)| d.moves()))
    }

    /// Frees the depth buffer; the next frame makes a new one.
    pub(super) fn trim_models(&mut self) {
        self.models.depth = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_inverse_undoes_an_affine_matrix() {
        let m = flatten(mat::from_trs(
            [1.0, -2.0, 3.0],
            [0.3, -0.7, 1.1],
            [2.0, 0.5, 1.5],
        ));
        let p = mul(&m, &inverse(&m));
        assert!(
            p.iter().zip(IDENTITY).all(|(a, b)| (a - b).abs() < 1e-5),
            "{p:?}"
        );
    }

    #[test]
    fn normals_stay_perpendicular_under_non_uniform_scale() {
        // Scaled 4x along x: a surface tilted 45 degrees has its normal pushed towards x less.
        let m = flatten(mat::from_trs([0.0; 3], [0.0; 3], [4.0, 1.0, 1.0]));
        let n = normal_matrix(&m);
        let normal = [n[0] + n[4], n[1] + n[5]];
        let tangent = [m[0] - m[4], m[1] - m[5]];
        assert!((normal[0] * tangent[0] + normal[1] * tangent[1]).abs() < 1e-5);
    }
}
