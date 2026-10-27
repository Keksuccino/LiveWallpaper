//! A puppet's skeleton pose each frame, computed the way Wallpaper Engine's puppet update does
//! (see `NOTES.md`).
//!
//! Every bone starts from its bind transform. Each visible animation layer then samples the
//! bone's track: translation and scale are interpolated linearly between the two keyframes around
//! the time, the rotation as a quaternion along the shorter way (normalised lerp). A layer with
//! weight 1 that is not additive replaces the pose so far, a lighter one blends towards its sample
//! by the weight (the rotation again the shorter way). An additive layer adds its sample's change
//! from the bind pose: `pose + (sample - bind) * weight` for translation and scale, and for the
//! rotation the bind-to-sample turn `D = conj(bind) * sample`, scaled down by blending it with no
//! turn by the weight, after the pose's own rotation. A track flagged as excluded leaves the pose
//! as it is.
//!
//! Rotations apply about x, then y, then z (the order of `mat::from_trs`); as a quaternion that
//! is `qz * qy * qx`.
//!
//! Bones with spring metadata then swing behind the motion of their tree (`Springs`).

use serde_json::Value;

use crate::mat::{self, M4};
use crate::puppet::{Animation, Bone};

/// A rotation as a unit quaternion: x, y, z, w.
pub type Quat = [f32; 4];

const IDENTITY_QUAT: Quat = [0.0, 0.0, 0.0, 1.0];

/// A bone's local transform.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Local {
    pub translation: [f32; 3],
    pub rotation: Quat,
    pub scale: [f32; 3],
}

impl Local {
    /// The bind transform of a bone from its matrix.
    pub fn of_bone(bone: &Bone) -> Self {
        let (translation, euler, scale) = mat::decompose(&bone.local);
        Self { translation, rotation: euler_quat(euler), scale }
    }

    /// Row-vector matrix in `mat::from_trs`'s layout: scale, then rotation, then translation.
    pub fn matrix(&self) -> M4 {
        let [x, y, z, w] = self.rotation;
        // The rotation's column-vector matrix, transposed for row vectors.
        let r = [
            [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y + z * w), 2.0 * (x * z - y * w)],
            [2.0 * (x * y - z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z + x * w)],
            [2.0 * (x * z + y * w), 2.0 * (y * z - x * w), 1.0 - 2.0 * (x * x + y * y)],
        ];
        let s = self.scale;
        let t = self.translation;
        [
            [r[0][0] * s[0], r[0][1] * s[0], r[0][2] * s[0], 0.0],
            [r[1][0] * s[1], r[1][1] * s[1], r[1][2] * s[1], 0.0],
            [r[2][0] * s[2], r[2][1] * s[2], r[2][2] * s[2], 0.0],
            [t[0], t[1], t[2], 1.0],
        ]
    }
}

/// An animation layer as it plays this frame.
pub struct Layer<'a> {
    pub animation: &'a Animation,
    /// Seconds into the animation, its play mode applied.
    pub time: f32,
    /// The layer's weight with its fades applied.
    pub weight: f32,
    pub additive: bool,
}

