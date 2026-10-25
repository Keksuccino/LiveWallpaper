//! Vertex data and shader inputs for the engine's particle shaders, drawn without their
//! geometry stage: four vertices per quad built here, two triangles each through an index
//! buffer (corners 0-1-2 and 0-2-3).
//!
//! `genericparticle` (sprites and sprite trails) takes one vertex per corner with the particle's
//! centre, size, rotation and colour, and builds the corner itself. `genericropeparticle` (ropes
//! and rope trails) takes each strip segment's ends, their neighbours (for the curve's tangents)
//! and the texture position along the strip.

use super::model::{Definition, Renderer, RendererKind};
use super::sim::{Instance, Node};
use super::{Affine, Vec3};

/// One shader attribute: name, float count, byte offset.
pub type Attribute = (&'static str, usize, usize);

/// How a vertex is laid out in the buffer.
#[derive(Debug)]
pub struct VertexLayout {
    pub stride: usize,
    pub attributes: &'static [Attribute],
}

/// Sprites without a sprite sheet: position, (corner, rotation z, size), rotation xy, colour.
static SPRITE: VertexLayout = VertexLayout {
    stride: 52,
    attributes: &[
        ("a_Position", 3, 0),
        ("a_TexCoordVec4", 4, 12),
        ("a_TexCoordC2", 2, 28),
        ("a_Color", 4, 36),
    ],
};

/// Sprites with velocity and sheet frame (`THICKFORMAT`): sheets and sprite trails.
static SPRITE_THICK: VertexLayout = VertexLayout {
    stride: 68,
    attributes: &[
        ("a_Position", 3, 0),
        ("a_TexCoordVec4", 4, 12),
        ("a_TexCoordVec4C1", 4, 28),
        ("a_TexCoordC2", 2, 44),
        ("a_Color", 4, 52),
    ],
};

/// Rope segments: start and size, end and strip length, previous point and strip position,
/// next point and end size, end colour, corner, start colour.
static ROPE: VertexLayout = VertexLayout {
    stride: 104,
    attributes: &[
        ("a_PositionVec4", 4, 0),
        ("a_TexCoordVec4", 4, 16),
        ("a_TexCoordVec4C1", 4, 32),
        ("a_TexCoordVec4C2", 4, 48),
        ("a_TexCoordVec4C3", 4, 64),
        ("a_TexCoordC4", 2, 80),
        ("a_Color", 4, 88),
    ],
};

/// Trail segments: start and size, end and length/index, previous point and position, next
/// point, corner, colour.
static ROPE_TRAIL: VertexLayout = VertexLayout {
    stride: 84,
    attributes: &[
        ("a_PositionVec4", 4, 0),
        ("a_TexCoordVec4", 4, 16),
        ("a_TexCoordVec4C1", 4, 32),
        ("a_TexCoordVec3C2", 3, 48),
        ("a_TexCoordC3", 2, 60),
        ("a_Color", 4, 68),
    ],
};

/// The quad corners, in the order the index buffer expects.
const CORNERS: [(f32, f32); 4] = [(0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0)];

/// The vertex format a renderer draws with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Layout {
    Sprite,
    SpriteThick,
    Rope,
    RopeTrail,
}

impl Layout {
    /// Sprites carry velocity and frame when the system has a trail renderer or a sheet.
    pub fn for_renderer(def: &Definition, renderer: &Renderer, sheet: bool) -> Self {
        let trails = def
            .renderers
            .iter()
            .any(|r| matches!(r.kind, RendererKind::SpriteTrail { .. }));
        match renderer.kind {
            RendererKind::Sprite if trails || sheet => Self::SpriteThick,
            RendererKind::Sprite => Self::Sprite,
            RendererKind::SpriteTrail { .. } => Self::SpriteThick,
            RendererKind::Rope { .. } => Self::Rope,
            RendererKind::RopeTrail { .. } => Self::RopeTrail,
        }
    }

