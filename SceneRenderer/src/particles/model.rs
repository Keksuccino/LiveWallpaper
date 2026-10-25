//! The particle file, parsed into ready-to-run components with the engine's defaults.
//!
//! A key that is absent takes the default; a key that is present but `null` reads as zero, like
//! the engine. Vectors are space-separated strings whose missing components are zero ("5" is
//! (5, 0, 0)). Ranges are kept as `min` and `max - min` without reordering, so `min > max` simply
//! draws from the reversed interval. Many defaults differ between 2D scenes (an orthographic
//! projection, scene units are pixels) and 3D ones (units are metres); `two_d` picks the set.

use serde_json::{Map, Value};

use super::{
    Affine, AudioResponse, Range, Range3, Vec3, CONTROL_POINTS, MAX_PARTICLES_PER_SYSTEM, PI, TAU,
};
use crate::Error;

/// System flag: simulate in scene space instead of the layer's.
pub const FLAG_WORLD_SPACE: u32 = 0x1;
/// System flag: sprite sheet frames do not blend into each other (also set by `randomframe`).
pub const FLAG_NO_FRAME_BLEND: u32 = 0x2;
/// System flag: drawn through a perspective camera.
pub const FLAG_PERSPECTIVE: u32 = 0x4;
/// System flags that make the system ignore one instance override each.
pub const FLAG_NO_COLOR_OVERRIDE: u32 = 0x8;
pub const FLAG_NO_SPEED_OVERRIDE: u32 = 0x10;
pub const FLAG_NO_COUNT_OVERRIDE: u32 = 0x20;
pub const FLAG_NO_LIFETIME_OVERRIDE: u32 = 0x40;
pub const FLAG_NO_SIZE_OVERRIDE: u32 = 0x80;

/// Emitter flag: `sign` forces the sign of each spawn offset component.
pub const EMIT_SIGN: u32 = 0x1;
/// Emitter flag: at most one particle per step.
pub const EMIT_ONE_PER_STEP: u32 = 0x2;
/// Emitter flag: emits in periods with pauses in between.
pub const EMIT_PERIODIC: u32 = 0x4;

/// A component's blend window over the particle's life: its effect fades in between `start` and
/// `start + 1/in_inv` and out towards `end`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BlendWindow {
    pub start: f32,
    pub in_inv: f32,
    pub end: f32,
    pub out_inv: f32,
}

