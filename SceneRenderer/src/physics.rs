//! Bone physics of puppets, as Wallpaper Engine's puppet update runs it (see `NOTES.md`, "Bone
//! springs"): each bone with physics settings in its metadata turns and shifts behind the motion
//! of its tree, with a spring back to rest (`se`) or freely (`re`), pulled by gravity, with limits
//! and friction.
//!
//! The state of a bone is a turn speed (a quaternion, per sixtieth of a second), its Euler angles
//! away from rest, and an offset with its velocity in scene space. Each frame compares where the
//! bone's tip is now with where it was the frame before, as seen from the bone's new place.

use serde_json::Value;

use crate::mat::{self, M4};
use crate::quat::{self, M3, Quat, V3};

/// Metadata flags, as Wallpaper Engine stores them.
pub const SPRING: u32 = 0x1;
pub const FREE: u32 = 0x2;
pub const GRAVITY: u32 = 0x4;
const LIMIT_ANGLE: u32 = 0x8;
const LIMIT_SPEED: u32 = 0x10;
/// The end bone of a chain turns towards a target it cannot reach.
pub const IK_REACH: u32 = 0x40;
/// A rope chain may stretch to its target.
pub const IK_STRETCH: u32 = 0x80;
/// A chain's end is free: it keeps its own rotation instead of the target's.
pub const IK_FREE_END: u32 = 0x100;
const ROTATE: u32 = 0x1000;
const TRANSLATE: u32 = 0x2000;
const IK: u32 = 0x4000;
/// The bone's turn in a chain is limited to `ik_limits`.
pub const IK_LIMIT: u32 = 0x8000;
const NO_TURN: [u32; 3] = [0x10_0000, 0x20_0000, 0x40_0000];
const LOCKED: [u32; 3] = [0x80_0000, 0x100_0000, 0x200_0000];

/// One bone's physics and inverse kinematics settings from its metadata JSON.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Settings {
    pub flags: u32,
    /// Gravity direction (scene space, y up) and strength.
    pub gravity: V3,
    pub mass: f32,
    /// Translation friction per second; for a rope, `(tf / 100)²`.
    pub friction: f32,
    rotation_spring: f32,
    translation_spring: f32,
    rotation_friction: f32,
    /// `1 - ri / 100` and `1 - ti / 100`.
    rotation_pull: f32,
    translation_lag: f32,
    tip: V3,
    max_offset: f32,
    angle_limits: [V3; 2],
    /// Degrees per sixtieth of a second, per axis.
    max_speed: f32,
    /// Rope elements; a rope's reach in degrees per unit; a chain joint's angle limits.
    pub ik_depth: i32,
    pub ik_reach: f32,
    pub ik_limits: [f32; 2],
}

impl Settings {
    /// The settings in a bone's metadata, or `None` when it has neither physics nor inverse
    /// kinematics settings.
    pub fn parse(metadata: &str) -> Option<Self> {
        let json: Value = serde_json::from_str(metadata).ok()?;
        let flag = |key: &str| json[key].as_bool() == Some(true);
        let num = |key: &str, default: f32| json[key].as_f64().map_or(default, |v| v as f32);
        let vec3 = |key: &str| {
            let f = crate::scene::floats(&json[key]);
            [0, 1, 2].map(|i| f.get(i).copied().unwrap_or(0.0))
        };
        let mut s = Self { mass: 1000.0, rotation_pull: 1.0, translation_lag: 1.0, ik_depth: 2, ik_reach: 50.0, ..Self::default() };
        for (key, bit) in [
            ("r", ROTATE),
            ("t", TRANSLATE),
            ("se", SPRING),
            ("re", FREE),
            ("ik", IK),
            ("ikce", IK_LIMIT),
            ("ikg", 0x20),
            ("ikr", IK_REACH),
            ("ikse", IK_STRETCH),
            ("ikfe", IK_FREE_END),
        ] {
            if flag(key) {
                s.flags |= bit;
            }
        }
        let physics = s.flags & (ROTATE | TRANSLATE) != 0 && s.flags & (SPRING | FREE) != 0;
        let ik = s.flags & IK != 0;
        if physics || ik {
            if flag("ge") {
                s.flags |= GRAVITY;
            }
            s.gravity = vec3("gd");
            s.mass = num("m", 1000.0);
            let tf = num("tf", 0.0);
            s.friction = if physics { tf } else { ((tf / 100.0) * (tf / 100.0)).clamp(0.0, 1.0) };
        }
        if physics {
            s.rotation_spring = num("rs", 0.0);
            s.translation_spring = num("ts", 0.0);
            s.rotation_friction = num("rf", 0.0);
            s.rotation_pull = 1.0 - num("ri", 0.0) / 100.0;
            s.translation_lag = 1.0 - num("ti", 0.0) / 100.0;
            s.tip = vec3("tp");
            s.max_offset = num("tm", 0.0);
            if json["la"] == Value::Bool(true) {
                s.flags |= LIMIT_ANGLE;
                s.angle_limits = [vec3("lamin"), vec3("lamax")];
            }
            if flag("lt") {
                s.flags |= LIMIT_SPEED;
                s.max_speed = num("ltmax", 0.0);
            }
            // An axis switch counts only when all three of a set are given.
            for (keys, bits) in [(["rax", "ray", "raz"], NO_TURN), (["tax", "tay", "taz"], LOCKED)] {
                if keys.iter().all(|k| json[*k].is_boolean()) {
                    for (k, bit) in keys.iter().zip(bits) {
                        if json[*k] == Value::Bool(false) {
                            s.flags |= bit;
                        }
                    }
                }
            }
        }
        let depth = json["ikd"].as_i64().unwrap_or(2) as i32;
        s.ik_depth = if depth < 2 { 1 } else { depth };
        if s.flags & IK_REACH != 0 {
            s.ik_reach = num("ikrd", 50.0).max(1.0);
        }
        if s.flags & IK_LIMIT != 0 && !ik {
            s.ik_limits = [num("ikrminl", 0.0), num("ikrmaxl", 0.0)];
        }
        if !(physics || ik || s.flags & IK_LIMIT != 0) {
            return None;
        }
        Some(s)
    }