    pub fn vertex(self) -> &'static VertexLayout {
        match self {
            Self::Sprite => &SPRITE,
            Self::SpriteThick => &SPRITE_THICK,
            Self::Rope => &ROPE,
            Self::RopeTrail => &ROPE_TRAIL,
        }
    }

    pub fn floats(self) -> usize {
        self.vertex().stride / 4
    }

    /// Quads the renderer may need for a system of `max_count` particles.
    pub fn max_quads(self, renderer: &Renderer, max_count: usize) -> usize {
        match renderer.kind {
            RendererKind::Rope { subdivision } => {
                max_count.saturating_sub(1) * (subdivision as usize + 1)
            }
            RendererKind::RopeTrail { segments, .. } => max_count * segments as usize,
            _ => max_count,
        }
    }
}

/// The sprite sheet of the material's texture, as the shaders need it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SheetInfo {
    /// One frame's size in texture coordinates.
    pub frame: [f32; 2],
    pub count: f32,
    /// A frame's height over its width, in pixels.
    pub aspect: f32,
}

/// The particle-specific uniforms of the particle shaders.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShaderInput {
    OrientationUp,
    OrientationRight,
    OrientationForward,
    ViewUp,
    ViewRight,
    EyePosition,
    RenderVar0,
    RenderVar1,
}

impl ShaderInput {
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "g_OrientationUp" => Self::OrientationUp,
            "g_OrientationRight" => Self::OrientationRight,
            "g_OrientationForward" => Self::OrientationForward,
            "g_ViewUp" => Self::ViewUp,
            "g_ViewRight" => Self::ViewRight,
            "g_EyePosition" => Self::EyePosition,
            "g_RenderVar0" => Self::RenderVar0,
            "g_RenderVar1" => Self::RenderVar1,
            _ => return None,
        })
    }
}

/// Values for the `ShaderInput`s of one draw.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShaderValues {
    /// Right, up, forward of a sprite, in the system's space.
    pub orientation: [Vec3; 3],
    pub view_up: Vec3,
    pub view_right: Vec3,
    /// The camera, in the space of the draw's model matrix.
    pub eye: Vec3,
    pub render_var0: [f32; 4],
    pub render_var1: [f32; 4],
}

impl ShaderValues {
    pub fn get(&self, input: ShaderInput) -> [f32; 4] {
        let v3 = |v: Vec3| [v.x, v.y, v.z, 0.0];
        match input {
            ShaderInput::OrientationRight => v3(self.orientation[0]),
            ShaderInput::OrientationUp => v3(self.orientation[1]),
            ShaderInput::OrientationForward => v3(self.orientation[2]),
            ShaderInput::ViewUp => v3(self.view_up),
            ShaderInput::ViewRight => v3(self.view_right),
            ShaderInput::EyePosition => v3(self.eye),
            ShaderInput::RenderVar0 => self.render_var0,
            ShaderInput::RenderVar1 => self.render_var1,
        }
    }
}

/// A sprite's right, up and forward axes in the system's space. `model` maps the system's space
/// into the scene (y up), whose camera looks down -z with y up.
pub fn orientation(model: &Affine, renderer: &Renderer) -> [Vec3; 3] {
    let view_forward = -Vec3::Z;
    let view_up = Vec3::Y;
    let screen_flag = renderer.flags & 1 != 0;
    let (forward, up) = match renderer.orientation {
        // Facing the camera; up is the layer's up, or the screen's with the flag.
        0 => {
            let a = -view_forward;
            let c = if screen_flag { view_up } else { model.cols[1] };
            (a, c - a * a.dot(c))
        }
        // Upright around the axis, turned towards the camera.
        1 => {
            let c = if screen_flag {
                Vec3::Y
            } else {
                model.vector(renderer.axis)
            };
            let b = view_forward.cross(c);
            (b.cross(c), c)
        }
        // Fixed to the axis and forward vector.
        _ => {
            if screen_flag {
                (renderer.axis, renderer.forward)
            } else {
                (model.vector(renderer.axis), model.vector(renderer.forward))
            }
        }
    };
    // Into the system's space: project onto the layer's axes.
    let [x, y, z] = model.cols;
    let local = |v: Vec3| Vec3::new(v.dot(x), v.dot(y), v.dot(z));
    let (a, c) = (local(forward), local(up));
    [
        c.cross(a).normalized_or(Vec3::X),
        c.normalized_or(Vec3::Y),
        a.normalized_or(Vec3::Z),
    ]
}

