//! A puppet's skeleton pose each frame, computed the way Wallpaper Engine's puppet update does
//! (see `NOTES.md`).
//!
//! Every bone starts from its rest transform. Each visible animation layer then samples the
//! bone's track: translation and scale are interpolated linearly between the two keyframes around
//! the time, the rotation as a quaternion along the shorter way (normalised lerp). A layer with
//! weight 1 that is not additive replaces the pose so far, a lighter one blends towards its sample
//! by the weight (the rotation again the shorter way). An additive layer adds its sample's change
//! from the rest pose: `pose + (sample - rest) * weight` for translation and scale, and for the
//! rotation the rest-to-sample turn `D = conj(rest) * sample`, scaled down by blending it with no
//! turn by the weight, after the pose's own rotation. A track flagged as excluded leaves the pose
//! as it is. Inverse kinematics handles blend the same way, and per-frame curves set constraint
//! weights, bone alphas, draw orders and morph target weights.
//!
//! Rotations apply about x, then y, then z (the order of `mat::from_trs`); as a quaternion that
//! is `qz * qy * qx`.
//!
//! The bones are then placed in index order: forward kinematics, the bone's constraints and its
//! physics (`physics`), and at the root of a chain group the group's inverse kinematics (`ik`).
//! Without any layer playing there are no handles, constraints or inverse kinematics.

use crate::ik::Ik;
use crate::mat::{self, M4};
use crate::physics::{Physics, Settings, Step};
use crate::puppet::{Animation, Bone, Curve, Puppet, Track, MESH_BONE_ALPHA, MESH_DRAW_ORDER};
use crate::quat::{self, Quat};

/// A local transform.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Local {
    pub translation: [f32; 3],
    pub rotation: Quat,
    pub scale: [f32; 3],
}

impl Local {
    /// The transform of a matrix (a bone's bind matrix).
    pub fn of_matrix(m: &M4) -> Self {
        let (translation, euler, scale) = mat::decompose(m);
        Self { translation, rotation: quat::from_euler(euler), scale }
    }

    /// The bind transform of a bone.
    pub fn of_bone(bone: &Bone) -> Self {
        Self::of_matrix(&bone.local)
    }

