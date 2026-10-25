//! Operators: the per-step changes to live particles, and the remap/inherit helpers the
//! initializers share with them.
//!
//! Every pass starts from the spawn size, colour and alpha, so the operators that scale those
//! scale the spawn values, never their own last result. Operators run in file order, each over
//! all particles. Those with a blend window scale their effect by the window's weight at the
//! particle's life fraction.
//!
//! The engine damps drag, attraction and turbulence when frames take longer than 25 ms; the fixed
//! 60 Hz step never does, so those use the plain step time.

use super::model::{
    BlendWindow, Collision, CollisionResponse, Component, Definition, EventValue, OperatorKind,
    Oscillate, Remap, RemapOperation, RemapValue, Transform,
};
use super::sim::{ControlPointState, Particle};
use super::{noise, Affine, Vec3, CONTROL_POINTS, PI, TAU};

/// The most a single step's drag may take off the velocity.
const MAX_DRAG: f32 = 0.999_999_9;

/// What the operators of one instance read during a step.
pub(crate) struct OpFrame<'a> {
    pub def: &'a Definition,
    pub dt: f32,
    pub time: f32,
    pub time_of_day: f32,
    pub audio: &'a [f32],
    pub canvas: [f32; 2],
    /// The instance's placement in scene space.
    pub model: Affine,
    pub world_space: bool,
    /// For event children: the particle that started them, while it lives.
    pub parent: Option<&'a Particle>,
}