/// `g_RenderVar0` for a renderer: trail lengths, or the rope's strip parameters.
pub fn render_var0(def: &Definition, renderer: &Renderer, inst: &Instance) -> [f32; 4] {
    match renderer.kind {
        RendererKind::SpriteTrail {
            length,
            max_length,
            min_length,
        } => [length, max_length, min_length, 0.0],
        RendererKind::Rope { .. } => [0.0, 0.0, 0.0, inst.alive as f32],
        RendererKind::RopeTrail { segments, .. } => {
            let s = segments as f32;
            if def.trail_scrolling {
                [s - 1.0, 0.0, inst.trail_phase(), (s - 1.0) * def.uv_scale]
            } else {
                [0.0, 0.0, inst.trail_phase(), s - 0.5]
            }
        }
        RendererKind::Sprite => [0.0; 4],
    }
}

/// One instance's vertices for one renderer, appended to a frame's buffer.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InstanceDraw {
    /// First float in the buffer.
    pub start: usize,
    pub quads: usize,
}

/// Appends `inst`'s quads for `renderer` to `out`.
pub fn build(
    nodes: &[Node],
    inst: &Instance,
    renderer: &Renderer,
    layout: Layout,
    out: &mut Vec<f32>,
) -> InstanceDraw {
    let start = out.len();
    let def = &nodes[inst.node].def;
    let quads = match layout {
        Layout::Sprite | Layout::SpriteThick => sprites(inst, layout == Layout::SpriteThick, out),
        Layout::Rope => match renderer.kind {
            RendererKind::Rope { subdivision } => rope(def, inst, subdivision, out),
            _ => 0,
        },
        Layout::RopeTrail => rope_trail(def, inst, out),
    };
    InstanceDraw { start, quads }
}

fn sprites(inst: &Instance, thick: bool, out: &mut Vec<f32>) -> usize {
    out.reserve(inst.alive * 4 * if thick { 17 } else { 13 });
    let mut quads = 0;
    for p in inst.particles.iter().filter(|p| p.alive()) {
        let (pos, rot, vel, c) = (p.position, p.rotation, p.velocity, p.color);
        for (cx, cy) in CORNERS {
            out.extend_from_slice(&[pos.x, pos.y, pos.z, cx, cy, rot.z, p.size]);
            if thick {
                out.extend_from_slice(&[vel.x, vel.y, vel.z, p.frame]);
            }
            out.extend_from_slice(&[rot.x, rot.y, c.x, c.y, c.z, p.alpha]);
        }
        quads += 1;
    }
    quads
}

