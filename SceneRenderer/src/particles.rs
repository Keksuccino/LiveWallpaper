//! Particle systems: the particle-file model, a CPU simulation of it and the vertex data the
//! engine's particle shaders draw.
//!
//! The behaviour follows Wallpaper Engine's: defaults, the per-frame order of emission,
//! initializers and operators, the way instance overrides scale a system, event children, and
//! what the `genericparticle`/`genericropeparticle` shaders expect in each vertex. NOTES.md says
//! where each part was learned.
//!
//! Spaces: a system simulates in its own space, x right and y up, in scene units. The layer's
//! transform (`Affine`, also y up, origin at the scene's bottom-left) places it in the scene. A
//! world-space system (flag 1) simulates in scene space directly.

mod geometry;
mod model;
mod noise;
mod operators;
mod overrides;
mod sim;

pub use geometry::{
    build, orientation, quad_indices, render_var0, InstanceDraw, Layout, ShaderInput, ShaderValues,
    SheetInfo, VertexLayout,
};
pub use model::{Definition, Renderer, RendererKind};
pub use overrides::InstanceOverride;
pub use sim::{Instance, Node, Particle, Simulation, Tree};

/// Hard ceiling per system: `maxcount` is clamped to this so a malformed package cannot make the
/// simulation allocate without bound. The largest `maxcount` in the local scenes is 100000.
pub const MAX_PARTICLES_PER_SYSTEM: usize = 100_000;

/// Fixed simulation step. Real time is consumed in whole steps of this size, so the same seed and
/// the same total time give the same state (frozen frames and the golden harness rely on it).
pub const FIXED_DT: f32 = 1.0 / 60.0;

/// Control points per system; component indices are clamped into this range.
pub const CONTROL_POINTS: usize = 8;

const TAU: f32 = std::f32::consts::TAU;
const PI: f32 = std::f32::consts::PI;
const EPS: f32 = 1.0e-6;

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vec3 {
    pub const ZERO: Self = Self::new(0.0, 0.0, 0.0);
    pub const ONE: Self = Self::new(1.0, 1.0, 1.0);
    pub const X: Self = Self::new(1.0, 0.0, 0.0);
    pub const Y: Self = Self::new(0.0, 1.0, 0.0);
    pub const Z: Self = Self::new(0.0, 0.0, 1.0);

    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }

    pub const fn splat(v: f32) -> Self {
        Self::new(v, v, v)
    }

    pub fn dot(self, o: Self) -> f32 {
        self.x * o.x + self.y * o.y + self.z * o.z
    }

    pub fn cross(self, o: Self) -> Self {
        Self::new(
            self.y * o.z - self.z * o.y,
            self.z * o.x - self.x * o.z,
            self.x * o.y - self.y * o.x,
        )
    }

    pub fn length_squared(self) -> f32 {
        self.dot(self)
    }

    pub fn length(self) -> f32 {
        self.length_squared().sqrt()
    }

    /// The unit vector, or `fallback` for a (near) zero vector.
    pub fn normalized_or(self, fallback: Self) -> Self {
        let len = self.length();
        if len > EPS {
            self * (1.0 / len)
        } else {
            fallback
        }
    }

    pub fn lerp(self, o: Self, t: f32) -> Self {
        self + (o - self) * t
    }

    pub fn abs(self) -> Self {
        Self::new(self.x.abs(), self.y.abs(), self.z.abs())
    }

    pub fn map(self, f: impl Fn(f32) -> f32) -> Self {
        Self::new(f(self.x), f(self.y), f(self.z))
    }
}

impl std::ops::Add for Vec3 {
    type Output = Self;
    fn add(self, o: Self) -> Self {
        Self::new(self.x + o.x, self.y + o.y, self.z + o.z)
    }
}

impl std::ops::AddAssign for Vec3 {
    fn add_assign(&mut self, o: Self) {
        *self = *self + o;
    }
}

impl std::ops::Sub for Vec3 {
    type Output = Self;
    fn sub(self, o: Self) -> Self {
        Self::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }
}

impl std::ops::SubAssign for Vec3 {
    fn sub_assign(&mut self, o: Self) {
        *self = *self - o;
    }
}

impl std::ops::Mul<f32> for Vec3 {
    type Output = Self;
    fn mul(self, s: f32) -> Self {
        Self::new(self.x * s, self.y * s, self.z * s)
    }
}

impl std::ops::MulAssign<f32> for Vec3 {
    fn mul_assign(&mut self, s: f32) {
        *self = *self * s;
    }
}

impl std::ops::Mul for Vec3 {
    type Output = Self;
    fn mul(self, o: Self) -> Self {
        Self::new(self.x * o.x, self.y * o.y, self.z * o.z)
    }
}

impl std::ops::MulAssign for Vec3 {
    fn mul_assign(&mut self, o: Self) {
        *self = *self * o;
    }
}