    pub fn moves(&self) -> bool {
        self.flags & (ROTATE | TRANSLATE) != 0
    }
}

/// A bone's motion between frames.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Motion {
    /// Turn per sixtieth of a second.
    speed: Quat,
    angles: V3,
    offset: V3,
    velocity: V3,
}

impl Default for Motion {
    fn default() -> Self {
        Self { speed: quat::IDENTITY, angles: [0.0; 3], offset: [0.0; 3], velocity: [0.0; 3] }
    }
}

/// The physics of a skeleton's bones and their state between frames.
#[derive(Debug, Clone)]
pub struct Physics {
    pub settings: Vec<Option<Settings>>,
    motion: Vec<Motion>,
    /// Last frame's final bone matrices in scene space; none before the first frame.
    previous: Option<Vec<M4>>,
}

/// One physics step: the frame's elapsed seconds and the puppet layer's placement in the scene
/// (row-vector), which the bones lag behind.
#[derive(Clone, Copy)]
pub struct Step<'a> {
    pub dt: f32,
    pub object: &'a M4,
}

impl Physics {
    pub fn new(settings: Vec<Option<Settings>>) -> Self {
        Self { motion: vec![Motion::default(); settings.len()], settings, previous: None }
    }

    /// Whether any bone moves by physics.
    pub fn any(&self) -> bool {
        self.settings.iter().flatten().any(Settings::moves)
    }

    /// Starts over at rest (the scene restarted).
    pub fn reset(&mut self) {
        self.motion.fill(Motion::default());
        self.previous = None;
    }

    /// A script's push (`applyBonePhysicsImpulse`): `translation` adds to bone `i`'s velocity
    /// (scene space, y up as scripts see it), `degrees` turns its turn speed.
    pub fn impulse(&mut self, i: usize, translation: V3, degrees: V3) {
        if let Some(m) = self.motion.get_mut(i) {
            m.velocity = quat::add(m.velocity, [translation[0], -translation[1], translation[2]]);
            m.speed = quat::mul(m.speed, quat::from_euler(degrees.map(|d| d * 0.017_453_292)));
        }
    }

    /// Puts bone `i` back at rest (`resetBonePhysicsSimulation`).
    pub fn reset_bone(&mut self, i: usize) {
        if let Some(m) = self.motion.get_mut(i) {
            *m = Motion::default();
        }
    }

    /// Keeps the frame's final matrices (model space) to lag behind in the next one.
    pub fn finish(&mut self, world: &[M4], step: Step<'_>) {
        self.previous = Some(world.iter().map(|w| mat::mul(w, step.object)).collect());
    }

    /// Bone `i`'s world matrix with its physics applied, advancing it by `step`. The first frame
    /// has nothing to lag behind and only places the bone.
    pub fn apply(&mut self, i: usize, world: &M4, step: Step<'_>) -> M4 {
        let Some(s) = self.settings.get(i).copied().flatten().filter(Settings::moves) else {
            return *world;
        };
        let Some(previous) = self.previous.as_ref().and_then(|p| p.get(i)) else {
            return *world;
        };
        let m = mat::mul(world, step.object);
        let o = step.object;
        let row_len = |r: usize| quat::length([o[r][0], o[r][1], o[r][2]]);
        let avg_scale = (row_len(1) + row_len(0) + row_len(2)) / 3.0;
        let local = advance(&s, &mut self.motion[i], &m, previous, step.dt, avg_scale);
        mat::mul(&local, world)
    }
}