/// The local transform of every bone: the bind pose with the layers applied in order.
pub fn blend(bind: &[Local], layers: &[Layer<'_>]) -> Vec<Local> {
    let mut pose = bind.to_vec();
    for layer in layers.iter().filter(|l| l.weight > 0.0) {
        let anim = layer.animation;
        let Some((a, b, t)) = keyframes(anim, layer.time) else { continue };
        let w = layer.weight;
        for (i, (pose, bind)) in pose.iter_mut().zip(bind).enumerate() {
            // Tracks are stored in bone order, one per bone.
            let Some(track) = anim.tracks.get(i).filter(|t| t.bone == i && !t.excluded) else {
                continue;
            };
            let last = track.keyframes.len().saturating_sub(1);
            let (Some(ka), Some(kb)) = (track.keyframes.get(a.min(last)), track.keyframes.get(b.min(last)))
            else {
                continue;
            };
            let sample = Local {
                translation: lerp3(ka.translation, kb.translation, t),
                rotation: nlerp(euler_quat(ka.rotation), euler_quat(kb.rotation), t),
                scale: lerp3(ka.scale, kb.scale, t),
            };
            if layer.additive {
                for k in 0..3 {
                    pose.translation[k] += (sample.translation[k] - bind.translation[k]) * w;
                    pose.scale[k] += (sample.scale[k] - bind.scale[k]) * w;
                }
                let d = qmul(conj(bind.rotation), sample.rotation);
                let sign = if d[3] < 0.0 { -1.0 } else { 1.0 };
                let d = normalize(std::array::from_fn(|k| {
                    IDENTITY_QUAT[k] * (1.0 - w) + sign * w * d[k]
                }));
                pose.rotation = qmul(pose.rotation, d);
            } else if w >= 1.0 {
                *pose = sample;
            } else {
                pose.translation = lerp3(pose.translation, sample.translation, w);
                pose.scale = lerp3(pose.scale, sample.scale, w);
                pose.rotation = nlerp(pose.rotation, sample.rotation, w);
            }
        }
    }
    pose
}

/// The keyframes around `time` and how far between them it is: the frame the time falls in
/// (clamped below the last frame) and the next one, `fmod(time, 1 / fps) * fps`.
fn keyframes(anim: &Animation, time: f32) -> Option<(usize, usize, f32)> {
    if anim.fps <= 0.0 || !time.is_finite() {
        return None;
    }
    let frames = anim.duration_frames.max(1) as usize;
    let spf = 1.0 / anim.fps;
    let a = ((time / spf).max(0.0) as usize).min(frames - 1);
    let b = (a + 1).min(frames);
    Some((a, b, (time.rem_euclid(spf) / spf).clamp(0.0, 1.0)))
}

/// World matrices (row-vector, model space) of every bone from their local transforms.
pub fn walk(bones: &[Bone], local: &[Local], springs: Option<&mut Springs>, step: Option<Step<'_>>) -> Vec<M4> {
    let mut world = vec![mat::IDENTITY; bones.len()];
    let mut springs = springs;
    for (i, bone) in bones.iter().enumerate() {
        let m = local.get(i).map_or(bone.local, Local::matrix);
        world[i] = match bone.parent {
            Some(p) if p < i => mat::mul(&m, &world[p]),
            _ => m,
        };
        if let Some(springs) = springs.as_deref_mut() {
            world[i] = springs.swing(i, &world[i], step);
        }
    }
    if let (Some(springs), Some(step)) = (springs, step) {
        springs.previous = Some(world.iter().map(|w| mat::mul(w, step.object)).collect());
    }
    world
}

/// One physics step: the frame's elapsed seconds and the puppet layer's placement in the scene
/// (row-vector), which the springs lag behind.
#[derive(Clone, Copy)]
pub struct Step<'a> {
    pub dt: f32,
    pub object: &'a M4,
}

/// A bone's rotational spring, from its editor metadata (`r` and `se` set). Each frame the bone's
/// tip `tp` is pulled towards where it was the frame before, as seen from the bone's new place,
/// and the spring `rs` turns it back to rest; `ri` damps the pull and `rf` is friction. `lt` caps
/// the turn speed at `ltmax` degrees, `la` the angle to `lamin`...`lamax`. Only the turn about z
/// is modelled (puppets are flat); an axis whose `rax`/`ray`/`raz` is false never turns.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Spring {
    tip: [f32; 3],
    strength: f32,
    pull: f32,
    friction: f32,
    max_speed: Option<f32>,
    limits: Option<[f32; 2]>,
}

impl Spring {
    /// The spring a bone's metadata describes, if any.
    pub fn parse(metadata: &str) -> Option<Self> {
        let json: Value = serde_json::from_str(metadata).ok()?;
        let flag = |key: &str| json[key].as_bool() == Some(true);
        // Translation springs (`t`), the "re" mode and gravity are not modelled.
        if !(flag("r") && flag("se")) || json["raz"].as_bool() == Some(false) {
            return None;
        }
        let num = |key: &str| json[key].as_f64().unwrap_or(0.0) as f32;
        let vec3 = |key: &str| {
            let f = crate::scene::floats(&json[key]);
            [0, 1, 2].map(|i| f.get(i).copied().unwrap_or(0.0))
        };
        Some(Self {
            tip: vec3("tp"),
            strength: num("rs"),
            pull: 1.0 - num("ri") / 100.0,
            friction: num("rf"),
            max_speed: flag("lt").then(|| num("ltmax").to_radians()),
            limits: flag("la").then(|| [vec3("lamin")[2], vec3("lamax")[2]]),
        })
    }
}

/// A spring's motion: the bone's turn away from rest and its turn speed, in radians.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct Swing {
    angle: f32,
    speed: f32,
}

/// The springs of a puppet's bones and their state between frames.
#[derive(Debug, Clone)]
pub struct Springs {
    springs: Vec<Option<Spring>>,
    swing: Vec<Swing>,
    /// Last frame's final bone matrices in scene space; none before the first frame.
    previous: Option<Vec<M4>>,
}