/// One operator pass over `particles`.
pub(crate) fn run(
    f: &OpFrame,
    particles: &mut [Particle],
    cps: &mut [ControlPointState; CONTROL_POINTS],
    scratch: &mut Vec<(Vec3, Vec3)>,
) {
    for p in particles.iter_mut().filter(|p| p.alive()) {
        p.size = p.init_size;
        p.color = p.init_color;
        p.alpha = p.init_alpha;
    }
    let dt = f.dt;
    for op in &f.def.operators {
        let blend = op.blend;
        let weight = |p: &Particle| blend.map_or(1.0, |b: BlendWindow| b.weight(p.life_fraction()));
        match &op.kind {
            OperatorKind::Movement {
                gravity,
                drag,
                local_gravity,
            } => {
                // A flagged gravity is in scene space; turn it into the system's axes.
                let g = if *local_gravity && !f.world_space {
                    let [a, b, c] = f.model.cols;
                    Vec3::new(a.dot(*gravity), b.dot(*gravity), c.dot(*gravity))
                } else {
                    *gravity
                };
                let keep = 1.0 - (drag * dt).min(MAX_DRAG);
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    p.prev_position = p.position;
                    let v = p.velocity + g * dt;
                    p.position += v * dt;
                    p.velocity = v * keep;
                }
            }
            OperatorKind::AngularMovement { force, drag } => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let w = weight(p);
                    let v = p.angular_velocity + *force * (dt * w);
                    p.rotation += v * (dt * w);
                    p.angular_velocity = v * (1.0 - (drag * dt).min(MAX_DRAG) * w);
                }
            }
            OperatorKind::AlphaFade { fade_in, fade_out } => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let t = p.life_fraction();
                    let mut factor: f32 = 1.0;
                    if t < *fade_in {
                        factor = t / fade_in;
                    }
                    if t > *fade_out {
                        factor = factor.min((1.0 - t) / (1.0 - fade_out));
                    }
                    p.alpha *= factor;
                }
            }
            OperatorKind::SizeChange(c) => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let s = ((p.life_fraction() - c.time) * c.inv).clamp(0.0, 1.0);
                    p.size *= c.start + s * c.delta;
                }
            }
            OperatorKind::AlphaChange(c) => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let s = ((p.life_fraction() - c.time) * c.inv).clamp(0.0, 1.0);
                    p.alpha *= c.start + s * c.delta;
                }
            }
            OperatorKind::ColorChange {
                start,
                delta,
                time,
                inv,
            } => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let s = ((p.life_fraction() - time) * inv).clamp(0.0, 1.0);
                    p.color *= *start + *delta * s;
                }
            }
            OperatorKind::OscillatePosition { mask, osc } => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let r = p.random;
                    let freq = osc.frequency.at(r);
                    let amplitude = osc.scale.at(r) * weight(p);
                    // A displacement per step: the change of a sine over the step, so the
                    // particle oscillates around its moving path. y runs a quarter turn of
                    // random phase apart from x and z.
                    let phase = osc.phase.at(r) + p.age;
                    let wave = |ph: f32| ((freq * ph).sin() - (freq * (ph - dt)).sin()) * amplitude;
                    let d = wave(phase);
                    let dy = wave(phase + TAU * r);
                    p.position += Vec3::new(d * mask.x, dy * mask.y, d * mask.z);
                }
            }
            OperatorKind::OscillateAlpha(osc) => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let w = weight(p);
                    p.alpha *= 1.0 + (oscillation(osc, p) - 1.0) * w;
                }
            }
            OperatorKind::OscillateSize(osc) => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let w = weight(p);
                    p.size *= 1.0 + (oscillation(osc, p) - 1.0) * w;
                }
            }
            OperatorKind::ControlPointAttract {
                scale,
                threshold,
                delete_threshold_sq,
                control_point,
                flags,
            } => {
                let cp = cps[*control_point].current.translation;
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let delta = p.position - cp;
                    let d = delta.length();
                    if d > f32::MIN_POSITIVE && d < *threshold {
                        // Stronger closer in; a negative scale pushes away.
                        let mut m = (1.0 - d / threshold) * dt * scale * weight(p);
                        if flags & 2 != 0 && d < m {
                            m = d;
                        }
                        p.velocity -= delta * (m / d);
                    }
                    if flags & 1 != 0
                        && segment_distance_sq(p.prev_position, p.position, cp)
                            < *delete_threshold_sq
                    {
                        p.age = p.lifetime;
                    }
                }
            }
            OperatorKind::MaintainDistance {
                distance,
                variable_strength,
                control_point,
            } => {
                let cp = &cps[*control_point];
                let c = cp.current.translation;
                let moved = c - cp.previous.translation;
                let inverse = cp.current.linear().inverse();
                let k = if *variable_strength == 0.0 {
                    1.0
                } else {
                    (variable_strength * dt).clamp(0.0, 1.0)
                };
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let v = p.position + moved - c;
                    let len = inverse.vector(v).length();
                    if len > f32::MIN_POSITIVE {
                        p.position += moved + v * ((distance / len - 1.0) * k * weight(p));
                    }
                }
            }
            OperatorKind::MaintainBetween { start, end } => {
                let (a, b) = (
                    cps[*start].current.translation,
                    cps[*end].current.translation,
                );
                let (a0, b0) = (
                    cps[*start].previous.translation,
                    cps[*end].previous.translation,
                );
                let (l, l0) = (b - a, b0 - a0);
                if l.length_squared() > 1.4e-14 && l0.length_squared() > 1.4e-14 {
                    let len0 = l0.length();
                    let dir0 = l0 * (1.0 / len0);
                    for p in particles.iter_mut().filter(|p| p.alive()) {
                        let s = (p.position - a0).dot(dir0);
                        let u = (s / len0).clamp(0.0, 1.0);
                        p.position += ((a - a0) + l * u - dir0 * s) * weight(p);
                    }
                }
            }
            OperatorKind::ReduceMovement {
                control_point,
                inner,
                inv_span,
                reduction_inner,
                reduction_span,
            } => {
                let cp = cps[*control_point].current.translation;
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let s = (((p.position - cp).length() - inner) * inv_span).clamp(0.0, 1.0);
                    let r = ((reduction_inner + s * reduction_span) * dt).clamp(0.0, 1.0);
                    p.velocity *= 1.0 - r * weight(p);
                }
            }
            OperatorKind::Turbulence {
                mask,
                scale,
                speed,
                phase_span,
                time_scale,
                audio,
            } => {
                let t = f.time * time_scale;
                let loudness = audio.factor(f.audio);
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let r = p.random;
                    let phase = r * phase_span + t;
                    let s = loudness * speed.at(r) * weight(p) * dt;
                    let (x, y, z) = (
                        (phase + p.position.x) * scale,
                        (phase + p.position.y) * scale,
                        (phase + p.position.z) * scale,
                    );
                    // One noise field per axis, read at rotated coordinates.
                    if mask.x != 0.0 {
                        p.velocity.x += noise::noise3(x, y, z) * mask.x * s;
                    }
                    if mask.y != 0.0 {
                        p.velocity.y += noise::noise3(z, x, y) * mask.y * s;
                    }
                    if mask.z != 0.0 {
                        p.velocity.z += noise::noise3(y, z, x) * mask.z * s;
                    }
                }
            }
            OperatorKind::Vortex {
                offset,
                axis,
                inner,
                inv_span,
                speed_inner,
                speed_span,
                axial,
                control_point,
                audio,
            } => {
                let centre = cps[*control_point].current.translation + *offset;
                let loudness = audio.factor(f.audio);
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let rel = p.position - centre;
                    let h = if *axial { rel.dot(*axis) } else { 0.0 };
                    let radial = rel - *axis * h;
                    let r = radial.length();
                    let t = ((r - inner) * inv_span).clamp(0.0, 1.0);
                    let tangent = radial.normalized_or(Vec3::ZERO).cross(*axis);
                    p.velocity += tangent * ((t * speed_span + speed_inner) * loudness * dt);
                }
            }
            OperatorKind::VortexV2 {
                axis,
                inner,
                inv_span,
                speed_inner,
                speed_span,
                axial,
                center_force,
                ring_radius,
                ring_pull_force,
                ring,
                control_point,
                audio,
            } => {
                let cp = cps[*control_point].current;
                let centre = cp.translation;
                let axis = cp.vector(*axis);
                let loudness = audio.factor(f.audio);
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let w = weight(p);
                    let rel = p.position - centre;
                    let h = if *axial { rel.dot(axis) } else { 0.0 };
                    let radial = rel - axis * h;
                    let r = radial.length();
                    // Where the particle would be next step, relative to the axis.
                    let q = p.position + p.velocity * dt - centre - axis * h;
                    let q_len = q.length();
                    let pull = if q_len > f32::MIN_POSITIVE {
                        r / q_len - 1.0
                    } else {
                        0.0
                    };
                    let (t, ring_term) = if *ring {
                        let e = ring_radius - r;
                        let t = ((e.abs() - inner) * inv_span).clamp(0.0, 1.0);
                        let g = 1.0 - t;
                        let g = if g != 1.0 { g } else { 0.0 };
                        (t, g.copysign(e) * dt * ring_pull_force)
                    } else {
                        (((r - inner) * inv_span).clamp(0.0, 1.0), 0.0)
                    };
                    let tangent = radial.normalized_or(Vec3::ZERO).cross(axis);
                    let mut dv = tangent * ((t * speed_span + speed_inner) * loudness * dt);
                    dv += q * (pull * center_force / dt + ring_term);
                    p.velocity += dv * w;
                }
            }
            OperatorKind::Boids {
                separation_threshold,
                neighbor_threshold,
                max_speed,
                separation,
                alignment,
                cohesion,
                flags,
            } => {
                scratch.clear();
                scratch.extend(particles.iter().map(|p| {
                    if p.alive() {
                        (p.position, p.velocity)
                    } else {
                        (Vec3::splat(f32::INFINITY), Vec3::ZERO)
                    }
                }));
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let (mut n, mut sep_n) = (0.0f32, 0.0f32);
                    let (mut sum_v, mut sum_p, mut sum_sep) = (Vec3::ZERO, Vec3::ZERO, Vec3::ZERO);
                    for &(q, v) in scratch.iter() {
                        let delta = p.position - q;
                        let d = delta.length();
                        if d < *neighbor_threshold {
                            n += 1.0;
                            sum_v += v;
                            sum_p += q;
                        }
                        if d != 0.0 && d < *separation_threshold {
                            sep_n += 1.0;
                            sum_sep += delta * (separation_threshold / d - 1.0);
                        }
                    }
                    let mut dv = Vec3::ZERO;
                    if n > 0.0 {
                        dv += (sum_v * (1.0 / n) - p.velocity) * (alignment * dt);
                        dv += (sum_p * (1.0 / n) - p.position) * (cohesion * dt);
                    }
                    if sep_n > 0.0 {
                        dv += sum_sep * (separation * dt / sep_n);
                    }
                    let v = p.velocity + dv;
                    let limit = p.velocity.length_squared().max(max_speed * max_speed);
                    p.velocity = if flags & 1 != 0 && v.length_squared() > limit {
                        v.normalized_or(Vec3::ZERO) * *max_speed
                    } else {
                        v
                    };
                }
            }
            OperatorKind::CapVelocity { max_speed } => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let speed = p.velocity.length();
                    if speed > *max_speed {
                        let cap = max_speed / speed;
                        p.velocity *= 1.0 + (cap - 1.0) * weight(p);
                    }
                }
            }
            OperatorKind::Remap(remap) => {
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let w = weight(p);
                    let t = remap_input(remap, p, cps, f.time, f.time_of_day, &f.model, false);
                    write_output(remap, t, p, cps, false, w);
                }
            }
            OperatorKind::InheritFromEvent(value) => {
                if let Some(parent) = f.parent {
                    for p in particles.iter_mut().filter(|p| p.alive()) {
                        let before = *p;
                        inherit(*value, p, parent, false);
                        let w = weight(p);
                        if w < 1.0 {
                            blend_particle(p, &before, w);
                        }
                    }
                }
            }
            OperatorKind::CollisionPlane {
                collision,
                normal,
                distance,
            } => {
                let (n, d) = if collision.flags & 1 != 0 {
                    let cp = cps[collision.control_point].current;
                    let n = cp.vector(*normal).normalized_or(*normal);
                    (n, n.dot(cp.translation))
                } else {
                    (*normal, *distance)
                };
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let pen = p.position.dot(n) - d;
                    if pen < 0.0 {
                        collide(collision, p, n, pen);
                    }
                }
            }
            OperatorKind::CollisionSphere {
                collision,
                center,
                radius,
            } => {
                let c = if collision.flags & 1 != 0 {
                    cps[collision.control_point].current.translation
                } else {
                    *center
                };
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let rel = p.position - c;
                    let d = rel.length();
                    if d < *radius && d > f32::MIN_POSITIVE {
                        collide(collision, p, rel * (1.0 / d), d - radius);
                    }
                }
            }
            OperatorKind::CollisionBounds { collision } => {
                let to_scene = if f.world_space {
                    Affine::IDENTITY
                } else {
                    f.model
                };
                let back = to_scene.inverse();
                let [w, h] = f.canvas;
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let q = to_scene.point(p.position);
                    // The highest violated edge answers: top, right, bottom, left.
                    let hit = if q.y > h {
                        Some((-Vec3::Y, h - q.y))
                    } else if q.x > w {
                        Some((-Vec3::X, w - q.x))
                    } else if q.y < 0.0 {
                        Some((Vec3::Y, q.y))
                    } else if q.x < 0.0 {
                        Some((Vec3::X, q.x))
                    } else {
                        None
                    };
                    if let Some((n, pen)) = hit {
                        let mut scene = Particle {
                            position: q,
                            velocity: to_scene.vector(p.velocity),
                            ..*p
                        };
                        collide(collision, &mut scene, n, pen);
                        p.position = back.point(scene.position);
                        p.velocity = back.vector(scene.velocity);
                        p.angular_velocity = scene.angular_velocity;
                        p.age = scene.age;
                    }
                }
            }
            OperatorKind::CollisionQuad {
                collision,
                origin,
                normal,
                forward,
                side,
                half_size,
            } => {
                let (o, n, fw, sd) = if collision.flags & 1 != 0 {
                    let cp = cps[collision.control_point].current;
                    (
                        cp.translation,
                        cp.vector(*normal).normalized_or(*normal),
                        cp.vector(*forward).normalized_or(*forward),
                        cp.vector(*side).normalized_or(*side),
                    )
                } else {
                    (*origin, *normal, *forward, *side)
                };
                for p in particles.iter_mut().filter(|p| p.alive()) {
                    let rel = p.position - o;
                    let s = rel.dot(n);
                    if (p.prev_position - o).dot(n) > 0.0
                        && s <= 0.0
                        && rel.dot(fw).abs() < half_size[1]
                        && rel.dot(sd).abs() < half_size[0]
                    {
                        // Slightly past the plane, so the next step does not hit again.
                        collide(collision, p, n, s * 1.05);
                    }
                }
            }
        }
    }
}

