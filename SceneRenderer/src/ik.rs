//! Constraints and inverse kinematics of puppets, as Wallpaper Engine's puppet update runs them
//! (see `NOTES.md`, "Inverse kinematics").
//!
//! A bone constraint makes a bone follow another by a weight the animations set. Handles are
//! animated targets and poles in model space; their own constraints copy a bone's transform or
//! position, hold them on a line along a bone, or slide them along a rail. When the per-bone walk
//! reaches the root of a chain group, the group's handle constraints run, then its chains are
//! solved with FABRIK: up to ten passes back from the targets and forward from the roots, bent
//! towards the poles and limited at joints with angle limits. The solved bones then turn from
//! their bind rotations so that each points at the next, and the end bone takes its target's
//! rotation. Chains marked as ropes swing as particles instead.
//!
//! Bones the solver moves keep last frame's matrices until the solver reaches them, so a chain
//! starts from where it was.

use std::collections::HashMap;
use std::f32::consts::PI;

use crate::mat::M4;
use crate::physics::{self, Settings};
use crate::puppet::{Chain, ChainGroup, Puppet, BONE_IK};
use crate::quat::{self, M3, V3};

/// Constraint flags of a handle's constraint.
const COPY_POSITION: u32 = 1;
const ON_LINE: u32 = 2;
const RAIL: u32 = 0x1_0000;
/// Chain flags.
const TO_HANDLE: u32 = 1;
const BEND_ALWAYS: u32 = 2;
const ROPE: u32 = 4;

/// The rig of a skeleton: who constrains whom, and the state chains carry between frames.
#[derive(Debug, Clone)]
pub struct Ik {
    /// Constraints on each bone (owner not moved by inverse kinematics), in file order.
    bone_constraints: Vec<Vec<usize>>,
    /// Constraints on each handle, in file order.
    handle_constraints: Vec<Vec<usize>>,
    /// Target and pole handle of the chain ending at a bone.
    targets: HashMap<usize, usize>,
    poles: HashMap<usize, usize>,
    /// The chain group whose root each bone is.
    group_of: Vec<Option<usize>>,
    /// Bind world matrices, which solved bones turn from.
    bind: Vec<M4>,
    /// Rope particles (position, last position) per rope chain, keyed by group, entry, chain.
    ropes: HashMap<(usize, usize, usize), Vec<(V3, V3)>>,
}

impl Ik {
    /// The rig of `model`, or `None` when it has no constraints or chains. `bind` holds the bind
    /// world matrices.
    pub fn new(model: &Puppet, bind: &[M4]) -> Option<Self> {
        if model.constraints.is_empty() && model.chains.is_empty() {
            return None;
        }
        let bones = model.bones.len();
        let mut targets = HashMap::new();
        let mut poles = HashMap::new();
        for (h, handle) in model.handles.iter().enumerate() {
            match handle.kind {
                0 => {
                    let _ = targets.insert(handle.bone, h);
                }
                1 => {
                    let _ = poles.insert(handle.bone, h);
                }
                _ => {}
            }
        }
        let mut bone_constraints = vec![Vec::new(); bones];
        let mut handle_constraints = vec![Vec::new(); model.handles.len()];
        for (c, constraint) in model.constraints.iter().enumerate() {
            if model.bones[constraint.owner].flags & BONE_IK == 0 {
                bone_constraints[constraint.owner].push(c);
            } else if let Some(h) = model.handles.iter().position(|h| h.kind == 0 && h.bone == constraint.owner) {
                handle_constraints[h].push(c);
            }
        }
        let mut group_of = vec![None; bones];
        for (g, group) in model.chains.iter().enumerate() {
            group_of[group.root] = Some(g);
        }
        Some(Self { bone_constraints, handle_constraints, targets, poles, group_of, bind: bind.to_vec(), ropes: HashMap::new() })
    }

    /// Starts over (the scene restarted).
    pub fn reset(&mut self) {
        self.ropes.clear();
    }

    /// Bone `i`'s constraints, after its forward kinematics.
    pub fn constrain_bone(&self, i: usize, model: &Puppet, world: &mut [M4], weights: &[f32]) {
        for &c in &self.bone_constraints[i] {
            let k = &model.constraints[c];
            world[i] = blend(&world[i], &world[k.target], weight(weights, k.weight));
        }
    }