impl Springs {
    /// The springs of a skeleton, or `None` when no bone has one.
    pub fn of(bones: &[Bone]) -> Option<Self> {
        let springs: Vec<Option<Spring>> =
            bones.iter().map(|b| b.metadata.as_deref().and_then(Spring::parse)).collect();
        springs.iter().any(Option::is_some).then(|| Self {
            swing: vec![Swing::default(); springs.len()],
            springs,
            previous: None,
        })
    }

    /// Starts over at rest (the scene restarted).
    pub fn reset(&mut self) {
        self.swing.fill(Swing::default());
        self.previous = None;
    }

    /// Bone `i`'s world matrix with its spring's turn applied, advancing the spring by `step`.
    /// The first frame has nothing to lag behind and only places the bones.
    fn swing(&mut self, i: usize, world: &M4, step: Option<Step<'_>>) -> M4 {
        let Some(spring) = self.springs.get(i).copied().flatten() else { return *world };
        if let (Some(step), Some(previous)) = (step.filter(|s| s.dt > 0.0), self.previous.as_ref()) {
            let dt = step.dt;
            let now = mat::mul(world, step.object);
            // Last frame's tip, seen from the bone's place now (its own space).
            let tip = mat::point(&previous[i], spring.tip);
            let mut rotation = now;
            rotation[3] = [0.0, 0.0, 0.0, 1.0];
            let lagged = mat::point(&mat::invert(&rotation), [0, 1, 2].map(|k| tip[k] - now[3][k]));
            let s = &mut self.swing[i];
            let current = rotate_z(spring.tip, s.angle);
            let towards = (current[0] * lagged[1] - current[1] * lagged[0])
                .atan2(current[0] * lagged[0] + current[1] * lagged[1]);
            let gap = (0..3).map(|k| (current[k] - lagged[k]).powi(2)).sum::<f32>().sqrt();
            s.speed += (gap.min(900.0 * dt) * spring.pull * std::f32::consts::PI / 180.0).min(1.0) * towards;
            s.speed -= (spring.strength.to_radians() * dt).min(1.0) * s.angle;
            if let Some(max) = spring.max_speed {
                s.speed = s.speed.clamp(-max, max);
            }
            s.angle = wrap(s.angle + (60.0 * dt).min(1.0) * s.speed);
            if let Some([lo, hi]) = spring.limits {
                let held = s.angle.clamp(lo, hi);
                s.speed -= s.angle - held;
                s.angle = held;
            }
            s.speed *= 1.0 - (spring.friction * dt).min(1.0);
        }
        let angle = self.swing[i].angle;
        if angle == 0.0 {
            return *world;
        }
        let (sin, cos) = angle.sin_cos();
        let turn = [[cos, sin, 0.0, 0.0], [-sin, cos, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]];
        mat::mul(&turn, world)
    }
}

/// `v` turned by `angle` about z (counter-clockwise, y up).
fn rotate_z(v: [f32; 3], angle: f32) -> [f32; 3] {
    let (sin, cos) = angle.sin_cos();
    [v[0] * cos - v[1] * sin, v[0] * sin + v[1] * cos, v[2]]
}

/// An angle wrapped into [-pi, pi).
fn wrap(angle: f32) -> f32 {
    use std::f32::consts::PI;
    (angle + PI).rem_euclid(2.0 * PI) - PI
}

/// The rotation of Euler angles (radians) applied about x, then y, then z: `qz * qy * qx`.
pub fn euler_quat(r: [f32; 3]) -> Quat {
    let (sx, cx) = (r[0] * 0.5).sin_cos();
    let (sy, cy) = (r[1] * 0.5).sin_cos();
    let (sz, cz) = (r[2] * 0.5).sin_cos();
    qmul(qmul([0.0, 0.0, sz, cz], [0.0, sy, 0.0, cy]), [sx, 0.0, 0.0, cx])
}

/// Hamilton product `a * b`: `b`'s rotation first, then `a`'s.
fn qmul(a: Quat, b: Quat) -> Quat {
    [
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    ]
}

fn conj(q: Quat) -> Quat {
    [-q[0], -q[1], -q[2], q[3]]
}

fn normalize(q: Quat) -> Quat {
    let len = q.iter().map(|v| v * v).sum::<f32>().sqrt();
    if len < 1e-12 {
        return IDENTITY_QUAT;
    }
    q.map(|v| v / len)
}

/// Normalised lerp from `a` to `b` along the shorter way.
fn nlerp(a: Quat, b: Quat, t: f32) -> Quat {
    let dot: f32 = (0..4).map(|k| a[k] * b[k]).sum();
    let sign = if dot < 0.0 { -1.0 } else { 1.0 };
    normalize(std::array::from_fn(|k| a[k] * (1.0 - t) + b[k] * sign * t))
}