/// The rope: one strip through all live particles in spawn order. Each segment is split into
/// `subdivision + 1` pieces along the curve through its neighbours, so the shader (which draws
/// straight pieces) shows the same curve as the engine's geometry stage.
fn rope(def: &Definition, inst: &Instance, subdivision: u32, out: &mut Vec<f32>) -> usize {
    let n = inst.rope.len();
    if n < 2 {
        return 0;
    }
    let p = |i: usize| &inst.particles[inst.rope[i] as usize];
    // How far along the texture the strip runs: the particles the emitter keeps alive, or the
    // ones there are, and where the oldest one starts.
    let rate = def.emitters.first().map_or(0.0, |e| e.rate);
    let life = def.mean_lifetime();
    let rate = if rate * life > n as f32 {
        rate.min(60.0)
    } else {
        rate
    };
    let expected = rate * life;
    let (length, offset) = if def.rope_scrolling {
        ((expected - 1.0) * def.uv_scale, inst.removed as f32)
    } else if def.rope_smoothing && expected > 0.0 && n as f32 >= expected - 1.0 {
        let oldest = p(0);
        (
            (expected - 1.0) * def.uv_scale,
            ((life - oldest.age) * rate).clamp(0.0, 1.0) - 1.0,
        )
    } else {
        (n as f32 * def.uv_scale, 0.0)
    };
    let pieces = subdivision as usize + 1;
    out.reserve((n - 1) * pieces * 4 * 26);
    let mut quads = 0;
    for s in 0..n - 1 {
        let (a, b) = (p(s), p(s + 1));
        let prev = if s > 0 { p(s - 1).position } else { a.position };
        let next = if s + 2 < n {
            p(s + 2).position
        } else {
            b.position
        };
        let position = if n == 2 { 0.0 } else { s as f32 + offset };
        // The curve: a cubic through both ends with tangents from the neighbours.
        let (t0, t1) = (b.position - prev, next - a.position);
        let (c0, c1) = (a.position + t0 * 0.15, b.position - t1 * 0.15);
        let color = |q: &super::sim::Particle| [q.color.x, q.color.y, q.color.z, q.alpha];
        let (ca, cb) = (color(a), color(b));
        for k in 0..pieces {
            let s0 = smooth(k as f32 / pieces as f32);
            let s1 = smooth((k + 1) as f32 / pieces as f32);
            let start = bezier(a.position, c0, c1, b.position, s0);
            let end = bezier(a.position, c0, c1, b.position, s1);
            // Neighbours that make the shader's tangents the interpolated ones.
            let piece_prev = end - t0.lerp(t1, s0);
            let piece_next = start + t0.lerp(t1, s1);
            let size0 = a.size + (b.size - a.size) * s0;
            let size1 = a.size + (b.size - a.size) * s1;
            let mix = |x: [f32; 4], y: [f32; 4], t: f32| {
                std::array::from_fn::<f32, 4, _>(|i| x[i] + (y[i] - x[i]) * t)
            };
            let (col0, col1) = (mix(ca, cb, s0), mix(ca, cb, s1));
            // The texture coordinate runs over this piece only: stretch the strip so one
            // segment of it is this piece.
            let span = (s1 - s0).max(1.0e-4);
            let piece_length = (length - 1.0) / span + 1.0;
            let piece_position = (position + s0) / span;
            for (cx, cy) in CORNERS {
                out.extend_from_slice(&[start.x, start.y, start.z, size0]);
                out.extend_from_slice(&[end.x, end.y, end.z, piece_length]);
                out.extend_from_slice(&[piece_prev.x, piece_prev.y, piece_prev.z, piece_position]);
                out.extend_from_slice(&[piece_next.x, piece_next.y, piece_next.z, size1]);
                out.extend_from_slice(&col1);
                out.extend_from_slice(&[cx, cy]);
                out.extend_from_slice(&col0);
            }
            quads += 1;
        }
    }
    quads
}

/// Rope trails: per live particle, a strip from its position back through its recorded ones.
fn rope_trail(def: &Definition, inst: &Instance, out: &mut Vec<f32>) -> usize {
    let s = inst.trails.segments;
    if s == 0 {
        return 0;
    }
    out.reserve(inst.alive * s * 4 * 21);
    let mut quads = 0;
    for (slot, p) in inst.particles.iter().enumerate() {
        if !p.alive() {
            continue;
        }
        let Some((history, count, scroll)) = inst.trail_history(slot) else {
            continue;
        };
        let point = |k: usize| if k == 0 { p.position } else { history[k - 1] };
        for k in 0..s {
            let (start, end) = (point(k), point(k + 1));
            let prev = point(k.saturating_sub(1));
            let next = point((k + 2).min(s));
            let (wa, wb) = if def.trail_scrolling {
                (k as f32, k as f32 - scroll as f32)
            } else {
                (count as f32 * def.uv_scale, k as f32)
            };
            for (cx, cy) in CORNERS {
                out.extend_from_slice(&[start.x, start.y, start.z, p.size]);
                out.extend_from_slice(&[end.x, end.y, end.z, wa]);
                out.extend_from_slice(&[prev.x, prev.y, prev.z, wb]);
                out.extend_from_slice(&[next.x, next.y, next.z, cx, cy]);
                out.extend_from_slice(&[p.color.x, p.color.y, p.color.z, p.alpha]);
            }
            quads += 1;
        }
    }
    quads
}