/// One bone's physics step. `m` is its scene matrix before physics, `previous` last frame's final
/// one. Returns the turn and offset to apply in the bone's own space.
fn advance(s: &Settings, state: &mut Motion, m: &M4, previous: &M4, dt: f32, avg_scale: f32) -> M4 {
    use quat::{add, apply, dot, length, normalize3, scale, sub};
    let rows: M3 = std::array::from_fn(|r| [m[r][0], m[r][1], m[r][2]]);
    let inv = quat::inverse3(&rows);
    let origin = [m[3][0], m[3][1], m[3][2]];
    let before = [previous[3][0], previous[3][1], previous[3][2]];
    // Our scene space is y down; Wallpaper Engine's gravity direction is y up.
    let gravity = [s.gravity[0], -s.gravity[1], s.gravity[2]];

    let lagged = apply(sub(mat::point(previous, s.tip), origin), &inv);
    let current = apply(s.tip, &quat::euler_matrix(state.angles));
    let mut from = add(current, apply(state.offset, &inv));
    if s.flags & GRAVITY != 0 {
        let pull = scale(apply(gravity, &inv), s.mass * avg_scale);
        let n = normalize3(current);
        from = sub(from, sub(pull, scale(n, dot(n, pull))));
        if s.flags & TRANSLATE != 0 {
            state.velocity = add(state.velocity, scale(gravity, s.mass * dt * 1000.0));
        }
    }
    let gap = length(sub(from, lagged)).min(dt * 900.0);
    let turn = quat::rotation(normalize3(from), normalize3(lagged));
    let pull = (gap * s.rotation_pull * 0.017_453_292).min(1.0);
    let free = s.flags & FREE != 0;
    let spring = s.flags & SPRING != 0;

    if s.flags & ROTATE != 0 && (free || spring) {
        state.speed = quat::mul(state.speed, quat::slerp(quat::IDENTITY, turn, pull));
        if !free {
            let back = quat::from_euler(scale(state.angles, -1.0));
            let k = (s.rotation_spring * 0.017_453_292 * dt).min(1.0);
            state.speed = quat::mul(state.speed, quat::slerp(quat::IDENTITY, back, k));
        }
        if s.flags & LIMIT_SPEED != 0 {
            state.speed = limit_speed(state.speed, s.max_speed);
        }
        let step = quat::slerp(quat::IDENTITY, state.speed, (dt / 0.016_666_668).min(1.0));
        let turned = quat::mul3(&quat::euler_matrix(state.angles), &quat::matrix(step));
        state.angles = quat::extract_euler(&turned);
        if !free {
            for (k, angle) in state.angles.iter_mut().enumerate() {
                *angle = if s.flags & NO_TURN[k] != 0 { 0.0 } else { wrap(*angle) };
            }
        }
        if s.flags & LIMIT_ANGLE != 0 {
            let held: V3 = std::array::from_fn(|k| state.angles[k].max(s.angle_limits[0][k]).min(s.angle_limits[1][k]));
            let undo = quat::conj(quat::from_euler(sub(state.angles, held)));
            state.speed = quat::mul(undo, state.speed);
            state.angles = held;
        }
        if free {
            for (k, angle) in state.angles.iter_mut().enumerate() {
                if s.flags & NO_TURN[k] != 0 {
                    *angle = 0.0;
                }
            }
        }
        state.speed = quat::slerp(state.speed, quat::IDENTITY, (dt * s.rotation_friction).min(1.0));
    }

    if s.flags & TRANSLATE != 0 && (free || spring) {
        let moved = sub(add(state.offset, origin), before);
        let lagging = sub(state.offset, scale(moved, s.translation_lag));
        let friction = (dt * s.friction).min(1.0);
        if free {
            state.offset = add(lagging, scale(state.velocity, dt));
            state.offset = hold(state.offset, s, &rows, avg_scale);
            state.velocity = sub(state.velocity, scale(state.velocity, friction));
        } else {
            let velocity = sub(state.velocity, scale(lagging, dt * s.translation_spring));
            state.offset = add(lagging, scale(velocity, dt));
            state.offset = hold(state.offset, s, &rows, avg_scale);
            state.velocity = sub(velocity, scale(velocity, friction));
        }
    }

    let r = quat::euler_matrix(state.angles);
    let t = apply(state.offset, &inv);
    [
        [r[0][0], r[0][1], r[0][2], 0.0],
        [r[1][0], r[1][1], r[1][2], 0.0],
        [r[2][0], r[2][1], r[2][2], 0.0],
        [t[0], t[1], t[2], 1.0],
    ]
}