    /// The chain group bone `i` is the root of, if any.
    pub fn group(&self, i: usize) -> Option<usize> {
        self.group_of.get(i).copied().flatten()
    }

    /// Runs chain group `g`: its handles' constraints, its ropes and the solver.
    #[allow(clippy::too_many_arguments)]
    pub fn solve(
        &mut self,
        g: usize,
        model: &Puppet,
        settings: &[Option<Settings>],
        world: &mut [M4],
        handles: &mut [M4],
        weights: &[f32],
        dt: f32,
    ) {
        let group = &model.chains[g];
        self.constrain_handles(group, model, world, handles, weights);
        let mut solver = Solver { ik: self, model, settings, group, g, world, handles };
        solver.step_ropes(dt);
        solver.run();
    }

    fn constrain_handles(&self, group: &ChainGroup, model: &Puppet, world: &mut [M4], handles: &mut [M4], weights: &[f32]) {
        for &h in &group.handles {
            let end = model.handles[h].bone;
            for &c in &self.handle_constraints[h] {
                let k = &model.constraints[c];
                let t = world[k.target];
                let w = weight(weights, k.weight);
                let tt = row3(&t, 3);
                let ax = quat::normalize3(row3(&t, 0));
                if k.flags & RAIL != 0 {
                    for chain in chains_ending(group, end) {
                        rail(chain, model, world, &mut handles[h], &t, ax, w, k.values);
                    }
                } else if k.flags & ON_LINE != 0 {
                    for _ in chains_ending(group, end) {
                        let ht = row3(&handles[h], 3);
                        let on = quat::add(tt, quat::scale(ax, quat::dot(quat::sub(ht, tt), ax)));
                        set_row3(&mut handles[h], 3, quat::lerp(ht, on, w));
                    }
                } else if k.flags & COPY_POSITION != 0 {
                    let ht = row3(&handles[h], 3);
                    set_row3(&mut handles[h], 3, quat::lerp(ht, tt, w));
                } else {
                    handles[h] = blend(&handles[h], &t, w);
                }
            }
        }
    }
}

/// A rail: the handle slides along the target bone's x axis, at most as far as the chain reaches,
/// and the chain's joints follow it onto the rail, fading in over `values` (start, length).
#[allow(clippy::too_many_arguments)]
fn rail(chain: &Chain, model: &Puppet, world: &mut [M4], handle: &mut M4, t: &M4, ax: V3, w: f32, values: [f32; 2]) {
    let tt = row3(t, 3);
    let n = chain.bones.len();
    let d = quat::length(quat::sub(tt, pos(world, chain.bones[0])));
    let mut p = quat::dot(quat::sub(row3(handle, 3), tt), ax);
    if !(d < chain.max_length && p >= 0.0) {
        return;
    }
    let on_rail = |k: f32| {
        let mut m = *t;
        set_row3(&mut m, 3, quat::add(tt, quat::scale(ax, k)));
        m
    };
    let mut k = (chain.max_length - d).min(p);
    *handle = blend(handle, &on_rail(k), w);
    for j in (1..n.saturating_sub(1)).rev() {
        let l = length_of(model, chain.bones[j + 1]);
        p -= l;
        if p < 0.0 {
            break;
        }
        let wj = ((p - values[0]).max(0.0) / values[1]).min(1.0);
        if wj <= 0.0 {
            break;
        }
        k -= l;
        if k < 0.0 {
            break;
        }
        let b = chain.bones[j];
        world[b] = blend(&world[b], &on_rail(k), wj * w);
    }
}

/// The FABRIK solve of one chain group.
struct Solver<'a> {
    ik: &'a mut Ik,
    model: &'a Puppet,
    settings: &'a [Option<Settings>],
    group: &'a ChainGroup,
    g: usize,
    world: &'a mut [M4],
    handles: &'a mut [M4],
}