impl std::ops::Neg for Vec3 {
    type Output = Self;
    fn neg(self) -> Self {
        Self::new(-self.x, -self.y, -self.z)
    }
}

/// An affine transform: a 3x3 linear part (columns) and a translation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Affine {
    pub cols: [Vec3; 3],
    pub translation: Vec3,
}

impl Default for Affine {
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl Affine {
    pub const IDENTITY: Self = Self {
        cols: [Vec3::X, Vec3::Y, Vec3::Z],
        translation: Vec3::ZERO,
    };

    pub fn translation(t: Vec3) -> Self {
        Self {
            translation: t,
            ..Self::IDENTITY
        }
    }

    /// Translation, then rotation `Rz * Ry * Rx` (radians), then scale: the order the particle
    /// files use for child offsets and control point angles.
    pub fn from_trs(origin: Vec3, angles: Vec3, scale: Vec3) -> Self {
        let rotation = Self::rotation(angles);
        Self {
            cols: [
                rotation.cols[0] * scale.x,
                rotation.cols[1] * scale.y,
                rotation.cols[2] * scale.z,
            ],
            translation: origin,
        }
    }

    /// `Rz * Ry * Rx` for the given angles in radians.
    pub fn rotation(angles: Vec3) -> Self {
        let (sx, cx) = angles.x.sin_cos();
        let (sy, cy) = angles.y.sin_cos();
        let (sz, cz) = angles.z.sin_cos();
        Self {
            cols: [
                Vec3::new(cz * cy, sz * cy, -sy),
                Vec3::new(cz * sy * sx - sz * cx, sz * sy * sx + cz * cx, cy * sx),
                Vec3::new(cz * sy * cx + sz * sx, sz * sy * cx - cz * sx, cy * cx),
            ],
            translation: Vec3::ZERO,
        }
    }

    /// From a column-major 4x4 matrix (the renderer's layout); the projective row is ignored.
    pub fn from_mat4(m: &[f32; 16]) -> Self {
        Self {
            cols: [
                Vec3::new(m[0], m[1], m[2]),
                Vec3::new(m[4], m[5], m[6]),
                Vec3::new(m[8], m[9], m[10]),
            ],
            translation: Vec3::new(m[12], m[13], m[14]),
        }
    }

    pub fn to_mat4(&self) -> [f32; 16] {
        let [a, b, c] = self.cols;
        let t = self.translation;
        [
            a.x, a.y, a.z, 0.0, b.x, b.y, b.z, 0.0, c.x, c.y, c.z, 0.0, t.x, t.y, t.z, 1.0,
        ]
    }

    pub fn vector(&self, v: Vec3) -> Vec3 {
        self.cols[0] * v.x + self.cols[1] * v.y + self.cols[2] * v.z
    }

    pub fn point(&self, p: Vec3) -> Vec3 {
        self.vector(p) + self.translation
    }

    /// `self * o`: `o` applies first.
    pub fn mul(&self, o: &Self) -> Self {
        Self {
            cols: [
                self.vector(o.cols[0]),
                self.vector(o.cols[1]),
                self.vector(o.cols[2]),
            ],
            translation: self.point(o.translation),
        }
    }

    /// The linear part's rows, i.e. the transpose's columns.
    pub fn rows(&self) -> [Vec3; 3] {
        let [a, b, c] = self.cols;
        [
            Vec3::new(a.x, b.x, c.x),
            Vec3::new(a.y, b.y, c.y),
            Vec3::new(a.z, b.z, c.z),
        ]
    }

    /// The inverse; a singular linear part gives the identity's.
    pub fn inverse(&self) -> Self {
        let [a, b, c] = self.cols;
        let r0 = b.cross(c);
        let r1 = c.cross(a);
        let r2 = a.cross(b);
        let det = a.dot(r0);
        if det.abs() < 1.0e-12 {
            return Self::translation(-self.translation);
        }
        let inv = 1.0 / det;
        // The rows of the inverse are the cross products; transpose them into columns.
        let linear = Self {
            cols: [
                Vec3::new(r0.x, r1.x, r2.x) * inv,
                Vec3::new(r0.y, r1.y, r2.y) * inv,
                Vec3::new(r0.z, r1.z, r2.z) * inv,
            ],
            translation: Vec3::ZERO,
        };
        Self {
            translation: -linear.vector(self.translation),
            ..linear
        }
    }

    /// The same linear part with the translation dropped.
    pub fn linear(&self) -> Self {
        Self {
            translation: Vec3::ZERO,
            ..*self
        }
    }
}

/// A uniform value between `min` and `min + span`.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Range {
    pub min: f32,
    pub span: f32,
}

impl Range {
    pub fn new(min: f32, max: f32) -> Self {
        Self {
            min,
            span: max - min,
        }
    }

    pub fn at(self, t: f32) -> f32 {
        self.min + self.span * t
    }

    pub fn scaled(self, s: f32) -> Self {
        Self {
            min: self.min * s,
            span: self.span * s,
        }
    }
}