impl BlendWindow {
    /// The weight at life fraction `t`.
    pub fn weight(&self, t: f32) -> f32 {
        ((t - self.start) * self.in_inv).clamp(0.0, 1.0)
            * ((self.end - t) * self.out_inv).clamp(0.0, 1.0)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum EmitterShape {
    /// Inside a sphere shell; `cone` is the lowest cosine to the +x axis a direction may have.
    Sphere {
        distance: Range,
        cone: f32,
        sign: Vec3,
    },
    /// Inside a box shell, per axis between `distance.min` and `distance.min + distance.span`.
    Box { distance: Range3 },
    /// On the opaque pixels of another layer's picture.
    LayerImage { offset: Range3 },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Emitter {
    pub shape: EmitterShape,
    pub origin: Vec3,
    pub directions: Vec3,
    pub speed: Range,
    pub control_point: usize,
    /// Particles per second.
    pub rate: f32,
    /// Seconds the emitter runs; 0 runs forever.
    pub duration: f32,
    pub delay: f32,
    /// A burst emitted at the start (and at every period start).
    pub instantaneous: u32,
    pub flags: u32,
    pub periodic_duration: Range,
    pub periodic_delay: Range,
    pub max_per_period: u32,
    pub audio: AudioResponse,
}

/// What a remap reads or writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemapValue {
    LifetimeFraction,
    MaxLifetime,
    Size,
    Opacity,
    Speed,
    Rotation,
    AngularSpeed,
    DistanceToControlPoint,
    PositionBetweenControlPoints,
    Runtime,
    TimeOfDay,
    SystemTime,
    LayerTime,
    Color,
    Position,
    Velocity,
    ControlPoint,
    DeltaToControlPoint,
    DirectionToControlPoint,
    LayerOrigin,
    Unknown,
}

impl RemapValue {
    fn from_name(name: &str) -> Self {
        match name {
            "lifetimefraction" => Self::LifetimeFraction,
            "maxlifetime" => Self::MaxLifetime,
            "size" => Self::Size,
            "opacity" => Self::Opacity,
            "speed" => Self::Speed,
            "rotation" => Self::Rotation,
            "angularspeed" => Self::AngularSpeed,
            "distancetocontrolpoint" => Self::DistanceToControlPoint,
            "positionbetweentwocontrolpoints" => Self::PositionBetweenControlPoints,
            "runtime" => Self::Runtime,
            "timeofday" => Self::TimeOfDay,
            "particlesystemtime" => Self::SystemTime,
            "layertime" => Self::LayerTime,
            "color" => Self::Color,
            "position" => Self::Position,
            "velocity" => Self::Velocity,
            "controlpoint" => Self::ControlPoint,
            "deltatocontrolpoint" => Self::DeltaToControlPoint,
            "directiontocontrolpoint" => Self::DirectionToControlPoint,
            "layerorigin" => Self::LayerOrigin,
            _ => Self::Unknown,
        }
    }

    /// Inputs from `Color` on carry three components.
    pub fn is_vector(self) -> bool {
        matches!(
            self,
            Self::Color
                | Self::Position
                | Self::Velocity
                | Self::ControlPoint
                | Self::DeltaToControlPoint
                | Self::DirectionToControlPoint
                | Self::LayerOrigin
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemapOperation {
    Set,
    Multiply,
    Add,
    Subtract,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Component {
    All,
    X,
    Y,
    Z,
    Sum,
    Average,
    Max,
    Min,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transform {
    None,
    Sine,
    Square,
    Saw,
    Triangle,
    Noise,
    Fbm,
}

/// A value read from the particle (or the scene), normalised into a range, shaped and written
/// to another particle value.
#[derive(Debug, Clone, PartialEq)]
pub struct Remap {
    pub operation: RemapOperation,
    pub input: RemapValue,
    pub output: RemapValue,
    pub input_component: Component,
    pub output_component: Component,
    pub transform: Transform,
    pub octaves: u32,
    /// Bit 0 clamps the normalised input to 0..1, bit 1 the output.
    pub flags: u32,
    pub input_min: Vec3,
    pub input_inv: Vec3,
    pub output_range: Range3,
    /// input 0, output 0, input 1, output 1.
    pub control_points: [usize; 4],
    pub scale: f32,
}

/// What an event child takes over from the particle that spawned it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventValue {
    SetColor,
    MultiplyColor,
    SetOpacity,
    MultiplyOpacity,
    SetColorOpacity,
    MultiplyColorOpacity,
    SetVelocity,
    AddVelocity,
    SetSize,
    MultiplySize,
    SetRotation,
    AddRotation,
    SetAngularVelocity,
    AddAngularVelocity,
    None,
}

impl EventValue {
    fn from_name(name: &str) -> Self {
        match name {
            "setcolor" => Self::SetColor,
            "multiplycolor" => Self::MultiplyColor,
            "setopacity" => Self::SetOpacity,
            "multiplyopacity" => Self::MultiplyOpacity,
            "setcoloropacity" => Self::SetColorOpacity,
            "multiplycoloropacity" => Self::MultiplyColorOpacity,
            "setvelocity" => Self::SetVelocity,
            "addvelocity" => Self::AddVelocity,
            "setsize" => Self::SetSize,
            "multiplysize" => Self::MultiplySize,
            "setrotation" => Self::SetRotation,
            "addrotation" => Self::AddRotation,
            "setangularvelocity" => Self::SetAngularVelocity,
            "addangularvelocity" => Self::AddAngularVelocity,
            _ => Self::None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Initializer {
    Lifetime {
        range: Range,
        exponent: f32,
    },
    /// Multiplies the spawn size, which starts at 0.5: a file's size is twice the drawn width.
    Size {
        range: Range,
        exponent: f32,
    },
    Alpha {
        range: Range,
        exponent: f32,
    },
    /// One draw along the line between the two colours.
    Color {
        range: Range3,
        exponent: f32,
    },
    /// A hue from `hue_steps` evenly spaced ones starting at `hue_min`, `hue_step` apart.
    HsvColor {
        hue_min: f32,
        hue_range: f32,
        hue_step: f32,
        hue_steps: u32,
        saturation: Range,
        value: Range,
    },
    /// Colours as HSV, each picked at random and jittered by `noise`, shifted by `offset`.
    ColorList {
        colors: Vec<Vec3>,
        noise: Vec3,
        offset: Vec3,
    },
    Velocity {
        range: Range3,
        exponent: f32,
    },
    InheritControlPointVelocity {
        range: Range,
        control_point: usize,
    },
    TurbulentVelocity {
        speed: Range,
        phase: Range,
        time_scale: f32,
        scale: f32,
        offset: f32,
        forward: Vec3,
        right: Vec3,
    },
    Rotation {
        range: Range3,
        exponent: f32,
    },
    PositionOffset {
        directions: Vec3,
        sign: Vec3,
        signed: bool,
        scale: f32,
        distance: f32,
        time_scale: f32,
        octaves: u32,
    },
    AngularVelocity {
        range: Range3,
        exponent: f32,
    },
    /// Places successive particles around a control point.
    MapAround {
        count: f32,
        bounds: Range,
        speed: Range3,
        axis: Vec3,
        right: Vec3,
        up: Vec3,
        mirror: bool,
        control_point: usize,
        flags: u32,
    },
    /// Places successive particles along the line between two control points.
    MapBetween {
        count: f32,
        bounds: Range,
        mirror: bool,
        start: usize,
        end: usize,
        flags: u32,
        arc_amount: f32,
        arc_direction: Vec3,
        size_reduction: f32,
    },
    Remap(Remap),
    InheritFromEvent(EventValue),
}

impl Initializer {
    /// The step between successive particles of a sequence initializer for `count` particles.
    pub fn sequence_step(&self) -> f32 {
        match self {
            Self::MapAround { count, .. } => 1.0 / count.max(1.0e-4),
            Self::MapBetween { count, .. } => 1.0 / (count - 1.0).max(1.0e-4),
            _ => 0.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Change {
    pub start: f32,
    pub delta: f32,
    pub time: f32,
    pub inv: f32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Oscillate {
    pub frequency: Range,
    pub phase: Range,
    pub scale: Range,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CollisionResponse {
    Bounce,
    Slide,
    Stop,
    Delete,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Collision {
    /// `-(1 + bounce factor)`: the velocity change along the normal per unit of normal speed.
    pub bounce: f32,
    pub response: CollisionResponse,
    pub flags: u32,
    pub control_point: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub enum OperatorKind {
    Movement {
        gravity: Vec3,
        drag: f32,
        local_gravity: bool,
    },
    AngularMovement {
        force: Vec3,
        drag: f32,
    },
    AlphaFade {
        fade_in: f32,
        fade_out: f32,
    },
    SizeChange(Change),
    AlphaChange(Change),
    ColorChange {
        start: Vec3,
        delta: Vec3,
        time: f32,
        inv: f32,
    },
    OscillatePosition {
        mask: Vec3,
        osc: Oscillate,
    },
    OscillateAlpha(Oscillate),
    OscillateSize(Oscillate),
    ControlPointAttract {
        scale: f32,
        threshold: f32,
        delete_threshold_sq: f32,
        control_point: usize,
        flags: u32,
    },
    MaintainDistance {
        distance: f32,
        variable_strength: f32,
        control_point: usize,
    },
    MaintainBetween {
        start: usize,
        end: usize,
    },
    ReduceMovement {
        control_point: usize,
        inner: f32,
        inv_span: f32,
        reduction_inner: f32,
        reduction_span: f32,
    },
    Turbulence {
        mask: Vec3,
        scale: f32,
        speed: Range,
        phase_span: f32,
        time_scale: f32,
        audio: AudioResponse,
    },
    Vortex {
        offset: Vec3,
        axis: Vec3,
        inner: f32,
        inv_span: f32,
        speed_inner: f32,
        speed_span: f32,
        axial: bool,
        control_point: usize,
        audio: AudioResponse,
    },
    VortexV2 {
        axis: Vec3,
        inner: f32,
        inv_span: f32,
        speed_inner: f32,
        speed_span: f32,
        axial: bool,
        center_force: f32,
        ring_radius: f32,
        ring_pull_force: f32,
        ring: bool,
        control_point: usize,
        audio: AudioResponse,
    },
    Boids {
        separation_threshold: f32,
        neighbor_threshold: f32,
        max_speed: f32,
        separation: f32,
        alignment: f32,
        cohesion: f32,
        flags: u32,
    },
    CapVelocity {
        max_speed: f32,
    },
    Remap(Remap),
    InheritFromEvent(EventValue),
    CollisionPlane {
        collision: Collision,
        normal: Vec3,
        distance: f32,
    },
    CollisionSphere {
        collision: Collision,
        center: Vec3,
        radius: f32,
    },
    CollisionBounds {
        collision: Collision,
    },
    CollisionQuad {
        collision: Collision,
        origin: Vec3,
        normal: Vec3,
        forward: Vec3,
        side: Vec3,
        half_size: [f32; 2],
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Operator {
    pub kind: OperatorKind,
    pub blend: Option<BlendWindow>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RendererKind {
    Sprite,
    /// A sprite stretched along its velocity: `length` seconds of travel, clamped to
    /// `min_length..max_length` sprite heights.
    SpriteTrail {
        length: f32,
        max_length: f32,
        min_length: f32,
    },
    /// All particles joined into one strip in spawn order.
    Rope {
        subdivision: u32,
    },
    /// A strip behind each particle through its last `segments` positions, `length` seconds long.
    /// The engine curves each segment in its geometry stage (`subdivision`); drawn without one,
    /// the segments stay straight.
    RopeTrail {
        length: f32,
        segments: u32,
        fade_alpha: bool,
        fade_size: bool,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Renderer {
    pub kind: RendererKind,
    /// 0 faces the screen, 1 stays upright around `axis`, 2 is fixed to `axis`/`forward`.
    pub orientation: u8,
    pub axis: Vec3,
    pub forward: Vec3,
    /// Bit 0: the orientation follows the screen (or world) instead of the layer.
    pub flags: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChildKind {
    /// Lives for the whole life of the parent system.
    Static,
    /// One system per spawned parent particle, following it until it dies.
    EventFollow,
    /// One system per spawned parent particle, left where the particle was born.
    EventSpawn,
    /// One system per dying parent particle, where it died.
    EventDeath,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Child {
    pub kind: ChildKind,
    /// Path of the child's particle file.
    pub name: String,
    pub offset: Affine,
    pub probability: f32,
    /// Most child systems of this entry alive at once.
    pub max_count: usize,
    pub control_point_start: usize,
    /// Bit 0: the parent's live particles drive the child's control points; bit 1: restart the
    /// child at every period start of the parent.
    pub flags: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ControlPoint {
    pub offset: Vec3,
    /// Bit 0 follows the pointer, bit 1 places the offset in scene space, bit 2 copies the parent
    /// system's control point `parent` (bit 3: without converting spaces).
    pub flags: u32,
    pub parent: usize,
}

/// Control point flag: follows the pointer.
pub const CP_POINTER: u32 = 0x1;
pub const CP_WORLD_OFFSET: u32 = 0x2;
pub const CP_PARENT: u32 = 0x4;
pub const CP_PARENT_RAW: u32 = 0x8;

#[derive(Debug, Clone, PartialEq)]
pub struct Definition {
    pub material: String,
    pub max_count: usize,
    /// Seconds simulated before the first frame.
    pub start_time: f32,
    pub flags: u32,
    pub random_frame: bool,
    pub sequence_multiplier: f32,
    pub emitters: Vec<Emitter>,
    pub initializers: Vec<Initializer>,
    pub operators: Vec<Operator>,
    pub renderers: Vec<Renderer>,
    pub control_points: [ControlPoint; CONTROL_POINTS],
    pub children: Vec<Child>,
    /// The colour a colour override is measured against, when the system defines its colour
    /// itself; without one an override tints the particles instead.
    pub reference_color: Option<Vec3>,
    /// Rope texture repeat: one texture length per `1 / uv_scale` segments.
    pub uv_scale: f32,
    pub rope_scrolling: bool,
    pub rope_smoothing: bool,
    pub trail_scrolling: bool,
    /// Component names this renderer does not know, as `section:name`.
    pub unknown: Vec<String>,
}

impl Definition {
    #[cfg(test)]
    pub fn parse_str(text: &str, two_d: bool) -> Result<Self, Error> {
        let value: Value =
            serde_json::from_str(text).map_err(|e| Error::Format(format!("particle JSON: {e}")))?;
        Self::from_json(&value, two_d)
    }

    pub fn from_json(value: &Value, two_d: bool) -> Result<Self, Error> {
        let map = value
            .as_object()
            .ok_or_else(|| Error::Format("particle system is not a JSON object".into()))?;
        let o = Obj { map, two_d };
        let random_frame = o.string("animationmode", "") == "randomframe";
        let mut flags = o.u32("flags", 0) & 0xff;
        if random_frame {
            flags |= FLAG_NO_FRAME_BLEND;
        }
        let mut def = Self {
            material: o.string("material", "").to_string(),
            max_count: (o.u32("maxcount", 0) as usize).min(MAX_PARTICLES_PER_SYSTEM),
            start_time: o.f32("starttime", 0.0),
            flags,
            random_frame,
            sequence_multiplier: match o.get("sequencemultiplier") {
                Some(Value::Number(n)) => n.as_f64().unwrap_or(1.0) as f32,
                _ => 1.0,
            },
            emitters: Vec::new(),
            initializers: Vec::new(),
            operators: Vec::new(),
            renderers: Vec::new(),
            control_points: [ControlPoint::default(); CONTROL_POINTS],
            children: Vec::new(),
            reference_color: None,
            uv_scale: 1.0,
            rope_scrolling: false,
            rope_smoothing: false,
            trail_scrolling: false,
            unknown: Vec::new(),
        };
        for item in objects(o.get("emitter")) {
            let c = Obj { map: item, two_d };
            match parse_emitter(&c) {
                Some(e) => def.emitters.push(e),
                None => def
                    .unknown
                    .push(format!("emitter:{}", c.string("name", ""))),
            }
        }
        // The last colour initializer sets the colour an override is measured against.
        let mut reference = None;
        for item in objects(o.get("initializer")) {
            let c = Obj { map: item, two_d };
            match parse_initializer(&c) {
                Some(i) => {
                    reference = initializer_color(&c, &i).or(reference);
                    def.initializers.push(i);
                }
                None => def
                    .unknown
                    .push(format!("initializer:{}", c.string("name", ""))),
            }
        }
        for item in objects(o.get("operator")) {
            let c = Obj { map: item, two_d };
            match parse_operator(&c) {
                Some(Some(op)) => def.operators.push(op),
                // Parsed, but it has no effect in the engine either (`collisionbox`).
                Some(None) => {}
                None => def
                    .unknown
                    .push(format!("operator:{}", c.string("name", ""))),
            }
        }
        match o.get("renderer") {
            Some(Value::Array(items)) => {
                for item in items.iter().filter_map(Value::as_object) {
                    let c = Obj { map: item, two_d };
                    match parse_renderer(&c, &mut def) {
                        Some(r) => def.renderers.push(r),
                        None => def
                            .unknown
                            .push(format!("renderer:{}", c.string("name", ""))),
                    }
                }
            }
            // A file without a renderer list draws sprites.
            _ => def.renderers.push(sprite_renderer(&Obj {
                map: &Map::new(),
                two_d,
            })),
        }
        if let Some(Value::Array(items)) = o.get("controlpoint") {
            // The position in the list is the index; `id` is ignored.
            for (slot, item) in items.iter().take(CONTROL_POINTS).enumerate() {
                if let Some(map) = item.as_object() {
                    let c = Obj { map, two_d };
                    def.control_points[slot] = ControlPoint {
                        offset: match c.get("offset") {
                            Some(Value::String(_)) => c.vec3("offset", Vec3::ZERO),
                            _ => Vec3::ZERO,
                        },
                        flags: c.u32("flags", 0),
                        parent: c.cp("parentcontrolpoint", 0),
                    };
                }
            }
        }
        for item in objects(o.get("children")) {
            let c = Obj { map: item, two_d };
            def.children.push(parse_child(&c));
        }
        def.reference_color = reference.or_else(|| {
            def.operators.iter().find_map(|op| match op.kind {
                OperatorKind::ColorChange { start, .. } => Some(start),
                _ => None,
            })
        });
        Ok(def)
    }

    pub fn world_space(&self) -> bool {
        self.flags & FLAG_WORLD_SPACE != 0
    }

    pub fn perspective(&self) -> bool {
        self.flags & FLAG_PERSPECTIVE != 0
    }

    /// Seconds per prewarm step: coarser for big systems.
    pub fn prewarm_step(&self) -> f32 {
        if self.max_count < 500 {
            0.05
        } else {
            0.2
        }
    }

    /// The trail renderer's history length, if the system has one.
    pub fn trail(&self) -> Option<(f32, u32)> {
        self.renderers.iter().find_map(|r| match r.kind {
            RendererKind::RopeTrail {
                length, segments, ..
            } => Some((length, segments)),
            _ => None,
        })
    }

    pub fn has_rope(&self) -> bool {
        self.renderers
            .iter()
            .any(|r| matches!(r.kind, RendererKind::Rope { .. }))
    }

    /// Mean lifetime of the first lifetime initializer; without one particles live the spawn
    /// default of one second.
    pub fn mean_lifetime(&self) -> f32 {
        self.initializers
            .iter()
            .find_map(|i| match i {
                Initializer::Lifetime { range, .. } => Some(range.at(0.5)),
                _ => None,
            })
            .unwrap_or(1.0)
    }
}

/// The colour a colour initializer centres on: the middle of its range as the file states it.
fn initializer_color(o: &Obj, init: &Initializer) -> Option<Vec3> {
    match init {
        Initializer::Color { range, .. } => Some(range.at(Vec3::splat(0.5))),
        Initializer::HsvColor { .. } => {
            let mid = |min: &str, max: &str, defaults: (f32, f32)| {
                (o.range(min, max, defaults).at(0.5)).clamp(0.0, 1.0)
            };
            Some(super::hsv_to_rgb(Vec3::new(
                mid("huemin", "huemax", (0.0, 1.0)),
                mid("saturationmin", "saturationmax", (0.5, 1.0)),
                mid("valuemin", "valuemax", (0.5, 1.0)),
            )))
        }
        Initializer::ColorList { colors, .. } => colors.first().map(|c| super::hsv_to_rgb(*c)),
        _ => None,
    }
}

/// A component object with the scene's dimension mode, read the way the engine reads it.
struct Obj<'a> {
    map: &'a Map<String, Value>,
    two_d: bool,
}

impl Obj<'_> {
    fn get(&self, key: &str) -> Option<&Value> {
        self.map.get(key)
    }

    /// The 3D or the 2D default.
    fn dim<T>(&self, three: T, two: T) -> T {
        if self.two_d {
            two
        } else {
            three
        }
    }

    fn f32(&self, key: &str, default: f32) -> f32 {
        match self.get(key) {
            None => default,
            Some(v) => number(v),
        }
    }

    fn u32(&self, key: &str, default: u32) -> u32 {
        match self.get(key) {
            None => default,
            // Truncated towards zero; negative values wrap like the engine's unsigned read.
            Some(v) => number(v) as i64 as u32,
        }
    }

    fn bool(&self, key: &str, default: bool) -> bool {
        match self.get(key) {
            None => default,
            Some(Value::Bool(b)) => *b,
            Some(Value::String(s)) => s == "true" || s == "1",
            Some(v) => number(v) != 0.0,
        }
    }

    fn string(&self, key: &str, default: &'static str) -> &str {
        match self.get(key) {
            Some(Value::String(s)) => s,
            Some(_) => "",
            None => default,
        }
    }

    fn vec3(&self, key: &str, default: Vec3) -> Vec3 {
        match self.get(key) {
            None => default,
            Some(v) => vector(v),
        }
    }

    /// A control point index, clamped into range (a negative value wraps to a huge one and so
    /// clamps to the last control point too).
    fn cp(&self, key: &str, default: u32) -> usize {
        (self.u32(key, default) as usize).min(CONTROL_POINTS - 1)
    }

    fn range(&self, min: &str, max: &str, defaults: (f32, f32)) -> Range {
        Range::new(self.f32(min, defaults.0), self.f32(max, defaults.1))
    }

    fn range3(&self, min: &str, max: &str, defaults: (Vec3, Vec3)) -> Range3 {
        Range3::new(self.vec3(min, defaults.0), self.vec3(max, defaults.1))
    }

    fn exponent(&self) -> f32 {
        self.f32("exponent", 1.0)
    }

    fn audio(&self) -> AudioResponse {
        let bounds = self.vec3("audioprocessingbounds", Vec3::new(0.8, 1.0, 0.0));
        let a = (self.u32("audioprocessingfrequencystart", 0) as usize).min(15);
        let b = (self.u32("audioprocessingfrequencyend", 1) as usize).min(15);
        AudioResponse {
            mode: self.u32("audioprocessingmode", 0).min(3) as u8,
            exponent: self.f32("audioprocessingexponent", 2.0),
            bounds: [bounds.x, bounds.y],
            bands: [a.min(b), a.max(b)],
        }
    }

    fn blend_window(&self) -> Option<BlendWindow> {
        let mut in_start = self.f32("blendinstart", 0.0);
        let in_end = self.f32("blendinend", 0.0);
        let out_start = self.f32("blendoutstart", 1.0);
        let mut out_end = self.f32("blendoutend", 1.0);
        in_start = in_start.min(in_end - 1.0e-4);
        out_end = out_end.max(out_start + 1.0e-4);
        // A window that covers the whole life (or is too narrow to matter) is no window.
        let active = (in_end > 0.01 || out_start < 0.99)
            && (out_start - in_end > 0.01
                || in_end - in_start > 0.01
                || out_end - out_start > 0.01);
        active.then(|| BlendWindow {
            start: in_start,
            in_inv: 1.0 / (in_end - in_start),
            end: out_end,
            out_inv: 1.0 / (out_end - out_start),
        })
    }

    fn remap(&self, default_input: &'static str) -> Remap {
        // Ranges accept a number for all three components.
        let range = |key: &str, default: f32| match self.get(key) {
            Some(v @ Value::Number(_)) => Vec3::splat(number(v)),
            _ => self.vec3(key, Vec3::splat(default)),
        };
        let input_min = range("inputrangemin", 0.0);
        let input_max = range("inputrangemax", 1.0);
        let output_min = range("outputrangemin", 0.0);
        let output_max = range("outputrangemax", 1.0);
        let span = (input_max - input_min).map(|s| if s == 0.0 { f32::EPSILON } else { s });
        let component = |key: &str| match self.string(key, "all") {
            "x" => Component::X,
            "y" => Component::Y,
            "z" => Component::Z,
            "sum" => Component::Sum,
            "average" => Component::Average,
            "max" => Component::Max,
            "min" => Component::Min,
            _ => Component::All,
        };
        Remap {
            operation: match self.string("operation", "multiply") {
                "remap" => RemapOperation::Set,
                "multiply" => RemapOperation::Multiply,
                "add" => RemapOperation::Add,
                "subtract" => RemapOperation::Subtract,
                _ => RemapOperation::None,
            },
            input: RemapValue::from_name(self.string("input", default_input)),
            output: RemapValue::from_name(self.string("output", "size")),
            input_component: component("inputcomponent"),
            output_component: component("outputcomponent"),
            transform: match self.string("transformfunction", "none") {
                "sine" => Transform::Sine,
                "square" => Transform::Square,
                "saw" => Transform::Saw,
                "triangle" => Transform::Triangle,
                "simplexnoise" => Transform::Noise,
                "fbmnoise" => Transform::Fbm,
                _ => Transform::None,
            },
            octaves: self.u32("transformoctaves", 3).clamp(1, 8),
            flags: self.u32("flags", 1),
            input_min,
            input_inv: span.map(|s| 1.0 / s),
            output_range: Range3::new(output_min, output_max),
            control_points: [
                self.cp("inputcontrolpoint0", 0),
                self.cp("outputcontrolpoint0", 0),
                self.cp("inputcontrolpoint1", 1),
                self.cp("outputcontrolpoint1", 1),
            ],
            scale: self.f32("transforminputscale", 2.0),
        }
    }

    fn collision(&self) -> Collision {
        Collision {
            bounce: -(1.0 + self.f32("bouncefactor", 0.5)),
            response: match self.string("collisionbehavior", "bounce") {
                "slide" => CollisionResponse::Slide,
                "stop" => CollisionResponse::Stop,
                "delete" => CollisionResponse::Delete,
                _ => CollisionResponse::Bounce,
            },
            flags: self.u32("flags", 0),
            control_point: self.cp("controlpoint", 0),
        }
    }
}

fn number(v: &Value) -> f32 {
    match v {
        Value::Number(n) => n.as_f64().unwrap_or(0.0) as f32,
        Value::Bool(b) => f32::from(u8::from(*b)),
        Value::String(s) => s.trim().parse().unwrap_or(0.0),
        _ => 0.0,
    }
}

/// A vector value: "x y z" with missing components zero. A bare number is taken for all three
/// components (the engine only accepts that for some keys; nothing valid relies on the rest).
fn vector(v: &Value) -> Vec3 {
    match v {
        Value::String(s) => {
            let mut parts = s.split_whitespace().map(leading_number);
            let x = parts.next().unwrap_or(0.0);
            let y = parts.next().unwrap_or(0.0);
            let z = parts.next().unwrap_or(0.0);
            Vec3::new(x, y, z)
        }
        Value::Number(_) | Value::Bool(_) => Vec3::splat(number(v)),
        _ => Vec3::ZERO,
    }
}

/// The number at the start of a token, like C's `atof` (trailing junk ignored, none gives 0).
fn leading_number(token: &str) -> f32 {
    (1..=token.len())
        .rev()
        .filter(|&n| token.is_char_boundary(n))
        .find_map(|n| token[..n].parse().ok())
        .unwrap_or(0.0)
}

fn objects(value: Option<&Value>) -> impl Iterator<Item = &Map<String, Value>> {
    value
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_object)
}

fn parse_emitter(o: &Obj) -> Option<Emitter> {
    let name = o.string("name", "");
    let (shape, origin, directions, speed, control_point, default_flags) = match name {
        "sphererandom" => {
            let sign = o.vec3("sign", Vec3::ZERO);
            (
                EmitterShape::Sphere {
                    distance: o.range("distancemin", "distancemax", (0.0, o.dim(1.0, 256.0))),
                    cone: -(o.f32("cone", 0.0) * PI).cos(),
                    sign,
                },
                o.vec3("origin", Vec3::ZERO),
                o.vec3("directions", Vec3::new(1.0, 1.0, 0.0)),
                o.range("speedmin", "speedmax", (0.0, 0.0)),
                o.cp("controlpoint", 0),
                if sign.length_squared() > f32::EPSILON {
                    EMIT_SIGN
                } else {
                    0
                },
            )
        }
        "boxrandom" => (
            EmitterShape::Box {
                distance: o.range3(
                    "distancemin",
                    "distancemax",
                    (Vec3::ZERO, o.dim(Vec3::ONE, Vec3::new(256.0, 256.0, 0.0))),
                ),
            },
            o.vec3("origin", Vec3::ZERO),
            o.vec3("directions", o.dim(Vec3::ONE, Vec3::new(1.0, 1.0, 0.0))),
            o.range("speedmin", "speedmax", (0.0, 0.0)),
            o.cp("controlpoint", 0),
            0,
        ),
        "layerimage" => (
            EmitterShape::LayerImage {
                offset: o.range3(
                    "offsetmin",
                    "offsetmax",
                    o.dim(
                        (Vec3::ZERO, Vec3::ZERO),
                        (Vec3::new(-5.0, -5.0, 0.0), Vec3::new(5.0, 5.0, 0.0)),
                    ),
                ),
            },
            Vec3::ZERO,
            Vec3::ONE,
            o.range("speedmin", "speedmax", (0.1, 0.2)),
            0,
            0,
        ),
        _ => return None,
    };
    let duration_min = o.f32("minperiodicduration", 2.0);
    let duration_max = o.f32("maxperiodicduration", 3.0);
    let delay_min = o.f32("minperiodicdelay", 1.0);
    let delay_max = o.f32("maxperiodicdelay", 2.0);
    let layer_default = if matches!(shape, EmitterShape::LayerImage { .. }) {
        0x10000
    } else {
        0
    };
    Some(Emitter {
        shape,
        origin,
        directions,
        speed,
        control_point,
        rate: o.f32("rate", 10.0),
        duration: o.f32("duration", 0.0),
        delay: o.f32("delay", 0.0),
        instantaneous: o.u32("instantaneous", 0),
        flags: o.u32("flags", layer_default) | default_flags,
        periodic_duration: Range::new(duration_min.min(duration_max), duration_max),
        periodic_delay: Range::new(delay_min.min(delay_max), delay_max),
        max_per_period: o.u32("maxtoemitperperiod", 0),
        audio: o.audio(),
    })
}

fn parse_initializer(o: &Obj) -> Option<Initializer> {
    let exponent = o.exponent();
    Some(match o.string("name", "") {
        "lifetimerandom" => Initializer::Lifetime {
            range: o.range("min", "max", (0.0, 1.0)),
            exponent,
        },
        "sizerandom" => Initializer::Size {
            range: o.range("min", "max", o.dim((0.001, 1.0), (5.0, 50.0))),
            exponent,
        },
        "alpharandom" => Initializer::Alpha {
            range: o.range("min", "max", (0.05, 1.0)),
            exponent,
        },
        "colorrandom" => Initializer::Color {
            range: Range3::new(
                o.vec3("min", Vec3::ZERO) * (1.0 / 255.0),
                o.vec3("max", Vec3::splat(255.0)) * (1.0 / 255.0),
            ),
            exponent,
        },
        "hsvcolorrandom" => {
            let hue_min = o.f32("huemin", 0.0);
            let hue_max = o.f32("huemax", 1.0);
            let steps = o.f32("huesteps", 6.0).max(0.0) as u32;
            let step = if steps > 1 {
                let range = if hue_max - hue_min == 0.0 {
                    1.0
                } else {
                    hue_max - hue_min
                };
                // A full turn of hue has as many steps as the count; a part of a turn includes
                // both ends.
                let n = if ((hue_max - hue_min) % 1.0).abs() < 1.0 / 360.0 {
                    steps
                } else {
                    steps - 1
                };
                range / n as f32
            } else {
                0.0
            };
            Initializer::HsvColor {
                hue_min,
                hue_range: hue_max - hue_min,
                hue_step: step,
                hue_steps: steps,
                saturation: o.range("saturationmin", "saturationmax", (0.5, 1.0)),
                value: o.range("valuemin", "valuemax", (0.5, 1.0)),
            }
        }
        "colorlist" => {
            let mut colors: Vec<Vec3> = match o.get("colors") {
                Some(Value::Array(items)) => items
                    .iter()
                    .filter_map(|c| match c {
                        // Entries with fewer than three components are dropped.
                        Value::String(s) if s.split_whitespace().count() >= 3 => {
                            Some(super::rgb_to_hsv(vector(c)))
                        }
                        _ => None,
                    })
                    .collect(),
                None => vec![super::rgb_to_hsv(Vec3::ONE)],
                Some(_) => Vec::new(),
            };
            if colors.is_empty() {
                colors.push(Vec3::new(0.0, 1.0, 1.0));
            }
            Initializer::ColorList {
                colors,
                noise: Vec3::new(
                    o.f32("huenoise", 0.0),
                    o.f32("saturationnoise", 0.0),
                    o.f32("valuenoise", 0.0),
                ),
                offset: Vec3::ZERO,
            }
        }
        "velocityrandom" => Initializer::Velocity {
            range: o.range3(
                "min",
                "max",
                o.dim(
                    (Vec3::splat(-1.0), Vec3::ONE),
                    (Vec3::new(-32.0, -32.0, 0.0), Vec3::new(32.0, 32.0, 0.0)),
                ),
            ),
            exponent,
        },
        "inheritcontrolpointvelocity" => Initializer::InheritControlPointVelocity {
            range: o.range("min", "max", (0.1, 0.2)),
            control_point: o.cp("controlpoint", 0),
        },
        "turbulentvelocityrandom" => Initializer::TurbulentVelocity {
            speed: o.range("speedmin", "speedmax", o.dim((0.5, 1.0), (100.0, 250.0))),
            phase: o.range("phasemin", "phasemax", (0.0, 0.1)),
            time_scale: o.f32("timescale", 1.0),
            scale: o.f32("scale", 1.0),
            offset: o.f32("offset", 0.0),
            forward: o.vec3("forward", Vec3::Y),
            right: o.vec3("right", Vec3::Z),
        },
        "rotationrandom" => {
            // A bare number is a rotation about z.
            let read = |key: &str, default: Vec3| match o.get(key) {
                Some(v @ Value::Number(_)) => Vec3::new(0.0, 0.0, number(v)),
                _ => o.vec3(key, default),
            };
            Initializer::Rotation {
                range: Range3::new(
                    read("min", Vec3::ZERO),
                    read("max", Vec3::new(0.0, 0.0, TAU)),
                ),
                exponent,
            }
        }
        "positionoffsetrandom" => {
            let sign = o.vec3("sign", Vec3::ZERO);
            Initializer::PositionOffset {
                directions: o.vec3("directions", o.dim(Vec3::ONE, Vec3::new(1.0, 1.0, 0.0))),
                sign,
                signed: sign.length_squared() > f32::EPSILON,
                scale: o.f32("scale", o.dim(1.0, 0.001)),
                distance: o.f32("distance", o.dim(0.1, 100.0)),
                time_scale: o.f32("timescale", 1.0),
                octaves: o.u32("octaves", 6).clamp(1, 8),
            }
        }
        "angularvelocityrandom" => Initializer::AngularVelocity {
            range: o.range3(
                "min",
                "max",
                (Vec3::new(0.0, 0.0, -5.0), Vec3::new(0.0, 0.0, 5.0)),
            ),
            exponent,
        },
        "mapsequencearoundcontrolpoint" => {
            let axis = o.vec3("axis", Vec3::Z).normalized_or(Vec3::Z);
            let (right, up) = if axis.x == 0.0 && axis.y == 0.0 {
                (Vec3::X, Vec3::Y)
            } else {
                let right = axis.cross(Vec3::Z).normalized_or(Vec3::X);
                (right, axis.cross(right).normalized_or(Vec3::Y))
            };
            let bounds = o.vec3("bounds", Vec3::new(0.0, 1.0, 0.0));
            Initializer::MapAround {
                count: o.f32("count", 32.0),
                bounds: Range::new(bounds.x, bounds.y),
                speed: o.range3("speedmin", "speedmax", (Vec3::ZERO, Vec3::ZERO)),
                axis,
                right,
                up,
                mirror: o.string("limitbehavior", "repeat") == "mirror",
                control_point: o.cp("controlpoint", 0),
                flags: o.u32("flags", 0),
            }
        }
        "mapsequencebetweencontrolpoints" => {
            let bounds = o.vec3("bounds", Vec3::new(0.0, 1.0, 0.0));
            Initializer::MapBetween {
                count: o.f32("count", 32.0),
                bounds: Range::new(bounds.x, bounds.y),
                mirror: o.string("limitbehavior", "repeat") == "mirror",
                start: o.cp("controlpointstart", 0),
                end: o.cp("controlpointend", 1),
                flags: o.u32("flags", 0),
                arc_amount: o.f32("arcamount", 0.3),
                arc_direction: o.vec3("arcdirection", Vec3::Y),
                size_reduction: o.f32("sizereductionamount", 0.9),
            }
        }
        "remapinitialvalue" => Initializer::Remap(o.remap("maxlifetime")),
        "inheritinitialvaluefromevent" => {
            Initializer::InheritFromEvent(EventValue::from_name(o.string("input", "setcolor")))
        }
        _ => return None,
    })
}

/// `None` for an unknown name, `Some(None)` for a known operator that does nothing.
fn parse_operator(o: &Obj) -> Option<Option<Operator>> {
    let change = || {
        let start = o.f32("startvalue", 1.0);
        let end = o.f32("endvalue", 0.0);
        let time = o.f32("starttime", 0.0);
        Change {
            start,
            delta: end - start,
            time,
            inv: 1.0 / (o.f32("endtime", 1.0) - time),
        }
    };
    let oscillate = |frequency: (f32, f32), scale: (f32, f32)| Oscillate {
        frequency: o.range("frequencymin", "frequencymax", frequency),
        phase: o.range("phasemin", "phasemax", (0.0, TAU)),
        scale: o.range("scalemin", "scalemax", scale),
    };
    let distance_span = |inner: f32, outer: f32| {
        if outer == inner {
            1.0
        } else {
            1.0 / (outer - inner)
        }
    };
    let name = o.string("name", "");
    let blendable = matches!(
        name,
        "angularmovement"
            | "oscillateposition"
            | "oscillatealpha"
            | "oscillatesize"
            | "controlpointattract"
            | "maintaindistancetocontrolpoint"
            | "maintaindistancebetweencontrolpoints"
            | "reducemovementnearcontrolpoint"
            | "turbulence"
            | "vortex_v2"
            | "capvelocity"
            | "remapvalue"
            | "inheritvaluefromevent"
    );
    let kind = match name {
        "movement" => OperatorKind::Movement {
            gravity: o.vec3("gravity", Vec3::ZERO),
            drag: o.f32("drag", 0.0),
            local_gravity: o.u32("flags", 0) & 1 != 0,
        },
        "angularmovement" => OperatorKind::AngularMovement {
            force: o.vec3("force", Vec3::ZERO),
            drag: o.f32("drag", 0.0),
        },
        "alphafade" => OperatorKind::AlphaFade {
            fade_in: o.f32("fadeintime", 0.5),
            fade_out: o.f32("fadeouttime", 0.5),
        },
        "sizechange" => OperatorKind::SizeChange(change()),
        "alphachange" => OperatorKind::AlphaChange(change()),
        "colorchange" => {
            let start = o.vec3("startvalue", Vec3::ONE);
            let time = o.f32("starttime", 0.0);
            OperatorKind::ColorChange {
                start,
                delta: o.vec3("endvalue", Vec3::ZERO) - start,
                time,
                inv: 1.0 / (o.f32("endtime", 1.0) - time),
            }
        }
        "oscillateposition" => OperatorKind::OscillatePosition {
            mask: o.vec3("mask", Vec3::new(1.0, 1.0, 0.0)),
            osc: oscillate((1.0, 5.0), (0.0, o.dim(0.5, 10.0))),
        },
        "oscillatealpha" => OperatorKind::OscillateAlpha(oscillate((1.0, 10.0), (0.0, 1.0))),
        "oscillatesize" => OperatorKind::OscillateSize(oscillate((1.0, 10.0), (0.8, 1.2))),
        // The attraction centre is the control point itself; `offset` is parsed by the engine
        // but never used.
        "controlpointattract" => OperatorKind::ControlPointAttract {
            scale: o.f32("scale", o.dim(20.0, 512.0)),
            threshold: o.f32("threshold", o.dim(5.0, 512.0)),
            delete_threshold_sq: o.f32("deletethreshold", o.dim(0.5, 15.0)).powi(2),
            control_point: o.cp("controlpoint", 0),
            flags: o.u32("flags", 2),
        },
        "maintaindistancetocontrolpoint" => OperatorKind::MaintainDistance {
            distance: o.f32("distance", o.dim(1.0, 200.0)),
            variable_strength: o.f32("variablestrength", 0.0),
            control_point: o.cp("controlpoint", 0),
        },
        "maintaindistancebetweencontrolpoints" => OperatorKind::MaintainBetween {
            start: o.cp("controlpointstart", 0),
            end: o.cp("controlpointend", 1),
        },
        "reducemovementnearcontrolpoint" => {
            let inner = o.f32("distanceinner", o.dim(0.5, 100.0));
            let outer = o.f32("distanceouter", o.dim(1.0, 350.0));
            let reduction_inner = o.f32("reductioninner", 100.0);
            let reduction_outer = o.f32("reductionouter", 0.0);
            OperatorKind::ReduceMovement {
                control_point: o.cp("controlpoint", 0),
                inner,
                inv_span: distance_span(inner, outer),
                reduction_inner,
                reduction_span: if reduction_outer == reduction_inner {
                    1.0
                } else {
                    reduction_outer - reduction_inner
                },
            }
        }
        "turbulence" => OperatorKind::Turbulence {
            mask: o.vec3("mask", o.dim(Vec3::ONE, Vec3::new(1.0, 1.0, 0.0))),
            scale: o.f32("scale", o.dim(0.5, 0.01)),
            speed: o.range("speedmin", "speedmax", o.dim((1.0, 5.0), (500.0, 1000.0))),
            phase_span: o.f32("phasemax", 0.0) - o.f32("phasemin", 0.0),
            time_scale: o.f32("timescale", o.dim(1.0, 20.0)),
            audio: o.audio(),
        },
        "vortex" => {
            let inner = o.f32("distanceinner", o.dim(1.0, 500.0));
            let outer = o.f32("distanceouter", o.dim(2.0, 650.0));
            let speed_inner = o.f32("speedinner", o.dim(1.0, 2500.0));
            OperatorKind::Vortex {
                offset: o.vec3("offset", Vec3::ZERO),
                axis: vortex_axis(o),
                inner,
                inv_span: distance_span(inner, outer),
                speed_inner,
                speed_span: o.f32("speedouter", 0.0) - speed_inner,
                axial: o.u32("flags", 0) & 1 != 0,
                control_point: o.cp("controlpoint", 0),
                audio: o.audio(),
            }
        }
        "vortex_v2" => {
            let flags = o.u32("flags", 0);
            let ring = flags & 4 != 0;
            let inner_distance = o.f32("distanceinner", o.dim(1.0, 500.0));
            let outer_distance = o.f32("distanceouter", o.dim(2.0, 650.0));
            let ring_width = o.f32("ringwidth", o.dim(0.2, 50.0));
            let pull_distance = o.f32("ringpulldistance", o.dim(0.25, 50.0));
            let speed_inner = o.f32("speedinner", o.dim(1.0, 2500.0));
            // In ring mode the distance band is the ring's width and pull distance.
            let (inner, inv_span) = if ring {
                (ring_width, 1.0 / pull_distance)
            } else {
                (
                    inner_distance,
                    distance_span(inner_distance, outer_distance),
                )
            };
            OperatorKind::VortexV2 {
                axis: vortex_axis(o),
                inner,
                inv_span,
                speed_inner,
                speed_span: o.f32("speedouter", 0.0) - speed_inner,
                axial: flags & 1 != 0,
                center_force: if flags & 2 != 0 {
                    o.f32("centerforce", 1.0)
                } else {
                    0.0
                },
                ring_radius: o.f32("ringradius", o.dim(1.0, 300.0)),
                ring_pull_force: o.f32("ringpullforce", o.dim(0.05, 10.0)),
                ring,
                control_point: o.cp("controlpoint", 0),
                audio: o.audio(),
            }
        }
        "boids" => OperatorKind::Boids {
            separation_threshold: o.f32("separationthreshold", o.dim(0.02, 20.0)),
            neighbor_threshold: o.f32("neighborthreshold", o.dim(0.2, 50.0)),
            max_speed: o.f32("maxspeed", o.dim(1.0, 500.0)),
            separation: o.f32("separationfactor", 15.0),
            alignment: o.f32("alignmentfactor", 1.0),
            cohesion: o.f32("cohesionfactor", 2.0),
            flags: o.u32("flags", 1),
        },
        "capvelocity" => OperatorKind::CapVelocity {
            max_speed: o.f32("maxspeed", o.dim(1.0, 100.0)),
        },
        "remapvalue" => OperatorKind::Remap(o.remap("lifetimefraction")),
        "inheritvaluefromevent" => OperatorKind::InheritFromEvent(EventValue::from_name(
            o.string("input", "setcoloropacity"),
        )),
        "collisionplane" => OperatorKind::CollisionPlane {
            collision: o.collision(),
            normal: o.vec3("plane", Vec3::Y).normalized_or(Vec3::Y),
            distance: o.f32("distance", o.dim(0.0, -150.0)),
        },
        "collisionsphere" => OperatorKind::CollisionSphere {
            collision: o.collision(),
            center: o.vec3("origin", o.dim(Vec3::ZERO, Vec3::new(0.0, -200.0, 0.0))),
            radius: o.f32("radius", o.dim(1.0, 50.0)),
        },
        "collisionbounds" => OperatorKind::CollisionBounds {
            collision: o.collision(),
        },
        "collisionquad" => {
            let normal = o.vec3("plane", Vec3::Y).normalized_or(Vec3::Y);
            let side = normal
                .cross(o.vec3("forward", Vec3::Z))
                .normalized_or(Vec3::X);
            let size = o.vec3(
                "size",
                o.dim(Vec3::new(1.0, 1.0, 0.0), Vec3::new(200.0, 200.0, 0.0)),
            );
            OperatorKind::CollisionQuad {
                collision: o.collision(),
                origin: o.vec3("origin", o.dim(Vec3::ZERO, Vec3::new(0.0, -150.0, 0.0))),
                normal,
                forward: side.cross(normal).normalized_or(Vec3::Z),
                side,
                half_size: [size.x * 0.5, size.y * 0.5],
            }
        }
        // The engine parses these but its box collision does nothing, and a model collision
        // needs a puppet's collision capsules, which this renderer does not load.
        "collisionbox" | "collisionmodel" => return Some(None),
        _ => return None,
    };
    Some(Some(Operator {
        kind,
        blend: if blendable { o.blend_window() } else { None },
    }))
}

fn vortex_axis(o: &Obj) -> Vec3 {
    let axis = o.vec3("axis", Vec3::Z);
    if axis.length_squared() < 0.001 {
        Vec3::Z
    } else {
        axis.normalized_or(Vec3::Z)
    }
}

fn sprite_renderer(o: &Obj) -> Renderer {
    let axis = o.vec3("axis", Vec3::ZERO);
    let axis = if axis == Vec3::ZERO {
        Vec3::Y
    } else {
        axis.normalized_or(Vec3::Y)
    };
    // The fixed orientation's second direction: perpendicular to the axis and to its sideways
    // direction (y x axis), or -z for the default axis y.
    let forward = if axis.x != 0.0 || axis.z != 0.0 {
        let right = Vec3::Y.cross(axis).normalized_or(Vec3::X);
        axis.cross(right).normalized_or(-Vec3::Z)
    } else {
        -Vec3::Z
    };
    Renderer {
        kind: RendererKind::Sprite,
        orientation: match o.string("orientation", "screen") {
            "upright" => 1,
            "fixed" => 2,
            _ => 0,
        },
        axis,
        forward,
        flags: o.u32("flags", 0) as u8,
    }
}

fn parse_renderer(o: &Obj, def: &mut Definition) -> Option<Renderer> {
    let mut renderer = sprite_renderer(o);
    let uv_scale = || {
        let s = o.f32("uvscale", 1.0);
        if s != 0.0 {
            1.0 / s
        } else {
            1.0
        }
    };
    renderer.kind = match o.string("name", "") {
        "sprite" => RendererKind::Sprite,
        "spritetrail" => RendererKind::SpriteTrail {
            length: o.f32("length", 0.05),
            max_length: o.f32("maxlength", 10.0),
            min_length: o.f32("minlength", 0.0),
        },
        "rope" => {
            def.uv_scale = uv_scale();
            def.rope_scrolling = o.bool("uvscrolling", false);
            def.rope_smoothing = !def.rope_scrolling && o.bool("uvsmoothing", true);
            RendererKind::Rope {
                subdivision: o.u32("subdivision", 4).min(32),
            }
        }
        "ropetrail" => {
            def.uv_scale = uv_scale();
            def.trail_scrolling = o.bool("uvscrolling", false);
            RendererKind::RopeTrail {
                length: o.f32("length", 1.0).max(0.001),
                segments: o.u32("segments", 4).clamp(2, 32),
                fade_alpha: o.bool("fadealpha", false),
                fade_size: o.bool("fadesize", false),
            }
        }
        _ => return None,
    };
    Some(renderer)
}

fn parse_child(o: &Obj) -> Child {
    let kind = match o.string("type", "static") {
        "eventfollow" => ChildKind::EventFollow,
        "eventspawn" => ChildKind::EventSpawn,
        "eventdeath" => ChildKind::EventDeath,
        _ => ChildKind::Static,
    };
    let event = kind != ChildKind::Static;
    Child {
        kind,
        name: o.string("name", "").to_string(),
        offset: Affine::from_trs(
            o.vec3("origin", Vec3::ZERO),
            o.vec3("angles", Vec3::ZERO),
            o.vec3("scale", Vec3::ONE),
        ),
        probability: if event {
            o.f32("probability", 1.0)
        } else {
            1.0
        },
        max_count: if event {
            o.u32("maxcount", 10) as usize
        } else {
            10
        },
        control_point_start: o.cp("controlpointstartindex", 0),
        flags: o.u32("flags", 0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(json: &str, two_d: bool) -> Definition {
        Definition::parse_str(json, two_d).expect("parses")
    }

    #[test]
    fn absent_keys_take_the_defaults_of_the_scene_kind() {
        let json = r#"{"emitter": [{"name": "boxrandom"}],
                       "initializer": [{"name": "sizerandom"}, {"name": "velocityrandom"}],
                       "operator": [{"name": "turbulence"}]}"#;
        let flat = parse(json, true);
        let deep = parse(json, false);
        assert_eq!(flat.emitters[0].rate, 10.0);
        assert_eq!(
            flat.emitters[0].shape,
            EmitterShape::Box {
                distance: Range3::new(Vec3::ZERO, Vec3::new(256.0, 256.0, 0.0))
            }
        );
        assert_eq!(flat.initializers[0], Initializer::Size { range: Range::new(5.0, 50.0), exponent: 1.0 });
        assert_eq!(deep.initializers[0], Initializer::Size { range: Range::new(0.001, 1.0), exponent: 1.0 });
        assert!(matches!(flat.operators[0].kind, OperatorKind::Turbulence { time_scale, .. } if time_scale == 20.0));
        // A file without a renderer list draws sprites.
        assert_eq!(flat.renderers.len(), 1);
        assert_eq!(flat.renderers[0].kind, RendererKind::Sprite);
    }

    #[test]
    fn vectors_fill_missing_components_with_zero() {
        let d = parse(
            r#"{"emitter": [{"name": "sphererandom", "origin": "5", "directions": "1 2"}],
                "initializer": [{"name": "rotationrandom", "min": -0.4, "max": -0.3},
                                {"name": "colorrandom", "min": "255 0 0", "max": "0 0 255"}]}"#,
            true,
        );
        assert_eq!(d.emitters[0].origin, Vec3::new(5.0, 0.0, 0.0));
        assert_eq!(d.emitters[0].directions, Vec3::new(1.0, 2.0, 0.0));
        // A bare rotation is about z; colours are 0..255 in the file.
        assert_eq!(
            d.initializers[0],
            Initializer::Rotation {
                range: Range3::new(Vec3::new(0.0, 0.0, -0.4), Vec3::new(0.0, 0.0, -0.3)),
                exponent: 1.0
            }
        );
        let Initializer::Color { range, .. } = &d.initializers[1] else {
            panic!("colour");
        };
        assert_eq!(range.min, Vec3::new(1.0, 0.0, 0.0));
        assert_eq!(d.reference_color, Some(Vec3::new(0.5, 0.0, 0.5)));
    }

    #[test]
    fn system_fields_flags_and_children() {
        let d = parse(
            r#"{"maxcount": 12, "starttime": 3, "flags": 261, "animationmode": "randomframe",
                "controlpoint": [{"id": 5, "offset": "1 2 3"}, {"flags": 1, "offset": 7}],
                "children": [{"name": "a.json", "type": "eventdeath", "probability": 0.5},
                             {"name": "b.json", "maxcount": 3}]}"#,
            true,
        );
        assert_eq!(d.max_count, 12);
        assert_eq!(d.start_time, 3.0);
        // Only the low byte counts; random frames never blend.
        assert_eq!(d.flags, 0x5 | FLAG_NO_FRAME_BLEND);
        assert!(d.random_frame && d.world_space() && d.perspective());
        // The list position is the index, and only a string offset is read.
        assert_eq!(d.control_points[0].offset, Vec3::new(1.0, 2.0, 3.0));
        assert_eq!(d.control_points[1].offset, Vec3::ZERO);
        assert_eq!(d.control_points[1].flags, CP_POINTER);
        assert_eq!(d.children[0].kind, ChildKind::EventDeath);
        assert_eq!(d.children[0].probability, 0.5);
        // Static children ignore probability and count.
        assert_eq!((d.children[1].kind, d.children[1].max_count), (ChildKind::Static, 10));
    }

    #[test]
    fn blend_windows_only_exist_when_they_matter() {
        let d = parse(
            r#"{"operator": [{"name": "turbulence"},
                             {"name": "turbulence", "blendinstart": 0.1, "blendinend": 0.5},
                             {"name": "movement", "blendinstart": 0.1, "blendinend": 0.5}]}"#,
            true,
        );
        assert_eq!(d.operators[0].blend, None);
        let window = d.operators[1].blend.expect("window");
        assert!((window.weight(0.3) - 0.5).abs() < 1.0e-5);
        assert_eq!(window.weight(0.8), 1.0);
        // Movement has no blend window.
        assert_eq!(d.operators[2].blend, None);
    }

    #[test]
    fn hue_steps_split_the_hue_range() {
        let d = parse(
            r#"{"initializer": [{"name": "hsvcolorrandom", "huemin": 0, "huemax": 1, "huesteps": 4},
                                {"name": "hsvcolorrandom", "huemin": 0, "huemax": 0.5, "huesteps": 3}]}"#,
            true,
        );
        // A full turn has as many steps as asked; a part of a turn includes both ends.
        assert!(matches!(d.initializers[0], Initializer::HsvColor { hue_step, .. } if hue_step == 0.25));
        assert!(matches!(d.initializers[1], Initializer::HsvColor { hue_step, .. } if hue_step == 0.25));
    }

    #[test]
    fn unknown_components_are_skipped_and_reported() {
        let d = parse(
            r#"{"emitter": [{"name": "weird"}], "operator": [{"name": "collisionbox"}, {"name": "odd"}]}"#,
            true,
        );
        assert!(d.emitters.is_empty() && d.operators.is_empty());
        assert_eq!(d.unknown.len(), 2);
    }

    #[test]
    #[ignore = "needs the local Wallpaper Engine assets"]
    fn parses_all_shared_particle_assets() {
        let Some(home) = std::env::var_os("HOME") else {
            return;
        };
        let root = std::path::PathBuf::from(home)
            .join("Library/Application Support/WallpaperMage/WallpaperEngineAssets");
        let mut stack = vec![root];
        let (mut systems, mut unknown) = (0usize, Vec::new());
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                    continue;
                }
                let Ok(text) = std::fs::read_to_string(&path) else {
                    continue;
                };
                let Ok(value) = serde_json::from_str::<Value>(&text) else {
                    continue;
                };
                if value.get("emitter").is_none() || value.get("material").is_none() {
                    continue;
                }
                let def = Definition::from_json(&value, true).expect("system parses");
                systems += 1;
                unknown.extend(def.unknown.iter().map(|u| format!("{}: {u}", path.display())));
                let tree = super::super::Tree::new(def, &mut |_| None);
                let mut sim = super::super::Simulation::new(tree, Default::default(), 1);
                sim.advance_to(5.0);
            }
        }
        assert!(systems > 100, "only {systems} particle systems found");
        assert!(unknown.is_empty(), "{unknown:#?}");
    }
}