impl Solver<'_> {
    fn flags(&self, bone: usize) -> u32 {
        self.settings.get(bone).copied().flatten().map_or(0, |s| s.flags)
    }

    fn target(&self, chain: &Chain) -> V3 {
        match self.ik.targets.get(&chain.end) {
            Some(&h) if chain.flags & TO_HANDLE != 0 => row3(&self.handles[h], 3),
            _ => pos(self.world, chain.end),
        }
    }

    fn run(&mut self) {
        let group = self.group;
        let root0 = pos(self.world, group.root);
        let root_has_parent = self.model.bones[group.root].parent.is_some();
        for pass in 0..10 {
            for (e, entry) in group.entries.iter().enumerate().rev() {
                let mut sum = [0.0; 3];
                let mut count = 0.0;
                for (c, chain) in entry.chains.iter().enumerate().rev() {
                    if chain.flags & ROPE != 0 {
                        self.constrain_rope((e, c), chain);
                        continue;
                    }
                    self.backward(entry.bone, chain);
                    sum = quat::add(sum, pos(self.world, entry.bone));
                    count += 1.0;
                }
                if count > 0.0 {
                    set_pos(self.world, entry.bone, quat::scale(sum, 1.0 / count));
                }
            }
            if pass == 0 {
                self.bend();
            }
            let mut done = true;
            for (e, entry) in group.entries.iter().enumerate() {
                for (c, chain) in entry.chains.iter().enumerate() {
                    if chain.flags & ROPE != 0 {
                        self.constrain_rope((e, c), chain);
                        continue;
                    }
                    if entry.bone == group.root && root_has_parent {
                        set_pos(self.world, entry.bone, root0);
                    }
                    self.forward(chain);
                    if chain.flags & TO_HANDLE != 0 {
                        let miss = quat::sub(pos(self.world, chain.end), self.target(chain));
                        if quat::dot(miss, miss) > 0.1 {
                            done = false;
                        }
                    }
                }
            }
            if done {
                break;
            }
        }
        self.finish();
    }

    /// From the target back to the chain's base.
    fn backward(&mut self, base_bone: usize, chain: &Chain) {
        let n = chain.bones.len();
        if n < 2 {
            return;
        }
        let base = pos(self.world, base_bone);
        let mut target = self.target(chain);
        let d = quat::sub(target, base);
        let mut dist = quat::length(d);
        let dir = quat::scale(d, 1.0 / dist);
        if chain.min_length > 0.0 && dist < chain.min_length {
            target = quat::add(target, quat::scale(dir, chain.min_length - dist));
            dist = chain.min_length;
        }
        let pole = match self.ik.poles.get(&chain.end) {
            Some(&h) => {
                let p = quat::sub(row3(&self.handles[h], 3), target);
                quat::sub(p, quat::scale(dir, quat::dot(p, dir)))
            }
            None => [0.0; 3],
        };
        set_pos(self.world, chain.end, target);
        if dist < chain.max_length || chain.flags & BEND_ALWAYS != 0 {
            let m = quat::normalize3(quat::cross(dir, pole));
            let mut acc = 0.0;
            for i in (1..n).rev() {
                let (cur, prev) = (chain.bones[i], chain.bones[i - 1]);
                let mut v = quat::sub(pos(self.world, prev), pos(self.world, cur));
                if i > 1 && self.flags(prev) & physics::IK_LIMIT != 0 {
                    v = quat::scale(self.angle_limit(prev, quat::scale(v, -1.0 / quat::length(v))), -1.0);
                }
                let len = length_of(self.model, cur);
                if i == n - 1 || acc + len < 0.5 * chain.max_length {
                    if quat::dot(pole, pole) > 0.01 {
                        v = quat::sub(v, quat::scale(m, quat::dot(v, m)));
                    }
                    let t = quat::dot(v, pole);
                    if t < 0.0 {
                        // Wallpaper Engine reflects by the pole as it is, not normalised.
                        v = quat::sub(v, quat::scale(pole, 2.0 * t));
                    }
                }
                let p = quat::add(pos(self.world, cur), quat::scale(v, len / quat::length(v)));
                set_pos(self.world, prev, p);
                acc += len;
            }
        } else {
            for i in (1..n).rev() {
                let p = quat::sub(pos(self.world, chain.bones[i]), quat::scale(dir, length_of(self.model, chain.bones[i])));
                set_pos(self.world, chain.bones[i - 1], p);
            }
        }
    }

    /// From the base out again, each bone at its length from the one before.
    fn forward(&mut self, chain: &Chain) {
        for i in 0..chain.bones.len().saturating_sub(1) {
            let (a, b) = (chain.bones[i], chain.bones[i + 1]);
            let mut u = quat::normalize3(quat::sub(pos(self.world, b), pos(self.world, a)));
            if i > 0 && self.flags(a) & physics::IK_LIMIT != 0 {
                u = self.angle_limit(a, u);
            }
            let p = quat::add(pos(self.world, a), quat::scale(u, length_of(self.model, b)));
            set_pos(self.world, b, p);
        }
    }

    /// Holds direction `u` out of bone `b` within the bone's angle limits, measured in the xy
    /// plane from the direction its parent points it in.
    fn angle_limit(&self, b: usize, u: V3) -> V3 {
        let Some(parent) = self.model.bones[b].parent else { return u };
        let Some(s) = self.settings.get(b).copied().flatten() else { return u };
        let pd = quat::normalize3(quat::sub(pos(self.world, b), pos(self.world, parent)));
        let m = quat::matrix(quat::rotation([1.0, 0.0, 0.0], pd));
        let len = (u[0] * u[0] + u[1] * u[1]).sqrt();
        let l = quat::apply([u[0] / len, u[1] / len, 0.0], &transpose(&m));
        let angle = l[1].atan2(l[0]);
        let [lo, hi] = s.ik_limits;
        let below = (angle < lo).then_some(lo - angle);
        let above = (angle > hi).then_some(hi - angle);
        let fix = match (below, above) {
            (Some(a), Some(b)) => if b.abs() < a.abs() { b } else { a },
            (Some(a), None) => a,
            (None, Some(b)) => b,
            (None, None) => 0.0,
        };
        let (sin, cos) = fix.sin_cos();
        let rz = [[cos, sin, 0.0], [-sin, cos, 0.0], [0.0, 0.0, 1.0]];
        let out = quat::apply(quat::apply(l, &rz), &m);
        [out[0] * len, out[1] * len, u[2]]
    }

    /// On the first pass, a chain held on a rail folds its joints back to the side the rail lies
    /// on, so it does not bend the wrong way along it.
    fn bend(&mut self) {
        let group = self.group;
        for &h in &group.handles {
            let end = self.model.handles[h].bone;
            for &c in &self.ik.handle_constraints[h] {
                let k = self.model.constraints[c];
                if k.flags & RAIL == 0 {
                    continue;
                }
                let t = self.world[k.target];
                let ax = row3(&t, 0);
                for chain in chains_ending(group, end) {
                    let n = chain.bones.len();
                    let d0 = quat::length(quat::sub(row3(&t, 3), pos(self.world, chain.bones[0])));
                    let mut d = d0;
                    let mut i = 1;
                    let mut budget = 32;
                    while budget > 0 && n > 2 {
                        d -= length_of(self.model, chain.bones[i]);
                        if d < 0.0 {
                            break;
                        }
                        let before = pos(self.world, chain.bones[i - 1]);
                        let u = quat::sub(pos(self.world, chain.bones[i + 1]), before);
                        let nv = quat::cross(quat::cross(u, ax), u);
                        if quat::dot(nv, nv) >= 0.01 {
                            let nn = quat::normalize3(nv);
                            let joint = pos(self.world, chain.bones[i]);
                            let off = quat::dot(quat::sub(joint, before), nn);
                            if off > f32::EPSILON {
                                set_pos(self.world, chain.bones[i], quat::sub(joint, quat::scale(nn, 2.0 * off)));
                                d = d0;
                                i = 1;
                            }
                        }
                        budget -= 1;
                        if i + 2 >= n {
                            break;
                        }
                        i += 1;
                    }
                }
            }
        }
    }

    /// Turns the solved bones: each from its bind rotation so that it points at the next bone,
    /// and the end bone as its target handle is turned.
    fn finish(&mut self) {
        let group = self.group;
        for entry in &group.entries {
            let several = entry.chains.len() > 1;
            for chain in &entry.chains {
                let n = chain.bones.len();
                for i in usize::from(several)..n.saturating_sub(1) {
                    let (a, b) = (chain.bones[i], chain.bones[i + 1]);
                    let dir = quat::normalize3(quat::sub(pos(self.world, b), pos(self.world, a)));
                    if let Some(rest) = self.rest_direction(a, b) {
                        self.turn_from_bind(a, quat::rotation(rest, dir));
                    }
                }
                if chain.flags & TO_HANDLE != 0 {
                    self.turn_end(chain);
                }
            }
            if several {
                let k = entry.chains.len() as f32;
                let mut q = quat::IDENTITY;
                for chain in &entry.chains {
                    let Some(&next) = chain.bones.get(1) else { continue };
                    let dir = quat::normalize3(quat::sub(pos(self.world, next), pos(self.world, entry.bone)));
                    if let Some(rest) = self.rest_direction(entry.bone, next) {
                        q = quat::slerp(q, quat::rotation(rest, dir), 1.0 / k);
                    }
                }
                self.turn_from_bind(entry.bone, q);
            }
        }
    }

    fn rest_direction(&self, bone: usize, child: usize) -> Option<V3> {
        self.model.rest_directions.get(bone)?.iter().find(|(c, _)| *c == child).map(|(_, d)| *d)
    }

    /// Sets bone `b`'s axes to its bind axes turned by `q` in model space.
    fn turn_from_bind(&mut self, b: usize, q: quat::Quat) {
        let rows = quat::mul3(&rows3(&self.ik.bind[b]), &quat::matrix(q));
        set_rows3(&mut self.world[b], &rows);
    }

    fn turn_end(&mut self, chain: &Chain) {
        let end = chain.end;
        let s = self.settings.get(end).copied().flatten().unwrap_or_default();
        if s.flags & physics::IK_FREE_END != 0 {
            let n = chain.bones.len();
            if n > 2 {
                let rows = rows3(&self.world[chain.bones[n - 2]]);
                set_rows3(&mut self.world[end], &rows);
            }
            return;
        }
        let Some(&h) = self.ik.targets.get(&end) else { return };
        let mut rows = rows3(&self.handles[h]).map(|r| quat::scale(r, fast_rsqrt(quat::dot(r, r))));
        let d = quat::sub(row3(&self.handles[h], 3), pos(self.world, end));
        let dd = quat::dot(d, d);
        if s.flags & physics::IK_REACH != 0 && dd > 1.0 {
            let len = dd.sqrt();
            let w = ((len - 1.0) / s.ik_reach).min(1.0);
            let towards = quat::rotation([1.0, 0.0, 0.0], quat::scale(d, 1.0 / len));
            rows = quat::matrix(quat::slerp(quat::from_matrix(&rows), towards, w));
        }
        set_rows3(&mut self.world[end], &rows);
    }

    /// Moves the group's rope particles on by `dt`: pinned at the root and (unless the end is
    /// free) at the target, swinging under gravity in between.
    fn step_ropes(&mut self, dt: f32) {
        let group = self.group;
        for (e, entry) in group.entries.iter().enumerate() {
            for (c, chain) in entry.chains.iter().enumerate() {
                if chain.flags & ROPE == 0 || chain.bones.len() < 2 {
                    continue;
                }
                let end_settings = self.settings.get(chain.end).copied().flatten().unwrap_or_default();
                let root = pos(self.world, chain.bones[0]);
                let mut target = self.target(chain);
                if end_settings.flags & physics::IK_STRETCH == 0 {
                    let d = quat::sub(target, root);
                    let len = quat::length(d);
                    if len > chain.max_length && len > 0.0 {
                        target = quat::add(root, quat::scale(d, chain.max_length / len));
                    }
                }
                let world = &*self.world;
                let particles = self
                    .ik
                    .ropes
                    .entry((self.g, e, c))
                    .or_insert_with(|| chain.bones.iter().map(|&b| (pos(world, b), pos(world, b))).collect());
                let last = particles.len() - 1;
                particles[0] = (root, root);
                if end_settings.flags & physics::IK_FREE_END == 0 {
                    particles[last] = (target, target);
                }
                for (i, (p, prev)) in particles.iter_mut().enumerate().take(last).skip(1) {
                    let s = self.settings.get(chain.bones[i]).copied().flatten().unwrap_or_default();
                    let mut x = quat::sub(quat::scale(*p, 2.0), *prev);
                    let back = quat::sub(*prev, *p);
                    if s.friction > 0.01 && quat::dot(back, back) > 1e-4 {
                        x = quat::add(x, quat::scale(back, s.friction));
                    }
                    if s.flags & physics::GRAVITY != 0 {
                        // Our model space is y up, like Wallpaper Engine's gravity direction.
                        x = quat::add(x, quat::scale(s.gravity, s.mass * dt * dt));
                    }
                    *prev = *p;
                    *p = x;
                }
            }
        }
    }

    /// Keeps neighbouring rope particles their bone length apart and places the bones on them.
    fn constrain_rope(&mut self, key: (usize, usize), chain: &Chain) {
        let Some(particles) = self.ik.ropes.get_mut(&(self.g, key.0, key.1)) else { return };
        for i in 0..particles.len().saturating_sub(1) {
            let want = length_of(self.model, chain.bones[i + 1]);
            let d = quat::sub(particles[i + 1].0, particles[i].0);
            let len = quat::length(d);
            let dir = if len < 0.01 { [0.707, 0.707, 0.0] } else { quat::scale(d, 1.0 / len) };
            let error = len - want;
            if error.abs() > 0.001 {
                let fix = quat::scale(dir, error * 0.5);
                particles[i].0 = quat::add(particles[i].0, fix);
                particles[i + 1].0 = quat::sub(particles[i + 1].0, fix);
            }
        }
        for (i, &b) in chain.bones.iter().enumerate() {
            if i > 0 {
                set_pos(self.world, b, particles[i].0);
            }
        }
    }
}

