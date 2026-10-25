//! The simulation: instances of a particle file and its children, stepped at a fixed rate.
//!
//! A step (in this order): age every particle and free the ones past their lifetime, start event
//! children for the dead, move the control points, emit (each new particle gets its emitter's
//! position and velocity, then every initializer in file order), run the operators over all
//! particles, record trail history; then the children step. Only the `movement` operator moves
//! particles: a system without it keeps them where they were born.
//!
//! Slots: particles live in slots up to a high-water mark; a slot with lifetime 0 is free and is
//! reused first-free, so the draw order is the slot order, like the engine's.

use super::model::{
    ChildKind, Definition, EmitterShape, Initializer, CP_PARENT, CP_PARENT_RAW, CP_POINTER,
    CP_WORLD_OFFSET, EMIT_ONE_PER_STEP, EMIT_PERIODIC, EMIT_SIGN,
};
use super::operators::{self, OpFrame};
use super::overrides::InstanceOverride;
use super::{
    hsv_to_rgb, noise, Affine, Rng, Vec3, CONTROL_POINTS, FIXED_DT, MAX_PARTICLES_PER_SYSTEM, PI,
    TAU,
};

/// Child systems nest at most this deep.
const MAX_DEPTH: usize = 10;

/// `1 / FIXED_DT`.
const STEPS_PER_SECOND: f64 = 60.0;

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Particle {
    pub position: Vec3,
    pub velocity: Vec3,
    /// Position before this step's movement (collisions and attractors test the path).
    pub prev_position: Vec3,
    pub rotation: Vec3,
    pub angular_velocity: Vec3,
    pub color: Vec3,
    pub alpha: f32,
    pub size: f32,
    /// Spawn values; every operator pass starts again from these.
    pub init_color: Vec3,
    pub init_alpha: f32,
    pub init_size: f32,
    pub age: f32,
    /// Seconds; 0 marks a free slot.
    pub lifetime: f32,
    /// Sprite sheet position: life fraction times the sequence multiplier, or a fixed random
    /// value for random frames. The shader takes its fraction.
    pub frame: f32,
    /// Per-particle random value, drawn once; oscillators derive their parameters from it.
    pub random: f32,
}

impl Particle {
    pub fn alive(&self) -> bool {
        self.lifetime != 0.0
    }

    pub fn life_fraction(&self) -> f32 {
        if self.lifetime > 0.0 {
            self.age / self.lifetime
        } else {
            1.0
        }
    }
}

/// One particle file of a system, with the overrides applied, and where its children are.
#[derive(Debug, Clone)]
pub struct Node {
    /// As parsed.
    pub base: Definition,
    /// With the instance overrides applied.
    pub def: Definition,
    /// Colour every particle starts with.
    pub tint: Vec3,
    /// Node index per entry of `def.children`; `None` when its file could not be loaded.
    pub children: Vec<Option<usize>>,
}

/// A particle file and all the child files it refers to, flattened; node 0 is the root.
#[derive(Debug, Clone)]
pub struct Tree {
    pub nodes: Vec<Node>,
}

impl Tree {
    /// Loads the children of `root` through `load` (a child path to its parsed file), up to the
    /// engine's nesting limit.
    pub fn new(root: Definition, load: &mut dyn FnMut(&str) -> Option<Definition>) -> Self {
        let mut tree = Self { nodes: Vec::new() };
        tree.add(root, load, 0);
        tree
    }

    fn add(
        &mut self,
        def: Definition,
        load: &mut dyn FnMut(&str) -> Option<Definition>,
        depth: usize,
    ) -> usize {
        let index = self.nodes.len();
        let names: Vec<String> = def.children.iter().map(|c| c.name.clone()).collect();
        self.nodes.push(Node {
            def: def.clone(),
            base: def,
            tint: Vec3::ONE,
            children: Vec::new(),
        });
        let children = names
            .iter()
            .map(|name| {
                if depth + 1 >= MAX_DEPTH {
                    return None;
                }
                load(name).map(|child| self.add(child, load, depth + 1))
            })
            .collect();
        self.nodes[index].children = children;
        index
    }