fn smooth(t: f32) -> f32 {
    t * t * (3.0 - 2.0 * t)
}

fn bezier(a: Vec3, b: Vec3, c: Vec3, d: Vec3, t: f32) -> Vec3 {
    let u = 1.0 - t;
    a * (u * u * u) + b * (3.0 * t * u * u) + c * (3.0 * t * t * u) + d * (t * t * t)
}

/// Indices for `quads` quads of four vertices each.
pub fn quad_indices(quads: usize) -> Vec<u32> {
    (0..quads as u32)
        .flat_map(|q| {
            let v = q * 4;
            [v, v + 1, v + 2, v, v + 2, v + 3]
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::particles::{Definition, InstanceOverride, Simulation, Tree};

    fn running(json: &str) -> Simulation {
        let def = Definition::parse_str(json, true).expect("parses");
        let mut sim = Simulation::new(Tree::new(def, &mut |_| None), InstanceOverride::default(), 3);
        sim.advance_to(1.0);
        sim
    }

    #[test]
    fn every_layout_gets_its_floats_per_vertex() {
        let sim = running(
            r#"{"maxcount": 6,
                "emitter": [{"name": "sphererandom", "rate": 20, "speedmin": 50, "speedmax": 50}],
                "initializer": [{"name": "lifetimerandom", "min": 2, "max": 2}],
                "operator": [{"name": "movement"}],
                "renderer": [{"name": "sprite"}, {"name": "spritetrail"}, {"name": "rope", "subdivision": 2},
                             {"name": "ropetrail", "segments": 3}]}"#,
        );
        let nodes = sim.nodes();
        let inst = sim.root();
        let def = &nodes[0].def;
        assert_eq!(inst.alive, 6);
        for renderer in &def.renderers {
            let layout = Layout::for_renderer(def, renderer, false);
            let mut out = Vec::new();
            let built = build(nodes, inst, renderer, layout, &mut out);
            assert!(built.quads > 0 && built.quads <= layout.max_quads(renderer, def.max_count));
            assert_eq!(out.len(), built.quads * 4 * layout.floats(), "{:?}", renderer.kind);
            let v = layout.vertex();
            let last = v.attributes.iter().map(|a| a.2 + a.1 * 4).max().unwrap();
            assert_eq!(last, v.stride);
        }
        // A sprite system with a trail renderer draws its sprites with velocity too.
        assert_eq!(Layout::for_renderer(def, &def.renderers[0], false), Layout::SpriteThick);
    }

    #[test]
    fn sprites_face_the_screen_in_the_layers_axes() {
        let renderer = &Definition::parse_str("{}", true).unwrap().renderers[0];
        let [r, u, f] = orientation(&Affine::IDENTITY, renderer);
        assert_eq!((r, u, f), (Vec3::X, Vec3::Y, Vec3::Z));
        // A layer turned a quarter keeps its sprites upright in its own axes.
        let turned = Affine::rotation(Vec3::new(0.0, 0.0, std::f32::consts::FRAC_PI_2));
        let [r, u, _] = orientation(&turned, renderer);
        assert!((r - Vec3::X).length() < 1.0e-5 && (u - Vec3::Y).length() < 1.0e-5);
    }

    #[test]
    fn quads_index_two_triangles_each() {
        assert_eq!(quad_indices(2), vec![0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]);
    }
}