fn lerp3(a: [f32; 3], b: [f32; 3], t: f32) -> [f32; 3] {
    std::array::from_fn(|k| a[k] + (b[k] - a[k]) * t)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::puppet::{Track, Transform};

    fn close(a: &[f32], b: &[f32]) -> bool {
        a.iter().zip(b).all(|(a, b)| (a - b).abs() < 1e-4)
    }

    #[test]
    fn local_matrices_match_from_trs() {
        let euler = [0.3, -0.7, 1.9];
        let local = Local { translation: [1.0, 2.0, 3.0], rotation: euler_quat(euler), scale: [2.0, 0.5, 1.5] };
        let expected = mat::from_trs([1.0, 2.0, 3.0], euler, [2.0, 0.5, 1.5]);
        assert!(close(local.matrix().as_flattened(), expected.as_flattened()));
    }

    fn turning(frames: &[f32], additive_bind: f32) -> (Vec<Local>, Animation) {
        let keyframes = frames
            .iter()
            .map(|&z| Transform { translation: [0.0; 3], rotation: [0.0, 0.0, z], scale: [1.0; 3] })
            .collect();
        let bind = Local { translation: [0.0; 3], rotation: euler_quat([0.0, 0.0, additive_bind]), scale: [1.0; 3] };
        let anim = Animation {
            fps: 1.0,
            duration_frames: frames.len() as u32 - 1,
            tracks: vec![Track { bone: 0, keyframes, excluded: false }],
            ..Animation::default()
        };
        (vec![bind], anim)
    }

    fn angle(q: Quat) -> f32 {
        2.0 * q[2].atan2(q[3])
    }

    #[test]
    fn rotations_interpolate_the_shorter_way() {
        // From just under +180 degrees to just over -180: through 180, not through 0.
        let (bind, anim) = turning(&[3.0, -3.0], 0.0);
        let layer = Layer { animation: &anim, time: 0.5, weight: 1.0, additive: false };
        let pose = blend(&bind, &[layer]);
        assert!(angle(pose[0].rotation).abs() > 3.1, "{:?}", pose[0].rotation);
    }

    #[test]
    fn additive_layers_add_their_turn_from_the_bind_pose() {
        let (bind, anim) = turning(&[0.5, 0.5], 0.2);
        let layer = Layer { animation: &anim, time: 0.0, weight: 1.0, additive: true };
        let pose = blend(&bind, &[layer]);
        // Bind 0.2 plus the 0.3 turn from bind to sample.
        assert!((angle(pose[0].rotation) - 0.5).abs() < 1e-4);
        // Half the weight blends the turn with none: about half of it for a small turn.
        let layer = Layer { animation: &anim, time: 0.0, weight: 0.5, additive: true };
        let pose = blend(&bind, &[layer]);
        assert!((angle(pose[0].rotation) - 0.35).abs() < 1e-3, "{}", angle(pose[0].rotation));
    }

    #[test]
    fn excluded_tracks_keep_the_pose_below() {
        let (bind, mut anim) = turning(&[1.0, 1.0], 0.0);
        anim.tracks[0].excluded = true;
        let layer = Layer { animation: &anim, time: 0.0, weight: 1.0, additive: false };
        assert_eq!(blend(&bind, &[layer]), bind);
    }

    #[test]
    fn a_spring_swings_behind_its_tree_and_settles() {
        let metadata = r#"{"r":true,"se":true,"raz":true,"rs":300,"ri":30,"rf":30,"la":true,
            "lamin":"0 0 -3.14159","lamax":"0 0 3.14159","tp":"100 0 0"}"#;
        let bone = Bone { local: mat::IDENTITY, metadata: Some(metadata.into()), ..Bone::default() };
        let bones = [bone];
        let local = [Local { translation: [0.0; 3], rotation: IDENTITY_QUAT, scale: [1.0; 3] }];
        let mut springs = Springs::of(&bones).expect("a spring");
        let at = |y: f32| {
            let mut m = mat::IDENTITY;
            m[3][1] = y;
            m
        };
        let frame = |springs: &mut Springs, y: f32| {
            let object = at(y);
            walk(&bones, &local, Some(springs), Some(Step { dt: 1.0 / 60.0, object: &object }))
        };
        frame(&mut springs, 0.0);
        // The tree moves up: the tip lags below, so the bone turns clockwise (negative angle).
        let world = frame(&mut springs, 20.0);
        assert!(world[0][0][1] < -0.01, "{:?}", world[0]);
        // Held still, it swings back and comes to rest.
        for _ in 0..600 {
            frame(&mut springs, 20.0);
        }
        let world = frame(&mut springs, 20.0);
        assert!(world[0][0][1].abs() < 1e-3, "{:?}", world[0]);
    }
}