/// An oscillation factor between the scale range's ends, with frequency, phase and amplitude
/// all derived from the particle's random value.
fn oscillation(osc: &Oscillate, p: &Particle) -> f32 {
    let r = p.random;
    let arg = (osc.phase.at(r) + p.age) * osc.frequency.at(r);
    osc.scale.min + r * osc.scale.span * (arg.sin() + 1.0) * 0.5
}

/// Pushes `p` out along `n` by the (negative) penetration `pen` and changes its velocity as the
/// collision says.
fn collide(c: &Collision, p: &mut Particle, n: Vec3, pen: f32) {
    let normal_speed = p.velocity.dot(n);
    match c.response {
        CollisionResponse::Bounce => {
            p.position -= n * pen;
            p.velocity += n * (c.bounce * normal_speed);
        }
        CollisionResponse::Slide => {
            p.position -= n * pen;
            p.velocity -= n * normal_speed;
        }
        CollisionResponse::Stop => {
            p.position -= n * pen;
            p.velocity = Vec3::ZERO;
        }
        CollisionResponse::Delete => p.age = p.lifetime,
    }
    if c.flags & 2 != 0 {
        p.angular_velocity = Vec3::ZERO;
    }
}

fn segment_distance_sq(a: Vec3, b: Vec3, point: Vec3) -> f32 {
    let ab = b - a;
    let len_sq = ab.length_squared();
    let t = if len_sq > 0.0 {
        ((point - a).dot(ab) / len_sq).clamp(0.0, 1.0)
    } else {
        0.0
    };
    (a + ab * t - point).length_squared()
}