fn chains_ending(group: &ChainGroup, end: usize) -> impl Iterator<Item = &Chain> {
    group.entries.iter().flat_map(|e| &e.chains).filter(move |c| c.end == end)
}

/// Wallpaper Engine's blend of two transforms: Euler angles (wrapped, and with a half turn taken
/// off when the second is more than a half turn ahead), axis lengths and translations each
/// interpolated by `w`.
pub fn blend(x: &M4, y: &M4, w: f32) -> M4 {
    let ex = quat::extract_euler(&rows3(x)).map(|a| a % (2.0 * PI));
    let mut ey = quat::extract_euler(&rows3(y)).map(|a| a % (2.0 * PI));
    for k in 0..3 {
        if ey[k] - ex[k] > PI {
            ey[k] -= PI;
        }
    }
    let r = quat::euler_matrix(quat::lerp(ex, ey, w));
    let len4 = |m: &M4, k: usize| m[k].iter().map(|v| v * v).sum::<f32>().sqrt();
    let t = quat::lerp(row3(x, 3), row3(y, 3), w);
    let mut out = [[0.0; 4]; 4];
    for k in 0..3 {
        let s = len4(x, k) + (len4(y, k) - len4(x, k)) * w;
        out[k] = [r[k][0] * s, r[k][1] * s, r[k][2] * s, 0.0];
    }
    out[3] = [t[0], t[1], t[2], 1.0];
    out
}