/// Per-component ranges.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Range3 {
    pub min: Vec3,
    pub span: Vec3,
}

impl Range3 {
    pub fn new(min: Vec3, max: Vec3) -> Self {
        Self {
            min,
            span: max - min,
        }
    }

    pub fn at(self, t: Vec3) -> Vec3 {
        self.min + self.span * t
    }

    pub fn scaled(self, s: f32) -> Self {
        Self {
            min: self.min * s,
            span: self.span * s,
        }
    }
}

/// The xorshift generator the simulation draws from. Seeded per system, so a frozen frame is
/// reproducible (the engine itself seeds from the clock).
#[derive(Debug, Clone)]
pub(crate) struct Rng {
    state: u64,
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self {
            state: if seed == 0 {
                0x9E37_79B9_7F4A_7C15
            } else {
                seed
            },
        }
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Uniform in [0, 1).
    pub fn f32(&mut self) -> f32 {
        ((self.next_u64() >> 40) as f32) / ((1u32 << 24) as f32)
    }

    /// Uniform in [1e-5, 1): the engine draws angles and radii from this range so a zero never
    /// reaches a logarithm or a cube root's derivative.
    pub fn positive(&mut self) -> f32 {
        1.0e-5 + (1.0 - 1.0e-5) * self.f32()
    }

    /// Uniform index in `0..n` (`n > 0`).
    pub fn index(&mut self, n: usize) -> usize {
        ((self.f32() * n as f32) as usize).min(n.saturating_sub(1))
    }

    /// `rand^exponent`, the skewed draw the range initializers use.
    pub fn skewed(&mut self, exponent: f32) -> f32 {
        let t = self.f32();
        if exponent == 1.0 {
            t
        } else {
            t.powf(exponent)
        }
    }

    /// Independent skewed draws per component, drawn z, y, x like the engine.
    pub fn skewed3(&mut self, exponent: f32) -> Vec3 {
        let z = self.skewed(exponent);
        let y = self.skewed(exponent);
        let x = self.skewed(exponent);
        Vec3::new(x, y, z)
    }
}

pub(crate) fn hsv_to_rgb(hsv: Vec3) -> Vec3 {
    let (h, s, v) = (hsv.x.rem_euclid(1.0) * 6.0, hsv.y, hsv.z);
    let i = h.floor();
    let f = h - i;
    let p = v * (1.0 - s);
    let q = v * (1.0 - s * f);
    let t = v * (1.0 - s * (1.0 - f));
    match i as i32 % 6 {
        0 => Vec3::new(v, t, p),
        1 => Vec3::new(q, v, p),
        2 => Vec3::new(p, v, t),
        3 => Vec3::new(p, q, v),
        4 => Vec3::new(t, p, v),
        _ => Vec3::new(v, p, q),
    }
}

pub(crate) fn rgb_to_hsv(rgb: Vec3) -> Vec3 {
    let max = rgb.x.max(rgb.y).max(rgb.z);
    let min = rgb.x.min(rgb.y).min(rgb.z);
    let delta = max - min;
    if delta < 1.0e-5 || max <= 0.0 {
        return Vec3::new(0.0, 0.0, max);
    }
    let h = if rgb.x >= max {
        (rgb.y - rgb.z) / delta
    } else if rgb.y >= max {
        (rgb.z - rgb.x) / delta + 2.0
    } else {
        (rgb.x - rgb.y) / delta + 4.0
    };
    Vec3::new((h / 6.0).rem_euclid(1.0), delta / max, max)
}

fn smoothstep01(t: f32) -> f32 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// How strongly the audio drives a component: the loudest band of `bands` in the chosen channel,
/// mapped from `bounds` to 0..1, smoothed and raised to `exponent`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AudioResponse {
    /// 0 off, 1 left, 2 right, 3 both channels averaged.
    pub mode: u8,
    pub exponent: f32,
    pub bounds: [f32; 2],
    pub bands: [usize; 2],
}

impl AudioResponse {
    /// `spectrum` holds the left bands followed by as many right bands.
    pub fn factor(&self, spectrum: &[f32]) -> f32 {
        if self.mode == 0 {
            return 1.0;
        }
        let half = spectrum.len() / 2;
        let band = |i: usize| match self.mode {
            1 => spectrum.get(i).copied().unwrap_or(0.0),
            2 => spectrum.get(half + i).copied().unwrap_or(0.0),
            _ => {
                let l = spectrum.get(i).copied().unwrap_or(0.0);
                let r = spectrum.get(half + i).copied().unwrap_or(0.0);
                (l + r) * 0.5
            }
        };
        let loudest = (self.bands[0]..=self.bands[1])
            .map(band)
            .fold(0.0f32, f32::max);
        let span = self.bounds[1] - self.bounds[0];
        let t = if span.abs() > EPS {
            (loudest - self.bounds[0]) / span
        } else {
            0.0
        };
        smoothstep01(t).powf(self.exponent).clamp(0.0, 1.0)
    }
}