/// Mixes the values an inherit operator may change back towards `before` by `1 - w`.
fn blend_particle(p: &mut Particle, before: &Particle, w: f32) {
    p.color = before.color.lerp(p.color, w);
    p.alpha = before.alpha + (p.alpha - before.alpha) * w;
    p.velocity = before.velocity.lerp(p.velocity, w);
    p.size = before.size + (p.size - before.size) * w;
    p.rotation = before.rotation.lerp(p.rotation, w);
    p.angular_velocity = before.angular_velocity.lerp(p.angular_velocity, w);
}

/// Takes a value over from the event's parent particle. `initial` writes the spawn values.
pub(crate) fn inherit(value: EventValue, p: &mut Particle, parent: &Particle, initial: bool) {
    let (color, alpha, size) = if initial {
        (&mut p.init_color, &mut p.init_alpha, &mut p.init_size)
    } else {
        (&mut p.color, &mut p.alpha, &mut p.size)
    };
    match value {
        EventValue::SetColor => *color = parent.color,
        EventValue::MultiplyColor => *color *= parent.color,
        EventValue::SetOpacity => *alpha = parent.alpha,
        EventValue::MultiplyOpacity => *alpha *= parent.alpha,
        EventValue::SetColorOpacity => {
            *color = parent.color;
            *alpha = parent.alpha;
        }
        EventValue::MultiplyColorOpacity => {
            *color *= parent.color;
            *alpha *= parent.alpha;
        }
        EventValue::SetVelocity => p.velocity = parent.velocity,
        EventValue::AddVelocity => p.velocity += parent.velocity,
        EventValue::SetSize => *size = parent.size,
        EventValue::MultiplySize => *size *= parent.size,
        EventValue::SetRotation => p.rotation = parent.rotation,
        EventValue::AddRotation => p.rotation += parent.rotation,
        EventValue::SetAngularVelocity => p.angular_velocity = parent.angular_velocity,
        EventValue::AddAngularVelocity => p.angular_velocity += parent.angular_velocity,
        EventValue::None => {}
    }
}