fn weight(weights: &[f32], i: usize) -> f32 {
    weights.get(i).copied().unwrap_or(0.0)
}

fn length_of(model: &Puppet, bone: usize) -> f32 {
    model.lengths.get(bone).copied().unwrap_or(0.0)
}

fn row3(m: &M4, r: usize) -> V3 {
    [m[r][0], m[r][1], m[r][2]]
}

fn set_row3(m: &mut M4, r: usize, v: V3) {
    m[r][0] = v[0];
    m[r][1] = v[1];
    m[r][2] = v[2];
}

fn rows3(m: &M4) -> M3 {
    [row3(m, 0), row3(m, 1), row3(m, 2)]
}

fn set_rows3(m: &mut M4, rows: &M3) {
    for (r, row) in rows.iter().enumerate() {
        set_row3(m, r, *row);
    }
}

fn pos(world: &[M4], b: usize) -> V3 {
    row3(&world[b], 3)
}

fn set_pos(world: &mut [M4], b: usize, p: V3) {
    set_row3(&mut world[b], 3, p);
}

fn transpose(m: &M3) -> M3 {
    std::array::from_fn(|i| std::array::from_fn(|j| m[j][i]))
}

/// The fast inverse square root Wallpaper Engine normalises the end bone's axes with: the bit
/// trick with seed `0x5f375a86` and one Newton step.
fn fast_rsqrt(x: f32) -> f32 {
    let y = f32::from_bits(0x5f37_5a86 - (x.to_bits() >> 1));
    y * (1.5 - 0.5 * x * y * y)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mat;
    use crate::puppet::{Bone, ChainEntry, Constraint, Handle};

    /// A base bone and three bones in a row along x, 100 apart, the last two moved by a chain from
    /// bone 1 (pinned by its parent) to a target handle.
    fn arm(target: V3) -> (Puppet, Vec<M4>, Vec<M4>) {
        let at = |x: f32| {
            let mut m = mat::IDENTITY;
            m[3][0] = x;
            m
        };
        let bone = |parent: Option<usize>, x: f32, flags: u32| Bone { parent, local: at(x), flags, ..Bone::default() };
        let mut handle = mat::IDENTITY;
        set_row3(&mut handle, 3, target);
        let model = Puppet {
            bones: vec![bone(None, 0.0, 0), bone(Some(0), 0.0, 0), bone(Some(1), 100.0, BONE_IK), bone(Some(2), 100.0, BONE_IK)],
            handles: vec![Handle { bone: 3, kind: 0, matrix: handle, ..Handle::default() }],
            lengths: vec![0.0, 0.0, 100.0, 100.0],
            rest_directions: vec![vec![], vec![(2, [1.0, 0.0, 0.0])], vec![(3, [1.0, 0.0, 0.0])], vec![]],
            chains: vec![ChainGroup {
                root: 1,
                handles: vec![0],
                entries: vec![ChainEntry {
                    bone: 1,
                    chains: vec![Chain { end: 3, flags: TO_HANDLE, max_length: 200.0, min_length: 0.0, bones: vec![1, 2, 3] }],
                }],
            }],
            ..Puppet::default()
        };
        let world = vec![at(0.0), at(0.0), at(100.0), at(200.0)];
        (model, world.clone(), vec![handle])
    }

    #[test]
    fn a_chain_reaches_its_target() {
        let target = [100.0, 100.0, 0.0];
        let (model, mut world, mut handles) = arm(target);
        let mut ik = Ik::new(&model, &world.clone()).expect("a rig");
        ik.solve(0, &model, &[None; 4], &mut world, &mut handles, &[], 1.0 / 60.0);
        let end = pos(&world, 3);
        assert!(quat::length(quat::sub(end, target)) < 0.5, "{end:?}");
        assert!((quat::length(quat::sub(pos(&world, 2), pos(&world, 1))) - 100.0).abs() < 0.5);
        // The middle bone points at the end.
        let dir = quat::normalize3(quat::sub(end, pos(&world, 2)));
        assert!(quat::dot(quat::normalize3(row3(&world[2], 0)), dir) > 0.999, "{:?}", world[2]);
    }

    #[test]
    fn a_target_out_of_reach_straightens_the_chain() {
        let target = [0.0, 500.0, 0.0];
        let (model, mut world, mut handles) = arm(target);
        let mut ik = Ik::new(&model, &world.clone()).expect("a rig");
        ik.solve(0, &model, &[None; 4], &mut world, &mut handles, &[], 1.0 / 60.0);
        // The pinned root stays; the chain points straight at the target.
        assert!(quat::length(pos(&world, 1)) < 1e-3, "{:?}", world[1]);
        let end = pos(&world, 3);
        assert!(quat::length(quat::sub(end, [0.0, 200.0, 0.0])) < 0.5, "{end:?}");
    }

    #[test]
    fn a_bone_constraint_follows_its_target_by_weight() {
        let (mut model, mut world, _) = arm([0.0; 3]);
        model.bones[3].flags = 0;
        model.chains.clear();
        model.constraints = vec![Constraint { owner: 3, weight: 0, target: 0, ..Constraint::default() }];
        let ik = Ik::new(&model, &world.clone()).expect("a rig");
        ik.constrain_bone(3, &model, &mut world, &[0.5]);
        assert!((world[3][3][0] - 100.0).abs() < 1e-3, "{:?}", world[3]);
    }

    #[test]
    fn blend_mixes_rotation_scale_and_translation() {
        let a = mat::from_trs([0.0; 3], [0.0, 0.0, 0.2], [1.0; 3]);
        let b = mat::from_trs([10.0, 0.0, 0.0], [0.0, 0.0, 0.6], [3.0, 3.0, 1.0]);
        let m = blend(&a, &b, 0.5);
        let expected = mat::from_trs([5.0, 0.0, 0.0], [0.0, 0.0, 0.4], [2.0, 2.0, 1.0]);
        assert!(m.as_flattened().iter().zip(expected.as_flattened()).all(|(x, y)| (x - y).abs() < 1e-4), "{m:?}");
    }
}