    fn apply(&mut self, overrides: &InstanceOverride) {
        for node in &mut self.nodes {
            node.def = overrides.apply(&node.base);
            node.tint = overrides.tint_for(&node.base);
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct EmitterState {
    accumulator: f32,
    duration: f32,
    delay: f32,
    /// Burst particles still to emit.
    pending: u32,
    emitted_in_period: u32,
    /// Positive while a period emits, negative while it pauses.
    timer: f32,
    disabled: bool,
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct ControlPointState {
    pub current: Affine,
    pub previous: Affine,
    /// Set by the parent's particles; the instance leaves it alone.
    pub driven: bool,
    /// Set by a remap operator.
    pub written: bool,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct Trails {
    /// `segments` past positions per slot, newest first.
    pub history: Vec<Vec3>,
    pub counts: Vec<u16>,
    pub scroll: Vec<u16>,
    pub segments: usize,
    pub interval: f32,
    pub timer: f32,
}

/// One entry of the parent's `children`: the systems it started.
#[derive(Debug, Clone, Default)]
pub struct ChildGroup {
    pub link: usize,
    pub instances: Vec<Instance>,
    /// Finished event systems, kept for reuse.
    pool: Vec<Instance>,
}

/// One running copy of a particle file.
#[derive(Debug, Clone, Default)]
pub struct Instance {
    pub node: usize,
    /// Slots up to the high-water mark.
    pub particles: Vec<Particle>,
    pub alive: usize,
    /// Where the instance sits, in scene space: the layer, then each child's offset.
    pub placement: Affine,
    /// Live slots in spawn order, for the rope renderer.
    pub rope: Vec<u32>,
    /// Particles removed from `rope` so far (scrolls the rope's texture).
    pub removed: u32,
    pub(crate) trails: Trails,
    pub children: Vec<ChildGroup>,
    emitters: Vec<EmitterState>,
    /// Per initializer: a sequence initializer's position and signed step.
    sequences: Vec<(f32, f32)>,
    pub(crate) control_points: [ControlPointState; CONTROL_POINTS],
    /// For event children: the parent's slot that started it, while that particle lives.
    pub parent_particle: Option<usize>,
    suppressed: bool,
    /// Prewarming: no event children are started.
    quiet: bool,
    died: Vec<usize>,
    spawned: Vec<usize>,
    /// Positions and velocities for operators that read other particles.
    scratch: Vec<(Vec3, Vec3)>,
}

/// What a frame passes down to every instance.
pub(crate) struct Frame<'a> {
    pub nodes: &'a [Node],
    pub time: f32,
    pub time_of_day: f32,
    /// The pointer in scene space.
    pub pointer: Vec3,
    pub audio: &'a [f32],
    pub canvas: [f32; 2],
    pub overrides: &'a InstanceOverride,
}

/// What a child reads from its parent.
#[derive(Clone, Copy)]
pub(crate) struct Parent<'a> {
    pub particles: &'a [Particle],
    pub control_points: &'a [ControlPointState; CONTROL_POINTS],
    pub world_space: bool,
    pub placement: Affine,
}

impl Instance {
    fn new(node: usize, nodes: &[Node], placement: Affine) -> Self {
        let def = &nodes[node].def;
        let mut inst = Self {
            node,
            placement,
            children: def
                .children
                .iter()
                .enumerate()
                .map(|(link, _)| ChildGroup {
                    link,
                    ..ChildGroup::default()
                })
                .collect(),
            ..Self::default()
        };
        inst.reset(nodes);
        inst
    }

    /// Clears all particles, child systems and control points and restarts the emitters.
    fn reset(&mut self, nodes: &[Node]) {
        let def = &nodes[self.node].def;
        self.particles.clear();
        self.particles
            .reserve(def.max_count.min(MAX_PARTICLES_PER_SYSTEM));
        self.alive = 0;
        self.rope.clear();
        self.removed = 0;
        self.restart_emitters(def);
        self.sequences = def
            .initializers
            .iter()
            .map(|i| (0.0, i.sequence_step()))
            .collect();
        self.trails = match def.trail() {
            Some((length, segments)) => Trails {
                segments: segments as usize,
                interval: length / segments as f32,
                ..Trails::default()
            },
            None => Trails::default(),
        };
        for group in &mut self.children {
            group.pool.append(&mut group.instances);
        }
        self.control_points = Default::default();
        self.parent_particle = None;
    }

    fn restart_emitters(&mut self, def: &Definition) {
        self.emitters = def
            .emitters
            .iter()
            .map(|e| EmitterState {
                duration: e.duration,
                delay: e.delay,
                pending: e.instantaneous,
                ..EmitterState::default()
            })
            .collect();
    }

    fn emitting(&self) -> bool {
        self.emitters.iter().any(|e| !e.disabled)
    }

    /// No particles, no emitters running and no child systems left.
    fn finished(&self) -> bool {
        self.alive == 0 && !self.emitting() && self.children.iter().all(|g| g.instances.is_empty())
    }

    /// Simulates `start_time` seconds in coarse steps, without starting event children.
    fn prewarm(&mut self, frame: &Frame, rng: &mut Rng) {
        let def = &frame.nodes[self.node].def;
        if def.start_time <= 0.0 {
            return;
        }
        let h = def.prewarm_step();
        let mut t = 0.0;
        self.quiet = true;
        while t < def.start_time {
            self.step(frame, rng, h, true, None);
            t += h;
        }
        self.quiet = false;
        // Trails start out collapsed onto their particles.
        let segments = self.trails.segments;
        for (slot, p) in self.particles.iter().enumerate() {
            if p.alive() && segments > 0 {
                self.trails.history[slot * segments..(slot + 1) * segments].fill(p.position);
            }
        }
    }

    /// Advances by `dt`: the step, then every child system.
    fn update(
        &mut self,
        frame: &Frame,
        rng: &mut Rng,
        dt: f32,
        emit: bool,
        parent: Option<Parent>,
    ) {
        let mut period_started = false;
        if dt > 0.0 {
            period_started = self.step(frame, rng, dt, emit, parent);
        }
        let def = &frame.nodes[self.node].def;
        let Self {
            particles,
            control_points,
            children,
            placement,
            suppressed,
            ..
        } = self;
        let me = Parent {
            particles,
            control_points,
            world_space: def.world_space(),
            placement: *placement,
        };
        for group in children.iter_mut() {
            let link = &def.children[group.link];
            let Some(node) = frame.nodes[self.node].children[group.link] else {
                continue;
            };
            for child in &mut group.instances {
                child.suppressed = *suppressed || !emit;
                if link.kind == ChildKind::Static {
                    child.placement = placement.mul(&link.offset);
                    if link.flags & 2 != 0 && period_started {
                        child.restart_emitters(&frame.nodes[node].def);
                    }
                }
                child.follow(link.kind, link.offset, &me);
                if link.flags & 1 != 0 {
                    child.drive_control_points(&me, link.control_point_start, &frame.nodes[node].def);
                }
                child.update(frame, rng, dt, emit, Some(me));
            }
            if link.kind != ChildKind::Static {
                // Finished event systems go back to the pool.
                let mut i = 0;
                while i < group.instances.len() {
                    if group.instances[i].finished() {
                        group.pool.push(group.instances.swap_remove(i));
                    } else {
                        i += 1;
                    }
                }
            }
        }
    }

    /// Re-places a following child on its parent particle; detaches it when that particle died.
    fn follow(&mut self, kind: ChildKind, offset: Affine, parent: &Parent) {
        let Some(slot) = self.parent_particle else {
            return;
        };
        match parent.particles.get(slot).filter(|p| p.alive()) {
            Some(p) if kind == ChildKind::EventFollow => {
                self.placement = parent_space(parent)
                    .mul(&Affine::translation(p.position))
                    .mul(&offset);
            }
            Some(_) => {}
            None => {
                self.parent_particle = None;
                if kind == ChildKind::EventFollow {
                    self.disable_all();
                }
            }
        }
    }

    /// Puts the parent's live particles, in slot order, on this system's control points from
    /// `start` on, up to the first control point that positions itself.
    fn drive_control_points(&mut self, parent: &Parent, start: usize, def: &Definition) {
        let to_space = if def.world_space() {
            Affine::IDENTITY
        } else {
            self.placement.inverse()
        };
        let from = parent_space(parent);
        let mut live = parent.particles.iter().filter(|p| p.alive());
        for i in start..CONTROL_POINTS {
            if def.control_points[i].flags & (CP_POINTER | CP_PARENT) != 0 {
                break;
            }
            let Some(p) = live.next() else {
                break;
            };
            let state = &mut self.control_points[i];
            state.current = Affine::translation(to_space.point(from.point(p.position)));
            state.driven = true;
        }
    }

    /// Stops this system's and its children's emitters; the particles live out their lives.
    fn disable_all(&mut self) {
        for e in &mut self.emitters {
            e.disabled = true;
        }
        for group in &mut self.children {
            for child in &mut group.instances {
                child.disable_all();
            }
        }
    }

    /// One simulation step; returns whether a period of emission started.
    fn step(
        &mut self,
        frame: &Frame,
        rng: &mut Rng,
        dt: f32,
        emit: bool,
        parent: Option<Parent>,
    ) -> bool {
        let node = &frame.nodes[self.node];
        let def = &node.def;

        // Age; free the particles past their lifetime.
        self.died.clear();
        for (slot, p) in self.particles.iter_mut().enumerate() {
            if !p.alive() {
                continue;
            }
            p.age += dt;
            if p.lifetime < p.age {
                p.lifetime = 0.0;
                self.alive -= 1;
                self.died.push(slot);
            }
        }
        if !def.random_frame {
            let multiplier = def.sequence_multiplier;
            for p in self.particles.iter_mut().filter(|p| p.alive()) {
                p.frame = p.age / p.lifetime * multiplier;
            }
        }
        if !self.died.is_empty() && !self.rope.is_empty() {
            let before = self.rope.len();
            let particles = &self.particles;
            self.rope.retain(|&slot| particles[slot as usize].alive());
            self.removed = self.removed.wrapping_add((before - self.rope.len()) as u32);
        }
        if !self.quiet {
            self.start_death_children(frame, rng);
        }

        self.update_control_points(frame, def, parent);

        let mut period_started = false;
        if emit && !self.suppressed {
            period_started = self.emit(frame, def, rng, dt, parent);
            if !self.quiet && !self.spawned.is_empty() {
                self.start_spawn_children(frame, rng);
            }
        }

        let op_frame = OpFrame {
            def,
            dt,
            time: frame.time,
            time_of_day: frame.time_of_day,
            audio: frame.audio,
            canvas: frame.canvas,
            model: self.placement,
            world_space: def.world_space(),
            parent: parent
                .zip(self.parent_particle)
                .and_then(|(p, slot)| p.particles.get(slot).filter(|q| q.alive())),
        };
        operators::run(
            &op_frame,
            &mut self.particles,
            &mut self.control_points,
            &mut self.scratch,
        );

        self.sample_trails(dt);
        for cp in &mut self.control_points {
            cp.previous = cp.current;
        }
        period_started
    }

    /// Records each particle's position into its trail every `interval` seconds.
    fn sample_trails(&mut self, dt: f32) {
        let trails = &mut self.trails;
        if trails.segments == 0 {
            return;
        }
        trails.timer -= dt;
        if trails.timer > 0.0 {
            return;
        }
        trails.timer = trails.interval;
        let s = trails.segments;
        for (slot, p) in self.particles.iter().enumerate() {
            if !p.alive() {
                continue;
            }
            let h = &mut trails.history[slot * s..(slot + 1) * s];
            h.copy_within(0..s - 1, 1);
            h[0] = p.position;
            trails.counts[slot] = (trails.counts[slot] + 1).min(s as u16);
            trails.scroll[slot] = trails.scroll[slot].wrapping_add(1);
        }
    }

    fn update_control_points(&mut self, frame: &Frame, def: &Definition, parent: Option<Parent>) {
        let world = def.world_space();
        let to_space = if world {
            Affine::IDENTITY
        } else {
            self.placement.inverse()
        };
        for (i, cp) in def.control_points.iter().enumerate() {
            let state = &mut self.control_points[i];
            if state.driven || state.written {
                continue;
            }
            // Scene overrides move a control point that nothing else positions.
            let overridable = cp.flags & (CP_POINTER | CP_PARENT) == 0;
            let offset = frame.overrides.control_points[i]
                .filter(|_| overridable)
                .unwrap_or(cp.offset);
            let local = match frame.overrides.control_point_angles[i].filter(|_| overridable) {
                Some(angles) => Affine::from_trs(offset, angles, Vec3::ONE),
                None => Affine::translation(offset),
            };
            state.current = if cp.flags & CP_POINTER != 0 {
                let mut pointer = frame.pointer;
                if world {
                    pointer.z = 0.0;
                }
                Affine {
                    translation: to_space.point(pointer),
                    ..local
                }
            } else if let Some(parent) = parent.filter(|_| cp.flags & CP_PARENT != 0) {
                let theirs = parent.control_points[cp.parent].current;
                if cp.flags & CP_PARENT_RAW != 0 {
                    theirs
                } else {
                    to_space.mul(&parent_space(&parent)).mul(&theirs)
                }
            } else if world {
                if cp.flags & CP_WORLD_OFFSET != 0 && i != 0 {
                    local
                } else {
                    self.placement.mul(&local)
                }
            } else if cp.flags & CP_WORLD_OFFSET != 0 {
                to_space.mul(&local)
            } else {
                local
            };
        }
    }

    /// Runs every emitter for one step; returns whether a period started.
    fn emit(
        &mut self,
        frame: &Frame,
        def: &Definition,
        rng: &mut Rng,
        dt: f32,
        parent: Option<Parent>,
    ) -> bool {
        self.spawned.clear();
        let mut period_started = false;
        let mut cursor = 0usize;
        for (index, e) in def.emitters.iter().enumerate() {
            let periodic = e.flags & EMIT_PERIODIC != 0;
            let mut count = 0u32;
            {
                let st = &mut self.emitters[index];
                if self.alive < def.max_count && !st.disabled && st.delay <= 0.0 {
                    let mut rate = e.rate * e.audio.factor(frame.audio);
                    if periodic {
                        if st.timer > 0.0 {
                            st.timer -= dt;
                            if st.timer < 0.0 {
                                st.timer = -e.periodic_delay.at(rng.f32());
                            }
                        } else {
                            st.timer += dt;
                            if st.timer < 0.0 {
                                rate = 0.0;
                            } else {
                                st.pending = e.instantaneous;
                                st.emitted_in_period = 0;
                                st.timer = e.periodic_duration.at(rng.f32());
                                period_started = true;
                            }
                        }
                    }
                    count = st.pending;
                    st.pending = 0;
                    st.accumulator += rate * dt;
                    if st.accumulator >= 1.0 && st.duration >= 0.0 {
                        let mut n = st.accumulator.floor();
                        // A burst also comes out of the accumulator, which can then stay
                        // negative for a while.
                        st.accumulator -= n + count as f32;
                        if e.flags & EMIT_ONE_PER_STEP != 0 {
                            n = n.min(1.0);
                        }
                        let mut n = n as u32;
                        if periodic && e.max_per_period > 0 {
                            n = n.min(e.max_per_period.saturating_sub(st.emitted_in_period));
                            st.emitted_in_period += n;
                        }
                        count += n;
                    } else {
                        st.accumulator -= count as f32;
                    }
                }
            }
            let room = def.max_count.saturating_sub(self.alive);
            for _ in 0..(count as usize).min(room) {
                match self.spawn(frame, def, rng, index, &mut cursor, parent) {
                    Some(slot) => self.spawned.push(slot),
                    None => break,
                }
            }
            let st = &mut self.emitters[index];
            if st.delay > 0.0 {
                st.delay -= dt;
            } else if st.duration > 0.0 {
                st.duration -= dt;
                if st.duration <= 0.0 {
                    st.duration = -1.0;
                    st.disabled = true;
                }
            } else if e.rate <= 0.0 && !(e.instantaneous != 0 && periodic) {
                st.disabled = true;
            }
        }
        if period_started {
            // Sequences flagged so start over with each period.
            for (init, seq) in def.initializers.iter().zip(&mut self.sequences) {
                let resets = match init {
                    Initializer::MapAround { flags, .. } => flags & 2 != 0,
                    Initializer::MapBetween { flags, .. } => flags & 0x20 != 0,
                    _ => false,
                };
                if resets {
                    seq.0 = 0.0;
                }
            }
        }
        period_started
    }

    /// Takes the first free slot at or after `cursor` and initialises a particle in it.
    fn spawn(
        &mut self,
        frame: &Frame,
        def: &Definition,
        rng: &mut Rng,
        emitter: usize,
        cursor: &mut usize,
        parent: Option<Parent>,
    ) -> Option<usize> {
        while *cursor < self.particles.len() && self.particles[*cursor].alive() {
            *cursor += 1;
        }
        let slot = *cursor;
        if slot == self.particles.len() {
            if slot >= def.max_count {
                return None;
            }
            self.particles.push(Particle::default());
            let s = self.trails.segments;
            if s > 0 {
                self.trails.history.resize((slot + 1) * s, Vec3::ZERO);
                self.trails.counts.push(0);
                self.trails.scroll.push(0);
            }
        }
        self.alive += 1;
        let node = &frame.nodes[self.node];
        let random = rng.f32();
        let mut p = Particle {
            lifetime: 1.0,
            init_size: 0.5,
            init_color: node.tint,
            init_alpha: frame.overrides.alpha(),
            random,
            frame: if def.random_frame { random } else { 0.0 },
            ..Particle::default()
        };
        let e = &def.emitters[emitter];
        let cp = self.control_points[e.control_point].current;
        let rotation = if def.world_space() || e.control_point != 0 {
            cp.linear()
        } else {
            Affine::IDENTITY
        };
        let (offset, velocity) = emitter_offset(e, &rotation, rng);
        p.position = cp.translation + e.origin + offset;
        p.velocity = velocity;
        let mut init = InitContext {
            frame,
            def,
            rng,
            rotation: &rotation,
            control_points: &self.control_points,
            sequences: &mut self.sequences,
            parent: parent
                .zip(self.parent_particle)
                .and_then(|(par, s)| par.particles.get(s).filter(|q| q.alive())),
            model: self.placement,
        };
        for (index, initializer) in def.initializers.iter().enumerate() {
            init.apply(index, initializer, &mut p);
        }
        p.prev_position = p.position;
        p.color = p.init_color;
        p.alpha = p.init_alpha;
        p.size = p.init_size;
        self.particles[slot] = p;
        if def.has_rope() {
            self.rope.push(slot as u32);
        }
        let s = self.trails.segments;
        if s > 0 {
            self.trails.history[slot * s..(slot + 1) * s].fill(p.position);
            self.trails.counts[slot] = 1;
            self.trails.scroll[slot] = 0;
        }
        Some(slot)
    }

    /// Event children for the particles spawned this step: one system per particle (with the
    /// entry's probability) while the entry has room.
    fn start_spawn_children(&mut self, frame: &Frame, rng: &mut Rng) {
        let node = &frame.nodes[self.node];
        for g in 0..self.children.len() {
            let link = &node.def.children[self.children[g].link];
            if !matches!(link.kind, ChildKind::EventSpawn | ChildKind::EventFollow) {
                continue;
            }
            let Some(child_node) = node.children[self.children[g].link] else {
                continue;
            };
            for i in 0..self.spawned.len() {
                if self.children[g].instances.len() >= link.max_count {
                    break;
                }
                if rng.f32() > link.probability {
                    continue;
                }
                let slot = self.spawned[i];
                let position = self.particles[slot].position;
                self.start_child(frame, rng, g, child_node, link.offset, position, Some(slot));
            }
        }
    }

    /// Event children where particles died this step. Room is counted over all death entries
    /// together, as the engine does.
    fn start_death_children(&mut self, frame: &Frame, rng: &mut Rng) {
        if self.died.is_empty() {
            return;
        }
        let node = &frame.nodes[self.node];
        let is_death = |g: &ChildGroup| node.def.children[g.link].kind == ChildKind::EventDeath;
        if !self.children.iter().any(is_death) {
            return;
        }
        for i in 0..self.died.len() {
            let room: usize = self
                .children
                .iter()
                .filter(|g| is_death(g))
                .map(|g| {
                    node.def.children[g.link]
                        .max_count
                        .saturating_sub(g.instances.len())
                })
                .sum();
            if room == 0 {
                break;
            }
            let position = self.particles[self.died[i]].position;
            for g in 0..self.children.len() {
                if !is_death(&self.children[g]) {
                    continue;
                }
                let link = &node.def.children[self.children[g].link];
                let Some(child_node) = node.children[self.children[g].link] else {
                    continue;
                };
                if rng.f32() <= link.probability {
                    self.start_child(frame, rng, g, child_node, link.offset, position, None);
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn start_child(
        &mut self,
        frame: &Frame,
        rng: &mut Rng,
        group: usize,
        node: usize,
        offset: Affine,
        position: Vec3,
        slot: Option<usize>,
    ) {
        let def = &frame.nodes[self.node].def;
        let space = if def.world_space() {
            Affine::IDENTITY
        } else {
            self.placement
        };
        let placement = space.mul(&Affine::translation(position)).mul(&offset);
        let mut child = match self.children[group].pool.pop() {
            Some(mut reused) => {
                reused.reset(frame.nodes);
                reused.placement = placement;
                reused
            }
            None => Instance::new(node, frame.nodes, placement),
        };
        child.parent_particle = slot;
        child.prewarm(frame, rng);
        child.start_static_children(frame, rng);
        self.children[group].instances.push(child);
    }

    /// The static children, which run for the whole life of the system.
    fn start_static_children(&mut self, frame: &Frame, rng: &mut Rng) {
        let node = &frame.nodes[self.node];
        for group in &mut self.children {
            let link = &node.def.children[group.link];
            let Some(child_node) = node.children[group.link] else {
                continue;
            };
            if link.kind != ChildKind::Static || !group.instances.is_empty() {
                continue;
            }
            let placement = self.placement.mul(&link.offset);
            let mut child = match group.pool.pop() {
                Some(mut reused) => {
                    reused.reset(frame.nodes);
                    reused.placement = placement;
                    reused
                }
                None => Instance::new(child_node, frame.nodes, placement),
            };
            child.prewarm(frame, rng);
            child.start_static_children(frame, rng);
            group.instances.push(child);
        }
    }
}

/// The space a parent stores its particles in, as a transform into scene space.
fn parent_space(parent: &Parent) -> Affine {
    if parent.world_space {
        Affine::IDENTITY
    } else {
        parent.placement
    }
}

/// The spawn offset from the emitter's origin and the initial velocity, for one particle.
fn emitter_offset(e: &super::model::Emitter, rotation: &Affine, rng: &mut Rng) -> (Vec3, Vec3) {
    let offset = match e.shape {
        EmitterShape::Sphere {
            distance,
            cone,
            sign,
        } => {
            // A direction in the cone around +x (the whole sphere for cone 0), a radius with the
            // density of a filled sphere, both scaled by `directions`.
            let phi = TAU * rng.positive();
            let u = cone + (1.0 - cone) * rng.f32();
            let r = rng.positive().cbrt();
            let s = (1.0 - u * u).max(0.0).sqrt();
            let v = Vec3::new(r * u, r * s * phi.sin(), r * s * phi.cos()) * e.directions;
            let len = v.length();
            let mut d = if len > 0.0 {
                v * (1.0 / len)
            } else {
                Vec3::ZERO
            };
            if e.flags & EMIT_SIGN != 0 {
                let force = |c: f32, s: f32| if s != 0.0 { c.abs().copysign(s) } else { c };
                d = Vec3::new(force(d.x, sign.x), force(d.y, sign.y), force(d.z, sign.z));
            }
            rotation.vector(d * distance.at(len))
        }
        EmitterShape::Box { distance } => {
            // Per axis independently, in a shell between the minimum and maximum distance.
            let mut axis = |dir: f32, min: f32, span: f32| {
                let c = (2.0 * rng.positive() - 1.0) * dir;
                if c == 0.0 {
                    0.0
                } else {
                    (c.abs() * span + min).copysign(c)
                }
            };
            let z = axis(e.directions.z, distance.min.z, distance.span.z);
            let y = axis(e.directions.y, distance.min.y, distance.span.y);
            let x = axis(e.directions.x, distance.min.x, distance.span.x);
            rotation.vector(Vec3::new(x, y, z))
        }
        // Without the source layer's pixels, the image emitter spawns at its offset range.
        EmitterShape::LayerImage { offset } => {
            offset.at(Vec3::new(rng.f32(), rng.f32(), rng.f32()))
        }
    };
    // Particles move away from the centre; at the centre itself in a random direction.
    let dir = if offset.length_squared() < 1.0e-4 {
        rotation.vector(
            e.directions
                * Vec3::new(
                    2.0 * rng.positive() - 1.0,
                    2.0 * rng.positive() - 1.0,
                    2.0 * rng.positive() - 1.0,
                ),
        )
    } else {
        offset
    };
    let speed = e.speed.at(rng.positive());
    (offset, dir.normalized_or(Vec3::ZERO) * speed)
}

/// Everything an initializer reads while a particle is born.
struct InitContext<'a, 'b> {
    frame: &'a Frame<'b>,
    def: &'a Definition,
    rng: &'a mut Rng,
    /// The emitter's control point rotation.
    rotation: &'a Affine,
    control_points: &'a [ControlPointState; CONTROL_POINTS],
    sequences: &'a mut Vec<(f32, f32)>,
    parent: Option<&'a Particle>,
    model: Affine,
}

impl InitContext<'_, '_> {
    fn apply(&mut self, index: usize, init: &Initializer, p: &mut Particle) {
        let rng = &mut *self.rng;
        match init {
            Initializer::Lifetime { range, exponent } => {
                p.lifetime = range.at(rng.skewed(*exponent)).max(0.001);
            }
            Initializer::Size { range, exponent } => p.init_size *= range.at(rng.skewed(*exponent)),
            Initializer::Alpha { range, exponent } => {
                p.init_alpha *= range.at(rng.skewed(*exponent))
            }
            Initializer::Color { range, exponent } => {
                p.init_color *= range.at(Vec3::splat(rng.skewed(*exponent)));
            }
            Initializer::HsvColor {
                hue_min,
                hue_step,
                hue_steps,
                saturation,
                value,
                ..
            } => {
                let k = ((rng.f32() * (*hue_steps + 1) as f32) as u32).min(*hue_steps);
                let hsv = Vec3::new(
                    hue_min + k as f32 * hue_step,
                    saturation.at(rng.f32()),
                    value.at(rng.f32()),
                );
                p.init_color *= hsv_to_rgb(hsv);
            }
            Initializer::ColorList {
                colors,
                noise,
                offset,
            } => {
                let c = colors[rng.index(colors.len())];
                let mut jitter = |c: f32, n: f32| {
                    let (lo, hi) = ((c - n).max(0.0), (c + n).min(1.0));
                    lo + (hi - lo) * rng.f32()
                };
                let hsv = Vec3::new(
                    jitter(c.x, noise.x),
                    jitter(c.y, noise.y),
                    jitter(c.z, noise.z),
                ) + *offset;
                let hsv = Vec3::new(
                    hsv.x - hsv.x.floor(),
                    hsv.y.clamp(0.0, 1.0),
                    hsv.z.clamp(0.0, 1.0),
                );
                p.init_color *= hsv_to_rgb(hsv);
            }
            Initializer::Velocity { range, exponent } => {
                p.velocity += self.rotation.vector(range.at(rng.skewed3(*exponent)));
            }
            Initializer::InheritControlPointVelocity {
                range,
                control_point,
            } => {
                let cp = &self.control_points[*control_point];
                let v = (cp.current.translation - cp.previous.translation) * (1.0 / FIXED_DT);
                p.velocity += self.rotation.vector(v) * range.at(rng.f32());
            }
            Initializer::TurbulentVelocity {
                speed,
                phase,
                time_scale,
                scale,
                offset,
                forward,
                right,
            } => {
                let t = (rng.f32() * phase.span + phase.min + self.frame.time) * time_scale;
                let angle = noise::noise1(t) * PI * scale + offset;
                let v = rotate_about(*forward, right.normalized_or(Vec3::Z), angle);
                p.velocity += self.rotation.vector(v) * speed.at(rng.f32());
            }
            Initializer::Rotation { range, exponent } => {
                p.rotation += range.at(rng.skewed3(*exponent));
            }
            Initializer::AngularVelocity { range, exponent } => {
                p.angular_velocity += range.at(rng.skewed3(*exponent));
            }
            Initializer::PositionOffset {
                directions,
                sign,
                signed,
                scale,
                distance,
                time_scale,
                octaves,
            } => {
                // Noise of position and time, not a random draw: neighbours move alike.
                let t = self.frame.time * time_scale;
                let q = p.position * *scale;
                let mut n = Vec3::new(
                    noise::fbm2(q.x, t, *octaves),
                    noise::fbm2(t, q.y, *octaves),
                    noise::fbm2(q.z, -t, *octaves),
                ) * *directions;
                if *signed {
                    n = n * (Vec3::ONE - sign.abs()) + n.abs() * *sign;
                }
                p.position += n * *distance;
            }
            Initializer::MapAround {
                bounds,
                speed,
                axis,
                right,
                up,
                mirror,
                control_point,
                ..
            } => {
                let cp = self.control_points[*control_point].current;
                let (axis, right, up) = (cp.vector(*axis), cp.vector(*right), cp.vector(*up));
                let u = advance(&mut self.sequences[index], *mirror, false);
                let d = p.position - cp.translation;
                let h = d.dot(axis);
                let r = (d - axis * h).length();
                let a = bounds.at(u) * TAU;
                let (s, c) = a.sin_cos();
                let radial = up * c + right * s;
                let tangent = up * -s + right * c;
                p.position = cp.translation + axis * h + radial * r;
                let sp = speed.at(Vec3::new(rng.f32(), rng.f32(), rng.f32()));
                p.velocity += tangent * sp.x + radial * sp.y + axis * sp.z;
            }
            Initializer::MapBetween {
                bounds,
                mirror,
                start,
                end,
                flags,
                arc_amount,
                arc_direction,
                size_reduction,
                ..
            } => {
                let a = self.control_points[*start].current.translation;
                let b = self.control_points[*end].current.translation;
                let u = advance(&mut self.sequences[index], *mirror, true);
                let d = b - a;
                let len = d.length().max(f32::MIN_POSITIVE);
                let dir = d * (1.0 / len);
                let mut q = p.position;
                if self.def.world_space() {
                    q -= a;
                }
                let mut perp = q - dir * q.dot(dir);
                let s = bounds.at(u);
                // 1 at the middle of the line, 0 at its ends.
                let w = 1.0 - (2.0 * u - 1.0).powi(2);
                if flags & 1 != 0 {
                    perp *= w;
                }
                p.position = perp + dir * (s * len) + a;
                if flags & 8 != 0 {
                    p.position += *arc_direction * (w * len * arc_amount);
                }
                if flags & 2 != 0 {
                    p.velocity *= w;
                }
                if flags & 4 != 0 {
                    p.init_size *= (1.0 - size_reduction) + size_reduction * w;
                }
            }
            Initializer::Remap(remap) => {
                let cps = self.control_points;
                operators::remap_initial(
                    remap,
                    p,
                    cps,
                    self.frame.time,
                    self.frame.time_of_day,
                    &self.model,
                );
            }
            Initializer::InheritFromEvent(value) => {
                if let Some(parent) = self.parent {
                    operators::inherit(*value, p, parent, true);
                }
            }
        }
    }
}

/// A sequence initializer's position for this particle, then the step to the next one:
/// repeating wraps to the start (between control points: back to 0), mirroring turns around.
fn advance(sequence: &mut (f32, f32), mirror: bool, between: bool) -> f32 {
    let (u, step) = sequence;
    let current = *u;
    *u += *step;
    if *u > 1.0 {
        if mirror {
            *step = -*step;
            *u = 2.0 - *u;
        } else if between {
            *u = 0.0;
        } else {
            *u %= 1.0;
        }
    } else if *u < 0.0 && mirror {
        *u = -*u;
        *step = -*step;
    }
    current
}

/// `v` rotated by `angle` radians about the unit axis `axis`.
fn rotate_about(v: Vec3, axis: Vec3, angle: f32) -> Vec3 {
    let (s, c) = angle.sin_cos();
    v * c + axis.cross(v) * s + axis * (axis.dot(v) * (1.0 - c))
}

/// A particle system on a layer: the tree of particle files, the root instance and the clock.
pub struct Simulation {
    tree: Tree,
    root: Instance,
    rng: Rng,
    seed: u64,
    overrides: InstanceOverride,
    /// Simulated seconds (the clock runs at the `rate` override's speed).
    time: f64,
    /// Whole steps taken; the step count follows from `time` alone, so how a span of time is
    /// split into advances does not change the result.
    steps: u64,
    /// The last real time the simulation was advanced to.
    real_time: f64,
    pointer: Vec3,
    audio: Vec<f32>,
    canvas: [f32; 2],
    time_of_day: f32,
    /// The prewarm has run (it waits for the first advance, so it sees the placement).
    started: bool,
}

impl Simulation {
    pub fn new(tree: Tree, overrides: InstanceOverride, seed: u64) -> Self {
        let mut tree = tree;
        tree.apply(&overrides);
        let mut sim = Self {
            root: Instance::default(),
            tree,
            rng: Rng::new(seed),
            seed,
            overrides,
            time: 0.0,
            steps: 0,
            real_time: 0.0,
            pointer: Vec3::ZERO,
            audio: Vec::new(),
            canvas: [0.0; 2],
            time_of_day: 0.0,
            started: false,
        };
        sim.root = Instance::new(0, &sim.tree.nodes, Affine::IDENTITY);
        sim
    }

    pub fn nodes(&self) -> &[Node] {
        &self.tree.nodes
    }

    #[cfg(test)]
    pub fn root(&self) -> &Instance {
        &self.root
    }

    /// Applies changed overrides to the definitions; running particles keep their state.
    pub fn set_overrides(&mut self, overrides: InstanceOverride) {
        if overrides != self.overrides {
            self.tree.apply(&overrides);
            self.overrides = overrides;
        }
    }

    /// Changes the overrides `partial` sets and keeps the others.
    pub fn apply_override(&mut self, partial: &InstanceOverride) {
        let mut overrides = self.overrides.clone();
        overrides.merge(partial);
        self.set_overrides(overrides);
    }

    /// The layer's transform: system space to scene space (y up).
    pub fn set_placement(&mut self, placement: Affine) {
        self.root.placement = placement;
    }

    /// The pointer in scene space.
    pub fn set_pointer(&mut self, pointer: Vec3) {
        self.pointer = pointer;
    }

    /// Left bands followed by right bands, 0..1.
    pub fn set_audio(&mut self, left: &[f32], right: &[f32]) {
        self.audio.clear();
        self.audio.extend_from_slice(left);
        self.audio.extend_from_slice(right);
    }

    /// Scene size, for bounds collisions.
    pub fn set_canvas(&mut self, width: f32, height: f32) {
        self.canvas = [width, height];
    }

    pub fn set_time_of_day(&mut self, fraction: f32) {
        self.time_of_day = fraction;
    }

    /// Starts over: no particles, emitters restarted, then the prewarm.
    fn reset(&mut self) {
        self.started = true;
        self.rng = Rng::new(self.seed);
        self.time = 0.0;
        self.steps = 0;
        self.real_time = 0.0;
        let placement = self.root.placement;
        self.root = Instance::new(0, &self.tree.nodes, placement);
        let frame = Frame {
            nodes: &self.tree.nodes,
            time: 0.0,
            time_of_day: self.time_of_day,
            pointer: self.pointer,
            audio: &self.audio,
            canvas: self.canvas,
            overrides: &self.overrides,
        };
        self.root.prewarm(&frame, &mut self.rng);
        self.root.start_static_children(&frame, &mut self.rng);
    }

    /// Advances to real time `time` in fixed steps. Going back starts over and replays, so a
    /// given time always shows the same frame.
    pub fn advance_to(&mut self, time: f32) {
        if !time.is_finite() || time < 0.0 {
            return;
        }
        let time = time as f64;
        if !self.started || time + 1.0e-9 < self.real_time {
            self.reset();
        }
        self.time += (time - self.real_time) * self.overrides.rate() as f64;
        self.real_time = time;
        let target = (self.time * STEPS_PER_SECOND + 1.0e-6).floor() as u64;
        while self.steps < target {
            self.steps += 1;
            let frame = Frame {
                nodes: &self.tree.nodes,
                time: (self.steps as f64 / STEPS_PER_SECOND) as f32,
                time_of_day: self.time_of_day,
                pointer: self.pointer,
                audio: &self.audio,
                canvas: self.canvas,
                overrides: &self.overrides,
            };
            self.root
                .update(&frame, &mut self.rng, FIXED_DT, true, None);
        }
    }

    /// Calls `f` for every instance, parents before their children (the draw order).
    pub fn visit<'a>(&'a self, f: &mut impl FnMut(&'a Instance)) {
        visit(&self.root, f);
    }

    #[cfg(test)]
    pub fn alive_count(&self) -> usize {
        let mut n = 0;
        self.visit(&mut |i| n += i.alive);
        n
    }
}

fn visit<'a>(inst: &'a Instance, f: &mut impl FnMut(&'a Instance)) {
    f(inst);
    for group in &inst.children {
        for child in &group.instances {
            visit(child, f);
        }
    }
}

impl Instance {
    /// A slot's trail: its past positions (newest first), how many are real and how often the
    /// trail has advanced.
    pub fn trail_history(&self, slot: usize) -> Option<(&[Vec3], u16, u16)> {
        let s = self.trails.segments;
        (s > 0).then(|| {
            (
                &self.trails.history[slot * s..(slot + 1) * s],
                self.trails.counts[slot],
                self.trails.scroll[slot],
            )
        })
    }

    /// The trail timer's progress through the current interval, 0..1.
    pub fn trail_phase(&self) -> f32 {
        if self.trails.interval > 0.0 {
            1.0 - self.trails.timer.max(0.0) / self.trails.interval
        } else {
            0.0
        }
    }

    /// The space the particles are stored in, as a transform into scene space.
    pub fn model(&self, nodes: &[Node]) -> Affine {
        if nodes[self.node].def.world_space() {
            Affine::IDENTITY
        } else {
            self.placement
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sim(json: &str) -> Simulation {
        sim_with(json, &mut |_| None)
    }

    fn sim_with(json: &str, load: &mut dyn FnMut(&str) -> Option<Definition>) -> Simulation {
        let def = Definition::parse_str(json, true).expect("parses");
        Simulation::new(
            Tree::new(def, load),
            InstanceOverride::default(),
            0x1234_5678,
        )
    }

    fn snapshot(sim: &Simulation) -> Vec<[f32; 4]> {
        let mut out = Vec::new();
        sim.visit(&mut |inst| {
            out.extend(
                inst.particles
                    .iter()
                    .filter(|p| p.alive())
                    .map(|p| [p.position.x, p.position.y, p.size, p.alpha]),
            )
        });
        out
    }

    const FLOW: &str = r#"{
        "maxcount": 64,
        "emitter": [{"name": "boxrandom", "rate": 40, "distancemax": "200 100 0",
                     "speedmin": 10, "speedmax": 40}],
        "initializer": [{"name": "lifetimerandom", "min": 0.5, "max": 1.5},
                        {"name": "sizerandom", "min": 10, "max": 30},
                        {"name": "velocityrandom", "min": "-10 -10 0", "max": "10 10 0"}],
        "operator": [{"name": "movement", "gravity": "0 -50 0", "drag": 0.1},
                     {"name": "turbulence", "speedmin": 20, "speedmax": 50},
                     {"name": "alphafade"},
                     {"name": "oscillatesize"}]
    }"#;

    #[test]
    fn same_seed_same_particles_and_seeking_back_replays() {
        let mut a = sim(FLOW);
        let mut b = sim(FLOW);
        a.advance_to(2.0);
        b.advance_to(1.0);
        b.advance_to(2.0);
        assert!(a.alive_count() > 20);
        assert_eq!(snapshot(&a), snapshot(&b));
        let at_two = snapshot(&a);
        a.advance_to(0.5);
        let mut fresh = sim(FLOW);
        fresh.advance_to(0.5);
        assert_eq!(snapshot(&a), snapshot(&fresh));
        assert_ne!(snapshot(&a), at_two);
    }

    #[test]
    fn emitters_default_to_ten_per_second() {
        let mut s = sim(r#"{"maxcount": 100, "emitter": [{"name": "boxrandom"}],
                           "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}]}"#);
        s.advance_to(1.0);
        assert_eq!(s.alive_count(), 10);
    }

    #[test]
    fn spawn_size_is_half_the_drawn_value() {
        let mut s = sim(
            r#"{"maxcount": 4, "emitter": [{"name": "sphererandom", "rate": 60}],
                           "initializer": [{"name": "sizerandom", "min": 40, "max": 40}]}"#,
        );
        s.advance_to(0.05);
        assert!(s
            .root()
            .particles
            .iter()
            .filter(|p| p.alive())
            .all(|p| p.size == 20.0));
    }

    #[test]
    fn start_time_prewarms_instead_of_delaying() {
        let mut s = sim(r#"{"maxcount": 16, "starttime": 15,
                           "emitter": [{"name": "sphererandom", "rate": 0.3}],
                           "initializer": [{"name": "lifetimerandom", "min": 8, "max": 20}]}"#);
        s.advance_to(0.0);
        assert!(
            s.alive_count() >= 3,
            "{} alive after the prewarm",
            s.alive_count()
        );
    }

    #[test]
    fn max_count_caps_and_count_override_does_not_raise_it() {
        let json = r#"{"maxcount": 7, "emitter": [{"name": "sphererandom", "rate": 1000}],
                       "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5}]}"#;
        let mut s = sim(json);
        s.advance_to(1.0);
        assert_eq!(s.alive_count(), 7);
        s.set_overrides(InstanceOverride {
            count: Some(3.0),
            ..InstanceOverride::default()
        });
        s.advance_to(2.0);
        assert_eq!(s.alive_count(), 7);
    }

    #[test]
    fn bursts_and_periodic_emission() {
        // A burst of 5, then nothing (rate 0 disables the emitter after it).
        let mut burst = sim(r#"{"maxcount": 50,
            "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 5}],
            "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}]}"#);
        burst.advance_to(2.0);
        assert_eq!(burst.alive_count(), 5);
        // One second on, one second off: particles of half a second exist only while on.
        let mut periodic = sim(r#"{"maxcount": 500,
            "emitter": [{"name": "sphererandom", "rate": 50, "flags": 4,
                         "minperiodicduration": 1, "maxperiodicduration": 1,
                         "minperiodicdelay": 1, "maxperiodicdelay": 1}],
            "initializer": [{"name": "lifetimerandom", "min": 0.5, "max": 0.5}]}"#);
        periodic.advance_to(0.8);
        assert!(periodic.alive_count() > 10);
        periodic.advance_to(1.7);
        assert_eq!(periodic.alive_count(), 0);
        periodic.advance_to(2.4);
        assert!(periodic.alive_count() > 10);
    }

    #[test]
    fn particles_die_after_their_lifetime_and_slots_are_reused() {
        let mut s = sim(r#"{"maxcount": 3,
            "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 3}],
            "initializer": [{"name": "lifetimerandom", "min": 0.1, "max": 0.1}]}"#);
        s.advance_to(0.05);
        assert_eq!(s.alive_count(), 3);
        s.advance_to(0.2);
        assert_eq!(s.alive_count(), 0);
        assert_eq!(s.root().particles.len(), 3);
    }

    #[test]
    fn death_children_start_where_particles_die() {
        let child = r#"{"maxcount": 4, "emitter": [{"name": "sphererandom", "rate": 0,
                        "instantaneous": 2, "distancemax": 0}],
                        "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5}]}"#;
        let mut s = sim_with(
            r#"{"maxcount": 1,
                "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1,
                             "distancemax": 0, "origin": "30 40 0"}],
                "initializer": [{"name": "lifetimerandom", "min": 0.2, "max": 0.2}],
                "children": [{"name": "spark.json", "type": "eventdeath"}]}"#,
            &mut |name| {
                assert_eq!(name, "spark.json");
                Some(Definition::parse_str(child, true).unwrap())
            },
        );
        s.advance_to(0.1);
        assert_eq!(s.alive_count(), 1);
        s.advance_to(0.5);
        let group = &s.root().children[0];
        assert_eq!(group.instances.len(), 1);
        let child = &group.instances[0];
        assert_eq!(child.alive, 2);
        // The child sits where its parent particle died.
        assert_eq!(child.placement.translation, Vec3::new(30.0, 40.0, 0.0));
    }

    #[test]
    fn a_pointer_control_point_drives_the_emitter() {
        let mut s = sim(r#"{"maxcount": 1,
            "emitter": [{"name": "sphererandom", "rate": 60, "distancemax": 0}],
            "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5}],
            "controlpoint": [{"flags": 1}]}"#);
        s.set_placement(Affine::translation(Vec3::new(100.0, 0.0, 0.0)));
        s.set_pointer(Vec3::new(150.0, 20.0, 0.0));
        s.advance_to(0.05);
        let p = s.root().particles[0];
        // In the layer's space: the pointer minus the layer's offset.
        assert!(
            (p.position - Vec3::new(50.0, 20.0, 0.0)).length() < 1.0e-3,
            "{p:?}"
        );
    }

    #[test]
    fn rope_trails_record_history_and_ropes_keep_spawn_order() {
        let mut s = sim(r#"{"maxcount": 8,
            "emitter": [{"name": "sphererandom", "rate": 20, "speedmin": 100, "speedmax": 100}],
            "initializer": [{"name": "lifetimerandom", "min": 0.3, "max": 0.3}],
            "operator": [{"name": "movement"}],
            "renderer": [{"name": "rope"}, {"name": "ropetrail", "segments": 4, "length": 0.2}]}"#);
        s.advance_to(1.0);
        let inst = s.root();
        assert_eq!(inst.rope.len(), inst.alive);
        let ages: Vec<f32> = inst
            .rope
            .iter()
            .map(|&i| inst.particles[i as usize].age)
            .collect();
        assert!(
            ages.windows(2).all(|w| w[0] >= w[1]),
            "spawn order {ages:?}"
        );
        let slot = inst.rope[0] as usize;
        let (history, count, _) = inst.trail_history(slot).expect("trail");
        assert_eq!(history.len(), 4);
        assert!(count >= 2);
        // The newest recorded point trails the particle.
        assert!((history[0] - inst.particles[slot].position).length() > 0.0);
    }

    #[test]
    fn colour_override_tints_systems_without_colours() {
        let def = Definition::parse_str(
            r#"{"maxcount": 2, "emitter": [{"name": "sphererandom", "rate": 60}]}"#,
            true,
        )
        .unwrap();
        let overrides = InstanceOverride {
            color: Some(Vec3::new(1.0, 0.5, 0.0)),
            alpha: Some(0.5),
            ..InstanceOverride::default()
        };
        let mut s = Simulation::new(Tree::new(def, &mut |_| None), overrides, 1);
        s.advance_to(0.05);
        let p = s.root().particles[0];
        assert_eq!(p.color, Vec3::new(1.0, 0.5, 0.0));
        assert_eq!(p.alpha, 0.5);
    }

    #[test]
    fn rate_override_speeds_up_the_clock() {
        let json = r#"{"maxcount": 100, "emitter": [{"name": "sphererandom", "rate": 10}],
                       "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}]}"#;
        let mut s = sim(json);
        s.set_overrides(InstanceOverride {
            rate: Some(2.0),
            ..InstanceOverride::default()
        });
        s.advance_to(1.0);
        assert_eq!(s.alive_count(), 20);
    }

    #[test]
    fn sequence_initializer_walks_between_control_points() {
        let mut s = sim(r#"{"maxcount": 5,
            "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 5, "distancemax": 0}],
            "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5},
                            {"name": "mapsequencebetweencontrolpoints", "count": 5}],
            "controlpoint": [{"offset": "0 0 0"}, {"offset": "100 0 0"}]}"#);
        s.advance_to(0.05);
        let mut xs: Vec<f32> = s.root().particles.iter().map(|p| p.position.x).collect();
        xs.sort_by(f32::total_cmp);
        for (x, want) in xs.iter().zip([0.0, 25.0, 50.0, 75.0, 100.0]) {
            assert!((x - want).abs() < 1.0e-3, "{xs:?}");
        }
    }
}