/// A remap of spawn values, run once when the particle is born.
pub(crate) fn remap_initial(
    remap: &Remap,
    p: &mut Particle,
    cps: &[ControlPointState; CONTROL_POINTS],
    time: f32,
    time_of_day: f32,
    model: &Affine,
) {
    let t = remap_input(remap, p, cps, time, time_of_day, model, true);
    let mut cps = *cps;
    write_output(remap, t, p, &mut cps, true, 1.0);
}

/// The remap's input, normalised into its range and shaped by the transform, per channel.
fn remap_input(
    remap: &Remap,
    p: &Particle,
    cps: &[ControlPointState; CONTROL_POINTS],
    time: f32,
    time_of_day: f32,
    model: &Affine,
    initial: bool,
) -> Vec3 {
    let cp = |slot: usize| cps[remap.control_points[slot]].current.translation;
    let (size, alpha, color) = if initial {
        (p.init_size, p.init_alpha, p.init_color)
    } else {
        (p.size, p.alpha, p.color)
    };
    let scalar = |v: f32| Vec3::splat(v);
    let raw = match remap.input {
        RemapValue::LifetimeFraction => scalar(p.life_fraction()),
        RemapValue::MaxLifetime => scalar(p.lifetime),
        RemapValue::Size => scalar(size),
        RemapValue::Opacity => scalar(alpha),
        RemapValue::Speed => scalar(p.velocity.length()),
        RemapValue::Rotation => scalar(p.rotation.z),
        RemapValue::AngularSpeed => scalar(p.angular_velocity.z),
        RemapValue::DistanceToControlPoint => scalar((p.position - cp(0)).length()),
        RemapValue::PositionBetweenControlPoints => {
            let (a, b) = (cp(0), cp(2));
            let ab = b - a;
            let len_sq = ab.length_squared();
            scalar(if len_sq > 0.0 {
                (p.position - a).dot(ab) / len_sq
            } else {
                0.0
            })
        }
        RemapValue::Runtime | RemapValue::SystemTime | RemapValue::LayerTime => scalar(time),
        RemapValue::TimeOfDay => scalar(time_of_day),
        RemapValue::Color => color,
        RemapValue::Position => p.position,
        RemapValue::Velocity => p.velocity,
        RemapValue::ControlPoint => cp(0),
        RemapValue::DeltaToControlPoint => cp(0) - p.position,
        RemapValue::DirectionToControlPoint => (cp(0) - p.position).normalized_or(Vec3::ZERO),
        RemapValue::LayerOrigin => model.translation,
        RemapValue::Unknown => Vec3::ZERO,
    };
    let picked = if remap.input.is_vector() {
        match remap.input_component {
            Component::All => raw,
            Component::X => scalar(raw.x),
            Component::Y => scalar(raw.y),
            Component::Z => scalar(raw.z),
            Component::Sum => scalar(raw.x + raw.y + raw.z),
            Component::Average => scalar((raw.x + raw.y + raw.z) / 3.0),
            Component::Max => scalar(raw.x.max(raw.y).max(raw.z)),
            Component::Min => scalar(raw.x.min(raw.y).min(raw.z)),
        }
    } else {
        raw
    };
    let mut n = if remap.input.is_vector() && remap.input_component == Component::All {
        (picked - remap.input_min) * remap.input_inv
    } else {
        scalar((picked.x - remap.input_min.x) * remap.input_inv.x)
    };
    if remap.flags & 1 != 0 {
        n = n.map(|v| v.clamp(0.0, 1.0));
    }
    // Noise transforms read a plane per particle and channel.
    let seed = p.random.to_bits();
    let channel = |v: f32, seed: u32| shape(remap.transform, v * remap.scale, seed, remap.octaves);
    let x = channel(n.x, seed);
    if remap.output.is_vector() {
        Vec3::new(
            x,
            channel(n.y, seed ^ 0x0b39_24ad),
            channel(n.z, seed ^ 0x493a_8e83),
        )
    } else {
        scalar(x)
    }
}