/// Locks the offset's locked axes (the bone's scene axes) and keeps it within `tm`.
fn hold(mut offset: V3, s: &Settings, rows: &M3, avg_scale: f32) -> V3 {
    for (k, row) in rows.iter().enumerate() {
        if s.flags & LOCKED[k] != 0 {
            offset = quat::sub(offset, quat::scale(*row, quat::dot(offset, *row) / quat::dot(*row, *row)));
        }
    }
    let max = s.max_offset * avg_scale;
    let len = quat::length(offset);
    if max > 0.0 && len > max {
        offset = quat::scale(offset, max / len);
    }
    offset
}

/// Caps a turn speed at `max` degrees about each axis.
fn limit_speed(q: Quat, max: f32) -> Quat {
    let mut v = [q[0] / q[3], q[1] / q[3], q[2] / q[3], 1.0];
    for c in &mut v[..3] {
        let mut a = (c.atan() * 57.295_78 * 2.0).min(max);
        if -max > a {
            a = -max;
        }
        *c = (a * 0.017_453_292 * 0.5).tan();
    }
    quat::normalize(v)
}

/// An angle wrapped into [-pi, pi), as Wallpaper Engine's `fmodf` form computes it.
fn wrap(angle: f32) -> f32 {
    use std::f32::consts::PI;
    if angle < 0.0 {
        (angle - PI) % (2.0 * PI) + PI
    } else {
        (angle + PI) % (2.0 * PI) - PI
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(y: f32) -> M4 {
        let mut m = mat::IDENTITY;
        m[3][1] = y;
        m
    }

    fn settle(metadata: &str, frames: usize, mut place: impl FnMut(usize) -> f32) -> (Physics, M4) {
        let mut physics = Physics::new(vec![Settings::parse(metadata)]);
        let mut world = mat::IDENTITY;
        for f in 0..frames {
            let object = at(place(f));
            let step = Step { dt: 1.0 / 60.0, object: &object };
            world = physics.apply(0, &mat::IDENTITY, step);
            physics.finish(&[world], step);
        }
        (physics, world)
    }

    #[test]
    fn a_spring_swings_behind_its_tree_and_settles() {
        let spring = r#"{"r":true,"se":true,"rs":300,"ri":30,"rf":30,"tp":"100 0 0"}"#;
        // The tree moves up after the first frame: the tip lags below, a clockwise turn.
        let (_, world) = settle(spring, 2, |f| if f == 0 { 0.0 } else { 20.0 });
        assert!(world[0][1] < -0.01, "{world:?}");
        // Held still, it swings back and comes to rest.
        let (_, world) = settle(spring, 700, |f| if f == 0 { 0.0 } else { 20.0 });
        assert!(world[0][1].abs() < 1e-3, "{world:?}");
    }

    #[test]
    fn a_free_bone_keeps_its_turn() {
        let free = r#"{"r":true,"re":true,"ri":30,"rf":30,"tp":"100 0 0"}"#;
        let (_, world) = settle(free, 700, |f| if f == 0 { 0.0 } else { 20.0 });
        assert!(world[0][1] < -0.01, "{world:?}");
    }

    #[test]
    fn a_translation_spring_lags_and_returns() {
        let spring = r#"{"t":true,"se":true,"ts":200,"tf":5,"ti":0}"#;
        let (_, world) = settle(spring, 2, |f| if f == 0 { 0.0 } else { 20.0 });
        assert!(world[3][1] < -10.0, "{world:?}");
        let (_, world) = settle(spring, 900, |f| if f == 0 { 0.0 } else { 20.0 });
        assert!(world[3][1].abs() < 0.1, "{world:?}");
    }

    #[test]
    fn gravity_pulls_a_free_hanging_bone_down() {
        // y up in Wallpaper Engine's scene: (0, -1, 0) pulls towards the bottom of the screen,
        // which is +y in our y-down scene space.
        let hanging = r#"{"r":true,"re":true,"ge":true,"gd":"0 -1 0","m":1,"rf":60,"tp":"100 0 0"}"#;
        let (_, world) = settle(hanging, 300, |_| 0.0);
        assert!(world[0][1] > 0.01, "{world:?}");
    }

    #[test]
    fn axis_switches_need_all_three() {
        let one = Settings::parse(r#"{"r":true,"se":true,"raz":false}"#).expect("spring");
        assert_eq!(one.flags & NO_TURN[2], 0);
        let all = Settings::parse(r#"{"r":true,"se":true,"rax":true,"ray":true,"raz":false}"#).expect("spring");
        assert_ne!(all.flags & NO_TURN[2], 0);
        assert!(Settings::parse(r#"{"r":true}"#).is_none());
    }
}