    /// Row-vector matrix in `mat::from_trs`'s layout: scale, then rotation, then translation.
    pub fn matrix(&self) -> M4 {
        let r = quat::matrix(self.rotation);
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

impl Layer<'_> {
    /// The layer replaces what is below it outright.
    fn full(&self) -> bool {
        !self.additive && self.weight >= 1.0
    }
}

/// The local transform of every bone: the rest pose with the layers applied in order.
pub fn blend(rest: &[Local], layers: &[Layer<'_>]) -> Vec<Local> {
    blend_tracks(rest, layers, |a| &a.tracks, &[])
}

/// Blends the tracks `tracks` picks from each layer's animation onto `rest`; `skip` marks tracks
/// to leave out.
fn blend_tracks(
    rest: &[Local],
    layers: &[Layer<'_>],
    tracks: impl Fn(&Animation) -> &[Track],
    skip: &[bool],
) -> Vec<Local> {
    let mut pose = rest.to_vec();
    for layer in layers {
        let anim = layer.animation;
        let Some((a, b, t)) = keyframes(anim, layer.time) else { continue };
        let w = layer.weight;
        for (i, (pose, rest)) in pose.iter_mut().zip(rest).enumerate() {
            // Tracks are stored in order, one per bone or handle.
            let Some(track) = tracks(anim).get(i).filter(|t| t.bone == i && !t.excluded) else {
                continue;
            };
            if skip.get(i).copied().unwrap_or(false) {
                continue;
            }
            let last = track.keyframes.len().saturating_sub(1);
            let (Some(ka), Some(kb)) = (track.keyframes.get(a.min(last)), track.keyframes.get(b.min(last)))
            else {
                continue;
            };
            let sample = Local {
                translation: quat::lerp(ka.translation, kb.translation, t),
                rotation: nlerp(quat::from_euler(ka.rotation), quat::from_euler(kb.rotation), t),
                scale: quat::lerp(ka.scale, kb.scale, t),
            };
            if layer.additive {
                for k in 0..3 {
                    pose.translation[k] += (sample.translation[k] - rest.translation[k]) * w;
                    pose.scale[k] += (sample.scale[k] - rest.scale[k]) * w;
                }
                let d = quat::mul(quat::conj(rest.rotation), sample.rotation);
                let sign = if d[3] < 0.0 { -1.0 } else { 1.0 };
                let d = quat::normalize(std::array::from_fn(|k| {
                    quat::IDENTITY[k] * (1.0 - w) + sign * w * d[k]
                }));
                pose.rotation = quat::mul(pose.rotation, d);
            } else if w >= 1.0 {
                *pose = sample;
            } else {
                pose.translation = quat::lerp(pose.translation, sample.translation, w);
                pose.scale = quat::lerp(pose.scale, sample.scale, w);
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

/// A curve's value between frames `a` and `b`.
fn sample(curve: &Curve, (a, b, t): (usize, usize, f32)) -> f32 {
    let last = curve.values.len().saturating_sub(1);
    let (va, vb) = (curve.values.get(a.min(last)), curve.values.get(b.min(last)));
    va.zip(vb).map_or(0.0, |(va, vb)| va + (vb - va) * t)
}

/// What the layers set besides transforms, per frame.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Extras {
    /// Each bone's alpha (mesh flag `MESH_BONE_ALPHA`), else empty.
    pub alpha: Vec<f32>,
    /// Each bone's draw order (mesh flag `MESH_DRAW_ORDER`), else empty.
    pub orders: Vec<f32>,
    /// A layer moved a bone in the draw order: the parts need sorting again.
    pub resort: bool,
    /// Each morph target's weight, and whether it is on.
    pub morphs: Vec<(f32, bool)>,
    /// The blend map's values (`g_BlendMap`, four per row). Unlike the rest they are never
    /// reset: a value no layer sets keeps the last one given.
    pub blend_values: Vec<f32>,
}

/// A skeleton's pose machinery and its state between frames.
#[derive(Debug, Clone)]
pub struct Rig {
    /// The pose animations start from: the rest matrices when the file has them, else the bind
    /// transforms; and the handles' rest transforms.
    rest: Vec<Local>,
    handle_rest: Vec<Local>,
    /// Bones the solver places (see `Puppet::solver_driven`).
    driven: Vec<bool>,
    physics: Physics,
    ik: Option<Ik>,
    /// Constraint weights; a curve a layer leaves out keeps last frame's value.
    weights: Vec<f32>,
    /// World matrix of every bone (model space, row-vector); solved bones carry theirs over.
    pub world: Vec<M4>,
    /// World matrix of every handle (model space).
    pub handles: Vec<M4>,
    pub extras: Extras,
}

impl Rig {
    pub fn new(model: &Puppet) -> Self {
        let bind_world = bind_world(&model.bones);
        let rest = match &model.rest {
            Some((bones, _)) if bones.len() == model.bones.len() => bones.iter().map(Local::of_matrix).collect(),
            _ => model.bones.iter().map(Local::of_bone).collect(),
        };
        let handle_rest = match &model.rest {
            Some((_, handles)) if handles.len() == model.handles.len() => handles.iter().map(Local::of_matrix).collect(),
            _ => model.handles.iter().map(|h| Local::of_matrix(&h.matrix)).collect(),
        };
        let settings = model.bones.iter().map(|b| b.metadata.as_deref().and_then(Settings::parse)).collect();
        Self {
            rest,
            handle_rest,
            driven: model.solver_driven(),
            physics: Physics::new(settings),
            ik: Ik::new(model, &bind_world),
            weights: vec![0.0; model.constraints.len()],
            handles: model.handles.iter().map(|h| h.matrix).collect(),
            world: bind_world,
            extras: Extras {
                blend_values: vec![0.0; model.blend_map.as_ref().map_or(0, |m| (m.rows as usize * 4).max(4))],
                ..Extras::default()
            },
        }
    }

    /// Whether bones move by physics, so the pose needs the layer's placement every frame.
    pub fn has_physics(&self) -> bool {
        self.physics.any()
    }

    /// Starts over (the scene restarted).
    pub fn reset(&mut self, model: &Puppet) {
        self.physics.reset();
        if let Some(ik) = &mut self.ik {
            ik.reset();
        }
        self.weights.fill(0.0);
        self.world = bind_world(&model.bones);
    }

    /// The bones' physics, for scripts' pushes and resets.
    pub fn physics_mut(&mut self) -> &mut Physics {
        &mut self.physics
    }

    /// A script's blend shape weight for this frame (`setBlendShapeWeight`): it replaces what the
    /// curves gave target `i`. Wallpaper Engine switches targets on or off through the bits of
    /// `(int64)(int)(1 << (i & 31))`, which from index 31 on reaches other targets' switches; so
    /// does this.
    pub fn set_morph(&mut self, i: usize, weight: f32) {
        let morphs = &mut self.extras.morphs;
        if let Some(m) = morphs.get_mut(i) {
            m.0 = weight;
        }
        let bits = i64::from(1i32.wrapping_shl((i & 31) as u32)) as u64;
        let on = weight.abs() >= f32::EPSILON;
        for (k, m) in morphs.iter_mut().enumerate().take(64) {
            if bits >> k & 1 == 1 {
                m.1 = on;
            }
        }
    }

    /// Poses the skeleton for `layers`, stepping physics and ropes by `step`.
    pub fn pose(&mut self, model: &Puppet, layers: &[Layer<'_>], step: Option<Step<'_>>) {
        let layers: Vec<&Layer<'_>> = layers.iter().filter(|l| l.weight > 0.0).collect();
        let owned: Vec<Layer<'_>> = layers
            .iter()
            .map(|l| Layer { animation: l.animation, time: l.time, weight: l.weight, additive: l.additive })
            .collect();
        let local = blend_tracks(&self.rest, &owned, |a| &a.tracks, &self.driven);
        self.blend_curves(model, &owned);
        let applied = !owned.is_empty();
        if applied && !self.handle_rest.is_empty() {
            let handles = blend_tracks(&self.handle_rest, &owned, |a| &a.handle_tracks, &[]);
            self.handles = handles
                .iter()
                .map(|h| {
                    let r = quat::matrix(h.rotation);
                    let t = h.translation;
                    [
                        [r[0][0], r[0][1], r[0][2], 0.0],
                        [r[1][0], r[1][1], r[1][2], 0.0],
                        [r[2][0], r[2][1], r[2][2], 0.0],
                        [t[0], t[1], t[2], 1.0],
                    ]
                })
                .collect();
        }
        let physics = step.filter(|_| self.physics.any());
        let dt = step.map_or(0.0, |s| s.dt);
        for (i, bone) in model.bones.iter().enumerate() {
            if !(applied && self.driven[i]) {
                let m = local.get(i).map_or(bone.local, Local::matrix);
                self.world[i] = match bone.parent {
                    Some(p) if p < i => mat::mul(&m, &self.world[p]),
                    _ => m,
                };
                if applied {
                    if let Some(ik) = &self.ik {
                        ik.constrain_bone(i, model, &mut self.world, &self.weights);
                    }
                }
                if let Some(step) = physics {
                    self.world[i] = self.physics.apply(i, &self.world[i], step);
                }
            }
            if applied {
                if let Some(ik) = &mut self.ik {
                    if let Some(g) = ik.group(i) {
                        ik.solve(g, model, &self.physics.settings, &mut self.world, &mut self.handles, &self.weights, dt);
                    }
                }
            }
        }
        if let Some(step) = physics {
            self.physics.finish(&self.world, step);
        }
    }

    /// Constraint weights, bone alphas, draw orders and morph weights for this frame's layers.
    fn blend_curves(&mut self, model: &Puppet, layers: &[Layer<'_>]) {
        let bones = model.bones.len();
        let e = &mut self.extras;
        e.alpha = if model.mesh_flags & MESH_BONE_ALPHA != 0 { vec![1.0; bones] } else { Vec::new() };
        e.orders = if model.mesh_flags & MESH_DRAW_ORDER != 0 {
            model.rest_orders.iter().map(|&o| o as f32).collect()
        } else {
            Vec::new()
        };
        e.morphs = vec![(0.0, false); model.morphs.as_ref().map_or(0, |m| m.targets.len())];
        for (n, layer) in layers.iter().enumerate() {
            let anim = layer.animation;
            let Some(at) = keyframes(anim, layer.time) else { continue };
            let w = layer.weight;
            let mix = |old: f32, s: f32| if layer.full() { s } else { old + (s - old) * w };
            if n == 0 {
                let excluded = anim.tracks.iter().enumerate().any(|(i, t)| t.excluded || self.driven.get(i) == Some(&true))
                    || anim.handle_tracks.iter().any(|t| t.excluded);
                if !layer.full() || excluded {
                    self.weights.fill(0.0);
                }
            }
            for (i, curve) in anim.blend_map.iter().enumerate().take(e.blend_values.len()) {
                let (old, s) = (e.blend_values[i], sample(curve, at));
                e.blend_values[i] = if layer.additive { old + s * w } else { mix(old, s) };
            }
            for (c, curve) in anim.constraint_curves.iter().enumerate() {
                if curve.excluded || c >= self.weights.len() {
                    continue;
                }
                let s = sample(curve, at);
                self.weights[c] = if layer.additive { self.weights[c] + s * w } else { mix(self.weights[c], s) };
            }
            let tracks = &anim.tracks;
            let kept = |i: usize| tracks.get(i).is_some_and(|t| !t.excluded);
            for (i, curve) in anim.alpha.iter().enumerate().take(e.alpha.len()) {
                if !kept(i) {
                    continue;
                }
                let (old, s) = (e.alpha[i], sample(curve, at));
                e.alpha[i] = if layer.additive {
                    (old + (s - 1.0) * w).clamp(old.min(s), old.max(s))
                } else {
                    mix(old, s)
                };
            }
            for (i, curve) in anim.orders.iter().enumerate().take(e.orders.len()) {
                if !kept(i) {
                    continue;
                }
                // Draw orders step from frame to frame.
                let (old, s) = (e.orders[i], curve.values.get(at.0).copied().unwrap_or(0.0));
                let rest = model.rest_orders.get(i).copied().unwrap_or(0) as f32;
                e.orders[i] = if layer.additive {
                    (old + (s - rest) * w).clamp(old.min(s), old.max(s))
                } else {
                    mix(old, s)
                };
                e.resort = true;
            }
            for (target, curve) in &anim.morphs {
                let Some((weight, on)) = e.morphs.get_mut(*target) else { continue };
                let s = sample(curve, at);
                if layer.additive {
                    let v = s * w;
                    *weight = (*weight + v).clamp(weight.min(v), weight.max(v));
                    *on |= weight.abs() >= f32::EPSILON;
                } else if layer.full() {
                    *on = s.abs() >= f32::EPSILON;
                    *weight = s;
                } else {
                    *weight += (s - *weight) * w;
                    *on |= s.abs() >= f32::EPSILON;
                }
            }
        }
    }
}

/// Bind world matrices: each bone's bind matrix through its parents.
pub fn bind_world(bones: &[Bone]) -> Vec<M4> {
    let mut world = vec![mat::IDENTITY; bones.len()];
    for (i, bone) in bones.iter().enumerate() {
        world[i] = match bone.parent {
            Some(p) if p < i => mat::mul(&bone.local, &world[p]),
            _ => bone.local,
        };
    }
    world
}

/// Normalised lerp from `a` to `b` along the shorter way.
fn nlerp(a: Quat, b: Quat, t: f32) -> Quat {
    let sign = if quat::dot4(a, b) < 0.0 { -1.0 } else { 1.0 };
    quat::normalize(std::array::from_fn(|k| a[k] * (1.0 - t) + b[k] * sign * t))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::puppet::Transform;

    fn close(a: &[f32], b: &[f32]) -> bool {
        a.iter().zip(b).all(|(a, b)| (a - b).abs() < 1e-4)
    }

    #[test]
    fn local_matrices_match_from_trs() {
        let euler = [0.3, -0.7, 1.9];
        let local = Local { translation: [1.0, 2.0, 3.0], rotation: quat::from_euler(euler), scale: [2.0, 0.5, 1.5] };
        let expected = mat::from_trs([1.0, 2.0, 3.0], euler, [2.0, 0.5, 1.5]);
        assert!(close(local.matrix().as_flattened(), expected.as_flattened()));
    }

    fn turning(frames: &[f32], additive_bind: f32) -> (Vec<Local>, Animation) {
        let keyframes = frames
            .iter()
            .map(|&z| Transform { translation: [0.0; 3], rotation: [0.0, 0.0, z], scale: [1.0; 3] })
            .collect();
        let bind = Local { translation: [0.0; 3], rotation: quat::from_euler([0.0, 0.0, additive_bind]), scale: [1.0; 3] };
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

    fn one_bone(mesh_flags: u32) -> (Puppet, Animation) {
        let (_, mut anim) = turning(&[0.0, 0.0], 0.0);
        let curve = |values: Vec<f32>| Curve { values, excluded: false };
        anim.alpha = vec![curve(vec![0.2, 0.6])];
        anim.orders = vec![curve(vec![300.0, 900.0])];
        anim.morphs = vec![(0, curve(vec![0.0, 1.0]))];
        let model = Puppet {
            mesh_flags,
            bones: vec![Bone { local: mat::IDENTITY, ..Bone::default() }],
            rest_orders: vec![100],
            morphs: Some(crate::puppet::Morphs { targets: vec![Default::default()], ..Default::default() }),
            ..Puppet::default()
        };
        (model, anim)
    }

    #[test]
    fn curves_set_alpha_order_and_morph_weights() {
        let (model, anim) = one_bone(MESH_BONE_ALPHA | MESH_DRAW_ORDER);
        let mut rig = Rig::new(&model);
        let layer = Layer { animation: &anim, time: 0.5, weight: 1.0, additive: false };
        rig.pose(&model, &[layer], None);
        assert!((rig.extras.alpha[0] - 0.4).abs() < 1e-5);
        // Orders step: the frame the time falls in.
        assert_eq!(rig.extras.orders, vec![300.0]);
        assert!(rig.extras.resort);
        assert_eq!(rig.extras.morphs, vec![(0.5, true)]);
        // Half a layer goes half way from the rest values.
        let layer = Layer { animation: &anim, time: 0.5, weight: 0.5, additive: false };
        rig.pose(&model, &[layer], None);
        assert!((rig.extras.alpha[0] - 0.7).abs() < 1e-5);
        assert_eq!(rig.extras.orders, vec![200.0]);
    }

    #[test]
    fn meshes_without_the_flags_get_no_alpha_or_order() {
        let (model, anim) = one_bone(0);
        let mut rig = Rig::new(&model);
        rig.pose(&model, &[Layer { animation: &anim, time: 0.5, weight: 1.0, additive: false }], None);
        assert!(rig.extras.alpha.is_empty() && rig.extras.orders.is_empty());
    }
}