/// A transform function on the scaled input.
fn shape(transform: Transform, v: f32, seed: u32, octaves: u32) -> f32 {
    let negative_bump = if v < 0.0 { 1.0 } else { 0.0 };
    match transform {
        Transform::None => v,
        Transform::Sine => ((v * PI - PI * 0.5).sin() + 1.0) * 0.5,
        Transform::Square => (v - v.trunc()).round() + negative_bump,
        Transform::Saw => v - v.trunc() + negative_bump,
        Transform::Triangle => 1.0 - (2.0 * (v.abs() - v.abs().trunc()) - 1.0).abs(),
        Transform::Noise => 0.5 + 0.5 * noise::noise2_seeded(seed, v, 0.0),
        Transform::Fbm => 0.5 + 0.5 * noise::fbm2_seeded(seed, v, 0.0, octaves),
    }
}

fn operate(op: RemapOperation, old: f32, value: f32) -> f32 {
    match op {
        RemapOperation::Set => value,
        RemapOperation::Multiply => old * value,
        RemapOperation::Add => old + value,
        RemapOperation::Subtract => old - value,
        RemapOperation::None => old,
    }
}

fn operate3(op: RemapOperation, old: Vec3, value: Vec3, component: Component) -> Vec3 {
    let full = Vec3::new(
        operate(op, old.x, value.x),
        operate(op, old.y, value.y),
        operate(op, old.z, value.z),
    );
    match component {
        Component::X => Vec3::new(full.x, old.y, old.z),
        Component::Y => Vec3::new(old.x, full.y, old.z),
        Component::Z => Vec3::new(old.x, old.y, full.z),
        _ => full,
    }
}

/// Writes the remapped value `t` (0..1 per channel) into the output, blended by `w`.
fn write_output(
    remap: &Remap,
    t: Vec3,
    p: &mut Particle,
    cps: &mut [ControlPointState; CONTROL_POINTS],
    initial: bool,
    w: f32,
) {
    let mut r = remap.output_range.at(t);
    if remap.flags & 2 != 0 {
        r = r.map(|v| v.clamp(0.0, 1.0));
    }
    let op = remap.operation;
    let mix = |old: f32, new: f32| old + (new - old) * w;
    let mix3 = |old: Vec3, new: Vec3| old.lerp(new, w);
    let cp = |slot: usize| cps[remap.control_points[slot]].current.translation;
    match remap.output {
        RemapValue::MaxLifetime => {
            p.lifetime = mix(p.lifetime, operate(op, p.lifetime, r.x)).max(0.001)
        }
        RemapValue::Size => {
            let size = if initial {
                &mut p.init_size
            } else {
                &mut p.size
            };
            *size = mix(*size, operate(op, *size, r.x));
        }
        RemapValue::Opacity => {
            let alpha = if initial {
                &mut p.init_alpha
            } else {
                &mut p.alpha
            };
            *alpha = mix(*alpha, operate(op, *alpha, r.x));
        }
        RemapValue::Speed => {
            let speed = p.velocity.length();
            let new = mix(speed, operate(op, speed, r.x));
            p.velocity = if speed > 0.0 {
                p.velocity * (new / speed)
            } else {
                p.velocity * new
            };
        }
        RemapValue::Rotation => p.rotation.z = mix(p.rotation.z, operate(op, p.rotation.z, r.x)),
        RemapValue::AngularSpeed => {
            p.angular_velocity.z = mix(p.angular_velocity.z, operate(op, p.angular_velocity.z, r.x))
        }
        RemapValue::DistanceToControlPoint => {
            let c = cp(1);
            let rel = p.position - c;
            let d = rel.length();
            p.position = mix3(
                p.position,
                c + rel.normalized_or(Vec3::ZERO) * operate(op, d, r.x),
            );
        }
        RemapValue::PositionBetweenControlPoints => {
            let (a, b) = (cp(1), cp(3));
            let ab = b - a;
            let len = ab.length();
            if len > 0.0 {
                let dir = ab * (1.0 / len);
                let along = (p.position - a).dot(dir);
                let perp = p.position - a - dir * along;
                let fraction = operate(op, along / len, r.x);
                p.position = mix3(p.position, a + perp + dir * (fraction * len));
            }
        }
        RemapValue::Color => {
            let color = if initial {
                &mut p.init_color
            } else {
                &mut p.color
            };
            *color = mix3(*color, operate3(op, *color, r, remap.output_component));
        }
        RemapValue::Position => {
            p.position = mix3(
                p.position,
                operate3(op, p.position, r, remap.output_component),
            )
        }
        RemapValue::Velocity => {
            p.velocity = mix3(
                p.velocity,
                operate3(op, p.velocity, r, remap.output_component),
            )
        }
        RemapValue::ControlPoint => {
            let state = &mut cps[remap.control_points[1]];
            state.current.translation =
                operate3(op, state.current.translation, r, remap.output_component);
            state.written = true;
        }
        RemapValue::DeltaToControlPoint => {
            let c = cp(1);
            p.position = mix3(
                p.position,
                c - operate3(op, c - p.position, r, Component::All),
            );
        }
        RemapValue::DirectionToControlPoint => {
            let c = cp(1);
            let rel = c - p.position;
            let d = rel.length();
            let dir = operate3(op, rel.normalized_or(Vec3::ZERO), r, Component::All);
            p.position = mix3(p.position, c - dir.normalized_or(Vec3::ZERO) * d);
        }
        RemapValue::LifetimeFraction
        | RemapValue::Runtime
        | RemapValue::TimeOfDay
        | RemapValue::SystemTime
        | RemapValue::LayerTime
        | RemapValue::LayerOrigin
        | RemapValue::Unknown => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::particles::model::Definition;

    fn particle() -> Particle {
        Particle {
            lifetime: 2.0,
            init_size: 10.0,
            init_alpha: 1.0,
            init_color: Vec3::ONE,
            ..Particle::default()
        }
    }

    fn run_ops(json: &str, particles: &mut [Particle], dt: f32) {
        let def = Definition::parse_str(json, true).expect("parses");
        let frame = OpFrame {
            def: &def,
            dt,
            time: 0.0,
            time_of_day: 0.0,
            audio: &[],
            canvas: [1920.0, 1080.0],
            model: Affine::IDENTITY,
            world_space: false,
            parent: None,
        };
        let mut cps = [ControlPointState::default(); CONTROL_POINTS];
        run(&frame, particles, &mut cps, &mut Vec::new());
    }

    #[test]
    fn movement_integrates_gravity_then_drag() {
        let mut ps = [Particle {
            velocity: Vec3::new(10.0, 0.0, 0.0),
            ..particle()
        }];
        run_ops(
            r#"{"operator": [{"name": "movement", "gravity": "0 -10 0", "drag": 1}]}"#,
            &mut ps,
            0.1,
        );
        assert!((ps[0].position - Vec3::new(1.0, -0.1, 0.0)).length() < 1.0e-5);
        assert!((ps[0].velocity - Vec3::new(9.0, -0.9, 0.0)).length() < 1.0e-5);
    }

    #[test]
    fn particles_without_movement_stay_put() {
        let mut ps = [Particle {
            velocity: Vec3::new(10.0, 0.0, 0.0),
            ..particle()
        }];
        run_ops(r#"{"operator": [{"name": "alphafade"}]}"#, &mut ps, 0.1);
        assert_eq!(ps[0].position, Vec3::ZERO);
    }

    #[test]
    fn alpha_fade_uses_life_fractions() {
        let json =
            r#"{"operator": [{"name": "alphafade", "fadeintime": 0.2, "fadeouttime": 0.6}]}"#;
        let at = |age: f32| {
            let mut ps = [Particle { age, ..particle() }];
            run_ops(json, &mut ps, 0.0);
            ps[0].alpha
        };
        assert!((at(0.2) - 0.5).abs() < 1.0e-5);
        assert!((at(1.0) - 1.0).abs() < 1.0e-5);
        assert!((at(1.6) - 0.5).abs() < 1.0e-5);
    }

    #[test]
    fn size_change_scales_the_spawn_size_each_pass() {
        let json = r#"{"operator": [{"name": "sizechange", "startvalue": 1, "endvalue": 3}]}"#;
        let mut ps = [Particle {
            age: 1.0,
            ..particle()
        }];
        run_ops(json, &mut ps, 0.0);
        run_ops(json, &mut ps, 0.0);
        assert!((ps[0].size - 20.0).abs() < 1.0e-4);
    }

    #[test]
    fn attraction_pulls_inside_the_threshold_only() {
        let json =
            r#"{"operator": [{"name": "controlpointattract", "scale": 100, "threshold": 50}]}"#;
        let mut ps = [
            Particle {
                position: Vec3::new(25.0, 0.0, 0.0),
                ..particle()
            },
            Particle {
                position: Vec3::new(80.0, 0.0, 0.0),
                ..particle()
            },
        ];
        run_ops(json, &mut ps, 0.1);
        assert!(ps[0].velocity.x < 0.0);
        assert_eq!(ps[1].velocity, Vec3::ZERO);
    }

    #[test]
    fn plane_collision_bounces() {
        let json = r#"{"operator": [{"name": "collisionplane", "plane": "0 1 0", "distance": 0,
                       "bouncefactor": 0.5}]}"#;
        let mut ps = [Particle {
            position: Vec3::new(0.0, -2.0, 0.0),
            velocity: Vec3::new(0.0, -10.0, 0.0),
            ..particle()
        }];
        run_ops(json, &mut ps, 0.0);
        assert!((ps[0].position.y).abs() < 1.0e-5);
        assert!((ps[0].velocity.y - 5.0).abs() < 1.0e-5);
    }

    #[test]
    fn remap_shapes_and_writes_its_output() {
        let json = r#"{"operator": [{"name": "remapvalue", "input": "lifetimefraction",
                       "output": "opacity", "operation": "remap", "transformfunction": "saw",
                       "transforminputscale": 2, "outputrangemin": 0, "outputrangemax": 10}]}"#;
        let mut ps = [Particle {
            age: 0.6,
            ..particle()
        }];
        run_ops(json, &mut ps, 0.0);
        // fraction 0.3, scaled 0.6, saw 0.6, output 6.
        assert!((ps[0].alpha - 6.0).abs() < 1.0e-4, "{}", ps[0].alpha);
    }
}
