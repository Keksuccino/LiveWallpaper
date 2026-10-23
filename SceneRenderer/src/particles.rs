//! Particle-system model and a deterministic CPU simulation.
//!
//! The JSON shapes here were derived from the particle files of the four local scenes and from the
//! particle presets in `WallpaperEngineAssets`. Every field and every operator/initializer/renderer
//! name in the model occurs in at least one of those files. Unknown names and fields are kept in
//! `ParticleSystem::unknown_fields` instead of being rejected, so a future package still loads.

use std::sync::Arc;

use serde_json::{Map, Value};

use crate::Error;

/// Hard ceiling per system. `maxcount` is clamped to this so a malformed package cannot make the
/// simulation allocate without bound. The largest `maxcount` in the local scenes is 100000 (Angel's
/// starfield) and this constant equals it, so no local system is reduced.
pub const MAX_PARTICLES_PER_SYSTEM: usize = 100_000;

/// A trail renderer keeps at most this many historical positions per particle. The rope/spritetrail
/// presets ask for far fewer; this is a guard for malformed `segments`/`subdivision` values.
pub const MAX_TRAIL_POINTS: usize = 32;

/// Fixed simulation step. `step` accumulates real time and always advances in whole steps of this
/// size, so the same seed and the same total time give the same state.
pub const FIXED_DT: f32 = 1.0 / 60.0;

const TAU: f32 = std::f32::consts::TAU;
const DEFAULT_LIFETIME: f32 = 5.0;
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

    pub fn normalized_or_zero(self) -> Self {
        let len = self.length();
        if len > EPS {
            self * (1.0 / len)
        } else {
            Self::ZERO
        }
    }

    pub fn lerp(self, o: Self, t: f32) -> Self {
        self + (o - self) * t
    }

    pub fn abs(self) -> Self {
        Self::new(self.x.abs(), self.y.abs(), self.z.abs())
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

impl std::ops::MulAssign for Vec3 {
    fn mul_assign(&mut self, o: Self) {
        *self = *self * o;
    }
}

impl std::ops::Mul for Vec3 {
    type Output = Self;
    fn mul(self, o: Self) -> Self {
        Self::new(self.x * o.x, self.y * o.y, self.z * o.z)
    }
}

impl std::ops::Neg for Vec3 {
    type Output = Self;
    fn neg(self) -> Self {
        Self::new(-self.x, -self.y, -self.z)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EmitterKind {
    SphereRandom,
    BoxRandom,
    Unknown(String),
}

impl EmitterKind {
    fn from_name(name: &str) -> Self {
        match name {
            "sphererandom" => Self::SphereRandom,
            "boxrandom" => Self::BoxRandom,
            other => Self::Unknown(other.to_string()),
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::SphereRandom => "sphererandom",
            Self::BoxRandom => "boxrandom",
            Self::Unknown(name) => name,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InitializerKind {
    LifetimeRandom,
    SizeRandom,
    ColorRandom,
    HsvColorRandom,
    VelocityRandom,
    RotationRandom,
    AngularVelocityRandom,
    AlphaRandom,
    TurbulentVelocityRandom,
    MapSequenceBetweenControlPoints,
    MapSequenceAroundControlPoint,
    PositionOffsetRandom,
    RemapInitialValue,
    Unknown(String),
}

impl InitializerKind {
    fn from_name(name: &str) -> Self {
        match name {
            "lifetimerandom" => Self::LifetimeRandom,
            "sizerandom" => Self::SizeRandom,
            "colorrandom" => Self::ColorRandom,
            "hsvcolorrandom" => Self::HsvColorRandom,
            "velocityrandom" => Self::VelocityRandom,
            "rotationrandom" => Self::RotationRandom,
            "angularvelocityrandom" => Self::AngularVelocityRandom,
            "alpharandom" => Self::AlphaRandom,
            "turbulentvelocityrandom" => Self::TurbulentVelocityRandom,
            "mapsequencebetweencontrolpoints" => Self::MapSequenceBetweenControlPoints,
            "mapsequencearoundcontrolpoint" => Self::MapSequenceAroundControlPoint,
            "positionoffsetrandom" => Self::PositionOffsetRandom,
            "remapinitialvalue" => Self::RemapInitialValue,
            other => Self::Unknown(other.to_string()),
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::LifetimeRandom => "lifetimerandom",
            Self::SizeRandom => "sizerandom",
            Self::ColorRandom => "colorrandom",
            Self::HsvColorRandom => "hsvcolorrandom",
            Self::VelocityRandom => "velocityrandom",
            Self::RotationRandom => "rotationrandom",
            Self::AngularVelocityRandom => "angularvelocityrandom",
            Self::AlphaRandom => "alpharandom",
            Self::TurbulentVelocityRandom => "turbulentvelocityrandom",
            Self::MapSequenceBetweenControlPoints => "mapsequencebetweencontrolpoints",
            Self::MapSequenceAroundControlPoint => "mapsequencearoundcontrolpoint",
            Self::PositionOffsetRandom => "positionoffsetrandom",
            Self::RemapInitialValue => "remapinitialvalue",
            Self::Unknown(name) => name,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OperatorKind {
    Movement,
    AngularMovement,
    AlphaFade,
    AlphaChange,
    SizeChange,
    ColorChange,
    OscillateAlpha,
    OscillatePosition,
    OscillateSize,
    Turbulence,
    Vortex,
    VortexV2,
    ControlPointAttract,
    Boids,
    CapVelocity,
    MaintainDistanceBetweenControlPoints,
    MaintainDistanceToControlPoint,
    ReduceMovementNearControlPoint,
    RemapValue,
    Unknown(String),
}

impl OperatorKind {
    fn from_name(name: &str) -> Self {
        match name {
            "movement" => Self::Movement,
            "angularmovement" => Self::AngularMovement,
            "alphafade" => Self::AlphaFade,
            "alphachange" => Self::AlphaChange,
            "sizechange" => Self::SizeChange,
            "colorchange" => Self::ColorChange,
            "oscillatealpha" => Self::OscillateAlpha,
            "oscillateposition" => Self::OscillatePosition,
            "oscillatesize" => Self::OscillateSize,
            "turbulence" => Self::Turbulence,
            "vortex" => Self::Vortex,
            "vortex_v2" => Self::VortexV2,
            "controlpointattract" => Self::ControlPointAttract,
            "boids" => Self::Boids,
            "capvelocity" => Self::CapVelocity,
            "maintaindistancebetweencontrolpoints" => Self::MaintainDistanceBetweenControlPoints,
            "maintaindistancetocontrolpoint" => Self::MaintainDistanceToControlPoint,
            "reducemovementnearcontrolpoint" => Self::ReduceMovementNearControlPoint,
            "remapvalue" => Self::RemapValue,
            other => Self::Unknown(other.to_string()),
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::Movement => "movement",
            Self::AngularMovement => "angularmovement",
            Self::AlphaFade => "alphafade",
            Self::AlphaChange => "alphachange",
            Self::SizeChange => "sizechange",
            Self::ColorChange => "colorchange",
            Self::OscillateAlpha => "oscillatealpha",
            Self::OscillatePosition => "oscillateposition",
            Self::OscillateSize => "oscillatesize",
            Self::Turbulence => "turbulence",
            Self::Vortex => "vortex",
            Self::VortexV2 => "vortex_v2",
            Self::ControlPointAttract => "controlpointattract",
            Self::Boids => "boids",
            Self::CapVelocity => "capvelocity",
            Self::MaintainDistanceBetweenControlPoints => "maintaindistancebetweencontrolpoints",
            Self::MaintainDistanceToControlPoint => "maintaindistancetocontrolpoint",
            Self::ReduceMovementNearControlPoint => "reducemovementnearcontrolpoint",
            Self::RemapValue => "remapvalue",
            Self::Unknown(name) => name,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RendererKind {
    Sprite,
    SpriteTrail,
    Rope,
    RopeTrail,
    Unknown(String),
}

impl RendererKind {
    fn from_name(name: &str) -> Self {
        match name {
            "sprite" => Self::Sprite,
            "spritetrail" => Self::SpriteTrail,
            "rope" => Self::Rope,
            "ropetrail" => Self::RopeTrail,
            other => Self::Unknown(other.to_string()),
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::Sprite => "sprite",
            Self::SpriteTrail => "spritetrail",
            Self::Rope => "rope",
            Self::RopeTrail => "ropetrail",
            Self::Unknown(name) => name,
        }
    }

    pub fn is_trail(&self) -> bool {
        matches!(self, Self::SpriteTrail | Self::RopeTrail)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChildKind {
    EventDeath,
    EventFollow,
    Static,
    Unknown(String),
}

impl ChildKind {
    fn from_name(name: &str) -> Self {
        match name {
            "eventdeath" => Self::EventDeath,
            "eventfollow" => Self::EventFollow,
            "static" => Self::Static,
            other => Self::Unknown(other.to_string()),
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::EventDeath => "eventdeath",
            Self::EventFollow => "eventfollow",
            Self::Static => "static",
            Self::Unknown(name) => name,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Emitter {
    pub id: i32,
    pub kind: EmitterKind,
    pub rate: f32,
    pub origin: Vec3,
    pub directions: Vec3,
    pub distance_min: Vec3,
    pub distance_max: Vec3,
    pub speed_min: Option<f32>,
    pub speed_max: Option<f32>,
    pub instantaneous: bool,
    pub flags: u32,
    pub delay: Option<f32>,
    pub duration: Option<f32>,
    pub min_periodic_delay: Option<f32>,
    pub max_periodic_delay: Option<f32>,
    pub min_periodic_duration: Option<f32>,
    pub max_periodic_duration: Option<f32>,
    pub max_to_emit_per_period: Option<f32>,
    pub cone: Option<f32>,
    pub sign: Option<f32>,
    pub control_point: Option<usize>,
}

impl Default for Emitter {
    fn default() -> Self {
        Self {
            id: 0,
            kind: EmitterKind::SphereRandom,
            rate: 0.0,
            origin: Vec3::ZERO,
            directions: Vec3::ONE,
            distance_min: Vec3::ZERO,
            distance_max: Vec3::ZERO,
            speed_min: None,
            speed_max: None,
            instantaneous: false,
            flags: 0,
            delay: None,
            duration: None,
            min_periodic_delay: None,
            max_periodic_delay: None,
            min_periodic_duration: None,
            max_periodic_duration: None,
            max_to_emit_per_period: None,
            cone: None,
            sign: None,
            control_point: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Initializer {
    pub id: i32,
    pub kind: InitializerKind,
    pub min: Option<Vec3>,
    pub max: Option<Vec3>,
    pub exponent: f32,
    pub scale: Option<f32>,
    pub offset: Option<f32>,
    pub speed_min: Option<f32>,
    pub speed_max: Option<f32>,
    pub phase_min: Option<f32>,
    pub phase_max: Option<f32>,
    pub time_scale: Option<f32>,
    pub distance: Option<f32>,
    pub count: Option<f32>,
    pub axis: Option<Vec3>,
    pub bounds: Option<Vec3>,
    pub limit_behavior: Option<String>,
    pub input: Option<String>,
    pub input_control_point0: Option<usize>,
    pub input_range_max: Option<f32>,
    pub operation: Option<String>,
    pub hue_min: Option<f32>,
    pub hue_max: Option<f32>,
    pub saturation_min: Option<f32>,
    pub saturation_max: Option<f32>,
    pub value_min: Option<f32>,
    pub value_max: Option<f32>,
}

impl Default for Initializer {
    fn default() -> Self {
        Self {
            id: 0,
            kind: InitializerKind::Unknown(String::new()),
            min: None,
            max: None,
            exponent: 1.0,
            scale: None,
            offset: None,
            speed_min: None,
            speed_max: None,
            phase_min: None,
            phase_max: None,
            time_scale: None,
            distance: None,
            count: None,
            axis: None,
            bounds: None,
            limit_behavior: None,
            input: None,
            input_control_point0: None,
            input_range_max: None,
            operation: None,
            hue_min: None,
            hue_max: None,
            saturation_min: None,
            saturation_max: None,
            value_min: None,
            value_max: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Operator {
    pub id: i32,
    pub kind: OperatorKind,
    pub gravity: Option<Vec3>,
    pub drag: Option<f32>,
    pub force: Option<Vec3>,
    pub fade_in_time: Option<f32>,
    pub fade_out_time: Option<f32>,
    pub start_time: Option<f32>,
    pub end_time: Option<f32>,
    pub start_value: Option<Vec3>,
    pub end_value: Option<Vec3>,
    pub frequency_min: Option<f32>,
    pub frequency_max: Option<f32>,
    pub scale_min: Option<f32>,
    pub scale_max: Option<f32>,
    pub phase_min: Option<f32>,
    pub phase_max: Option<f32>,
    pub blend_in_start: Option<f32>,
    pub blend_in_end: Option<f32>,
    pub blend_out_start: Option<f32>,
    pub blend_out_end: Option<f32>,
    pub mask: Option<Vec3>,
    pub scale: Option<f32>,
    pub speed_min: Option<f32>,
    pub speed_max: Option<f32>,
    pub time_scale: Option<f32>,
    pub axis: Option<Vec3>,
    pub distance_inner: Option<f32>,
    pub distance_outer: Option<f32>,
    pub speed_inner: Option<f32>,
    pub speed_outer: Option<f32>,
    pub ring_pull_distance: Option<f32>,
    pub ring_radius: Option<f32>,
    pub ring_width: Option<f32>,
    pub control_point: Option<usize>,
    pub threshold: Option<f32>,
    pub origin: Option<Vec3>,
    pub alignment_factor: Option<f32>,
    pub cohesion_factor: Option<f32>,
    pub separation_factor: Option<f32>,
    pub neighbor_threshold: Option<f32>,
    pub max_speed: Option<f32>,
    pub variable_strength: Option<f32>,
    pub reduction_inner: Option<f32>,
    pub input: Option<String>,
    pub output: Option<String>,
    pub transform_function: Option<String>,
    pub transform_input_scale: Option<f32>,
    pub operation: Option<String>,
    pub output_range_min: Option<Vec3>,
    pub output_range_max: Option<Vec3>,
    pub flags: u32,
}

impl Default for Operator {
    fn default() -> Self {
        Self {
            id: 0,
            kind: OperatorKind::Unknown(String::new()),
            gravity: None,
            drag: None,
            force: None,
            fade_in_time: None,
            fade_out_time: None,
            start_time: None,
            end_time: None,
            start_value: None,
            end_value: None,
            frequency_min: None,
            frequency_max: None,
            scale_min: None,
            scale_max: None,
            phase_min: None,
            phase_max: None,
            blend_in_start: None,
            blend_in_end: None,
            blend_out_start: None,
            blend_out_end: None,
            mask: None,
            scale: None,
            speed_min: None,
            speed_max: None,
            time_scale: None,
            axis: None,
            distance_inner: None,
            distance_outer: None,
            speed_inner: None,
            speed_outer: None,
            ring_pull_distance: None,
            ring_radius: None,
            ring_width: None,
            control_point: None,
            threshold: None,
            origin: None,
            alignment_factor: None,
            cohesion_factor: None,
            separation_factor: None,
            neighbor_threshold: None,
            max_speed: None,
            variable_strength: None,
            reduction_inner: None,
            input: None,
            output: None,
            transform_function: None,
            transform_input_scale: None,
            operation: None,
            output_range_min: None,
            output_range_max: None,
            flags: 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Renderer {
    pub id: i32,
    pub kind: RendererKind,
    pub length: Option<f32>,
    pub max_length: Option<f32>,
    pub min_length: Option<f32>,
    pub subdivision: u32,
    pub uv_smoothing: bool,
    pub uv_scale: Option<Vec3>,
    pub uv_scrolling: Option<Vec3>,
    pub fade_alpha: bool,
    pub segments: u32,
    pub axis: Option<Vec3>,
    pub orientation: Option<i32>,
    pub flags: u32,
}

impl Default for Renderer {
    fn default() -> Self {
        Self {
            id: 0,
            kind: RendererKind::Sprite,
            length: None,
            max_length: None,
            min_length: None,
            subdivision: 0,
            uv_smoothing: false,
            uv_scale: None,
            uv_scrolling: None,
            fade_alpha: false,
            segments: 0,
            axis: None,
            orientation: None,
            flags: 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ControlPoint {
    pub id: i32,
    pub offset: Vec3,
    pub angles: Option<Vec3>,
    pub flags: u32,
    pub parent: Option<usize>,
    pub lock_to_pointer: bool,
}

impl Default for ControlPoint {
    fn default() -> Self {
        Self {
            id: 0,
            offset: Vec3::ZERO,
            angles: None,
            flags: 0,
            parent: None,
            lock_to_pointer: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ChildLink {
    pub id: i32,
    pub name: String,
    pub kind: ChildKind,
    pub max_count: Option<usize>,
    pub flags: u32,
    pub origin: Vec3,
    pub angles: Option<Vec3>,
    pub scale: Vec3,
    pub probability: Option<f32>,
    pub control_point_start_index: Option<usize>,
}

impl Default for ChildLink {
    fn default() -> Self {
        Self {
            id: 0,
            name: String::new(),
            kind: ChildKind::Unknown(String::new()),
            max_count: None,
            flags: 0,
            origin: Vec3::ZERO,
            angles: None,
            scale: Vec3::ONE,
            probability: None,
            control_point_start_index: None,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ParticleSystem {
    pub material: String,
    pub max_count: usize,
    pub start_time: f32,
    pub flags: u32,
    pub animation_mode: Option<String>,
    pub sequence_multiplier: f32,
    pub emitters: Vec<Emitter>,
    pub initializers: Vec<Initializer>,
    pub operators: Vec<Operator>,
    pub renderers: Vec<Renderer>,
    pub control_points: Vec<ControlPoint>,
    pub children: Vec<ChildLink>,
    pub unknown_fields: Vec<String>,
}

const SYSTEM_FIELDS: &[&str] = &[
    "material",
    "maxcount",
    "starttime",
    "flags",
    "animationmode",
    "sequencemultiplier",
    "emitter",
    "initializer",
    "operator",
    "renderer",
    "controlpoint",
    "children",
];

const EMITTER_FIELDS: &[&str] = &[
    "id",
    "name",
    "rate",
    "origin",
    "directions",
    "distancemin",
    "distancemax",
    "speedmin",
    "speedmax",
    "instantaneous",
    "flags",
    "delay",
    "duration",
    "minperiodicdelay",
    "maxperiodicdelay",
    "minperiodicduration",
    "maxperiodicduration",
    "maxtoemitperperiod",
    "cone",
    "sign",
    "controlpoint",
];

const INITIALIZER_FIELDS: &[&str] = &[
    "id",
    "name",
    "min",
    "max",
    "exponent",
    "scale",
    "offset",
    "speedmin",
    "speedmax",
    "phasemin",
    "phasemax",
    "timescale",
    "distance",
    "count",
    "axis",
    "bounds",
    "limitbehavior",
    "input",
    "inputcontrolpoint0",
    "inputrangemax",
    "operation",
    "huemin",
    "huemax",
    "saturationmin",
    "saturationmax",
    "valuemin",
    "valuemax",
];

const OPERATOR_FIELDS: &[&str] = &[
    "id",
    "name",
    "gravity",
    "drag",
    "force",
    "fadeintime",
    "fadeouttime",
    "starttime",
    "endtime",
    "startvalue",
    "endvalue",
    "frequencymin",
    "frequencymax",
    "scalemin",
    "scalemax",
    "phasemin",
    "phasemax",
    "blendinstart",
    "blendinend",
    "blendoutstart",
    "blendoutend",
    "mask",
    "scale",
    "speedmin",
    "speedmax",
    "timescale",
    "axis",
    "distanceinner",
    "distanceouter",
    "speedinner",
    "speedouter",
    "ringpulldistance",
    "ringradius",
    "ringwidth",
    "controlpoint",
    "threshold",
    "origin",
    "alignmentfactor",
    "cohesionfactor",
    "separationfactor",
    "neighborthreshold",
    "maxspeed",
    "variablestrength",
    "reductioninner",
    "input",
    "output",
    "transformfunction",
    "transforminputscale",
    "operation",
    "outputrangemin",
    "outputrangemax",
    "flags",
];

const RENDERER_FIELDS: &[&str] = &[
    "id",
    "name",
    "length",
    "maxlength",
    "minlength",
    "subdivision",
    "uvsmoothing",
    "uvscale",
    "uvscrolling",
    "fadealpha",
    "segments",
    "axis",
    "orientation",
    "flags",
];

const CONTROL_POINT_FIELDS: &[&str] = &[
    "id",
    "offset",
    "angles",
    "flags",
    "locktopointer",
    "parentcontrolpoint",
];

const CHILD_FIELDS: &[&str] = &[
    "id",
    "name",
    "type",
    "maxcount",
    "flags",
    "origin",
    "angles",
    "scale",
    "probability",
    "controlpointstartindex",
];

fn field<'a>(map: &'a Map<String, Value>, name: &str) -> Option<&'a Value> {
    map.get(name).filter(|v| !v.is_null())
}

fn check_unknown(map: &Map<String, Value>, known: &[&str], path: &str, unknown: &mut Vec<String>) {
    for key in map.keys() {
        if !known.contains(&key.as_str()) {
            unknown.push(format!("{path}.{key}"));
        }
    }
}

fn as_f32(value: Option<&Value>) -> Option<f32> {
    match value? {
        Value::Number(n) => n.as_f64().map(|v| v as f32),
        Value::String(s) => s.trim().parse::<f32>().ok(),
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        _ => None,
    }
}

fn as_vec3(value: Option<&Value>) -> Option<Vec3> {
    match value? {
        Value::Number(_) | Value::Bool(_) => as_f32(value).map(Vec3::splat),
        Value::String(s) => {
            let mut parts = s
                .split(|c: char| c.is_whitespace() || c == ',')
                .filter(|p| !p.is_empty())
                .filter_map(|p| p.parse::<f32>().ok());
            let x = parts.next()?;
            let y = parts.next().unwrap_or(x);
            let z = parts.next().unwrap_or(x);
            Some(Vec3::new(x, y, z))
        }
        Value::Array(items) => {
            let parsed: Vec<f32> = items.iter().filter_map(|v| as_f32(Some(v))).collect();
            if parsed.is_empty() {
                None
            } else {
                let x = parsed[0];
                let y = parsed.get(1).copied().unwrap_or(x);
                let z = parsed.get(2).copied().unwrap_or(x);
                Some(Vec3::new(x, y, z))
            }
        }
        _ => None,
    }
}

fn as_rgb01(value: Option<&Value>) -> Option<Vec3> {
    let c = as_vec3(value)?;
    let max = c.x.max(c.y).max(c.z);
    if max > 1.0 {
        Some(c * (1.0 / 255.0))
    } else {
        Some(c)
    }
}

fn as_string(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(s) => Some(s.clone()),
        _ => None,
    }
}

fn as_bool(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().map(|v| v != 0.0).unwrap_or(false),
        Some(Value::String(s)) => s == "true" || s == "1",
        _ => false,
    }
}

fn as_u32(value: Option<&Value>, default: u32) -> u32 {
    as_f32(value)
        .map(|v| v.max(0.0).round() as u32)
        .unwrap_or(default)
}

fn as_i32(value: Option<&Value>, default: i32) -> i32 {
    as_f32(value).map(|v| v.round() as i32).unwrap_or(default)
}

fn as_usize(value: Option<&Value>) -> Option<usize> {
    as_f32(value).and_then(|v| {
        if v.is_finite() && v >= 0.0 {
            Some(v.round() as usize)
        } else {
            None
        }
    })
}

fn objects(value: Option<&Value>) -> Vec<&Map<String, Value>> {
    match value {
        Some(Value::Array(items)) => items.iter().filter_map(Value::as_object).collect(),
        Some(Value::Object(map)) => vec![map],
        _ => Vec::new(),
    }
}

impl ParticleSystem {
    pub fn parse_str(text: &str) -> Result<Self, Error> {
        let value: Value =
            serde_json::from_str(text).map_err(|e| Error::Format(format!("particle JSON: {e}")))?;
        Self::from_json(&value)
    }

    pub fn from_json(value: &Value) -> Result<Self, Error> {
        let map = value
            .as_object()
            .ok_or_else(|| Error::Format("particle system is not a JSON object".into()))?;
        let mut unknown = Vec::new();
        check_unknown(map, SYSTEM_FIELDS, "system", &mut unknown);

        let mut system = Self {
            material: as_string(field(map, "material")).unwrap_or_default(),
            max_count: as_usize(field(map, "maxcount")).unwrap_or(0),
            start_time: as_f32(field(map, "starttime")).unwrap_or(0.0).max(0.0),
            flags: as_u32(field(map, "flags"), 0),
            animation_mode: as_string(field(map, "animationmode")),
            sequence_multiplier: as_f32(field(map, "sequencemultiplier")).unwrap_or(1.0),
            unknown_fields: Vec::new(),
            ..Self::default()
        };

        for (i, item) in objects(field(map, "emitter")).into_iter().enumerate() {
            system.emitters.push(parse_emitter(item, i, &mut unknown));
        }
        for (i, item) in objects(field(map, "initializer")).into_iter().enumerate() {
            system
                .initializers
                .push(parse_initializer(item, i, &mut unknown));
        }
        for (i, item) in objects(field(map, "operator")).into_iter().enumerate() {
            system.operators.push(parse_operator(item, i, &mut unknown));
        }
        for (i, item) in objects(field(map, "renderer")).into_iter().enumerate() {
            system.renderers.push(parse_renderer(item, i, &mut unknown));
        }
        for (i, item) in objects(field(map, "controlpoint")).into_iter().enumerate() {
            system
                .control_points
                .push(parse_control_point(item, i, &mut unknown));
        }
        for (i, item) in objects(field(map, "children")).into_iter().enumerate() {
            system.children.push(parse_child(item, i, &mut unknown));
        }

        system.unknown_fields = unknown;
        Ok(system)
    }

    pub fn unknown_fields(&self) -> &[String] {
        &self.unknown_fields
    }

    pub fn has_trail_renderer(&self) -> bool {
        self.renderers.iter().any(|r| r.kind.is_trail())
    }

    pub fn trail_capacity(&self) -> usize {
        let mut n = 0usize;
        for renderer in &self.renderers {
            if renderer.kind.is_trail() {
                let requested = match renderer.kind {
                    RendererKind::SpriteTrail => renderer.max_length,
                    _ => Some(renderer.segments.max(renderer.subdivision) as f32),
                };
                n = n.max(requested.unwrap_or(8.0).max(1.0) as usize);
            }
        }
        n.clamp(1, MAX_TRAIL_POINTS)
    }

    pub fn with_instance_override(&self, overrides: &InstanceOverride, seed: u64) -> Simulation {
        let mut sim = Simulation::new(self, seed);
        sim.apply_override(overrides);
        sim
    }
}

fn parse_emitter(map: &Map<String, Value>, index: usize, unknown: &mut Vec<String>) -> Emitter {
    check_unknown(map, EMITTER_FIELDS, &format!("emitter[{index}]"), unknown);
    let name = as_string(field(map, "name")).unwrap_or_default();
    let kind = EmitterKind::from_name(&name);
    if matches!(kind, EmitterKind::Unknown(_)) {
        unknown.push(format!("emitter[{index}].name={name}"));
    }
    Emitter {
        id: as_i32(field(map, "id"), 0),
        kind,
        rate: as_f32(field(map, "rate")).unwrap_or(0.0).max(0.0),
        origin: as_vec3(field(map, "origin")).unwrap_or(Vec3::ZERO),
        directions: as_vec3(field(map, "directions")).unwrap_or(Vec3::ONE),
        distance_min: as_vec3(field(map, "distancemin")).unwrap_or(Vec3::ZERO),
        distance_max: as_vec3(field(map, "distancemax")).unwrap_or(Vec3::ZERO),
        speed_min: as_f32(field(map, "speedmin")),
        speed_max: as_f32(field(map, "speedmax")),
        instantaneous: as_bool(field(map, "instantaneous")),
        flags: as_u32(field(map, "flags"), 0),
        delay: as_f32(field(map, "delay")),
        duration: as_f32(field(map, "duration")),
        min_periodic_delay: as_f32(field(map, "minperiodicdelay")),
        max_periodic_delay: as_f32(field(map, "maxperiodicdelay")),
        min_periodic_duration: as_f32(field(map, "minperiodicduration")),
        max_periodic_duration: as_f32(field(map, "maxperiodicduration")),
        max_to_emit_per_period: as_f32(field(map, "maxtoemitperperiod")),
        cone: as_f32(field(map, "cone")),
        sign: as_f32(field(map, "sign")),
        // An emitter without the key follows control point 0, which is how a cursor trail
        // (control point 0 locked to the pointer) gets emitted under the pointer.
        control_point: as_usize(field(map, "controlpoint")).or(Some(0)),
    }
}

fn parse_initializer(
    map: &Map<String, Value>,
    index: usize,
    unknown: &mut Vec<String>,
) -> Initializer {
    check_unknown(
        map,
        INITIALIZER_FIELDS,
        &format!("initializer[{index}]"),
        unknown,
    );
    let name = as_string(field(map, "name")).unwrap_or_default();
    let kind = InitializerKind::from_name(&name);
    if matches!(kind, InitializerKind::Unknown(_)) {
        unknown.push(format!("initializer[{index}].name={name}"));
    }
    Initializer {
        id: as_i32(field(map, "id"), 0),
        kind,
        min: as_vec3(field(map, "min")),
        max: as_vec3(field(map, "max")),
        exponent: as_f32(field(map, "exponent")).unwrap_or(1.0).max(EPS),
        scale: as_f32(field(map, "scale")),
        offset: as_f32(field(map, "offset")),
        speed_min: as_f32(field(map, "speedmin")),
        speed_max: as_f32(field(map, "speedmax")),
        phase_min: as_f32(field(map, "phasemin")),
        phase_max: as_f32(field(map, "phasemax")),
        time_scale: as_f32(field(map, "timescale")),
        distance: as_f32(field(map, "distance")),
        count: as_f32(field(map, "count")),
        axis: as_vec3(field(map, "axis")),
        bounds: as_vec3(field(map, "bounds")),
        limit_behavior: as_string(field(map, "limitbehavior")),
        input: as_string(field(map, "input")),
        input_control_point0: as_usize(field(map, "inputcontrolpoint0")),
        input_range_max: as_f32(field(map, "inputrangemax")),
        operation: as_string(field(map, "operation")),
        hue_min: as_f32(field(map, "huemin")),
        hue_max: as_f32(field(map, "huemax")),
        saturation_min: as_f32(field(map, "saturationmin")),
        saturation_max: as_f32(field(map, "saturationmax")),
        value_min: as_f32(field(map, "valuemin")),
        value_max: as_f32(field(map, "valuemax")),
    }
}

fn parse_operator(map: &Map<String, Value>, index: usize, unknown: &mut Vec<String>) -> Operator {
    check_unknown(map, OPERATOR_FIELDS, &format!("operator[{index}]"), unknown);
    let name = as_string(field(map, "name")).unwrap_or_default();
    let kind = OperatorKind::from_name(&name);
    if matches!(kind, OperatorKind::Unknown(_)) {
        unknown.push(format!("operator[{index}].name={name}"));
    }
    Operator {
        id: as_i32(field(map, "id"), 0),
        kind,
        gravity: as_vec3(field(map, "gravity")),
        drag: as_f32(field(map, "drag")),
        force: as_vec3(field(map, "force")),
        fade_in_time: as_f32(field(map, "fadeintime")),
        fade_out_time: as_f32(field(map, "fadeouttime")),
        start_time: as_f32(field(map, "starttime")),
        end_time: as_f32(field(map, "endtime")),
        start_value: as_vec3(field(map, "startvalue")),
        end_value: as_vec3(field(map, "endvalue")),
        frequency_min: as_f32(field(map, "frequencymin")),
        frequency_max: as_f32(field(map, "frequencymax")),
        scale_min: as_f32(field(map, "scalemin")),
        scale_max: as_f32(field(map, "scalemax")),
        phase_min: as_f32(field(map, "phasemin")),
        phase_max: as_f32(field(map, "phasemax")),
        blend_in_start: as_f32(field(map, "blendinstart")),
        blend_in_end: as_f32(field(map, "blendinend")),
        blend_out_start: as_f32(field(map, "blendoutstart")),
        blend_out_end: as_f32(field(map, "blendoutend")),
        mask: as_vec3(field(map, "mask")),
        scale: as_f32(field(map, "scale")),
        speed_min: as_f32(field(map, "speedmin")),
        speed_max: as_f32(field(map, "speedmax")),
        time_scale: as_f32(field(map, "timescale")),
        axis: as_vec3(field(map, "axis")),
        distance_inner: as_f32(field(map, "distanceinner")),
        distance_outer: as_f32(field(map, "distanceouter")),
        speed_inner: as_f32(field(map, "speedinner")),
        speed_outer: as_f32(field(map, "speedouter")),
        ring_pull_distance: as_f32(field(map, "ringpulldistance")),
        ring_radius: as_f32(field(map, "ringradius")),
        ring_width: as_f32(field(map, "ringwidth")),
        control_point: as_usize(field(map, "controlpoint")),
        threshold: as_f32(field(map, "threshold")),
        origin: as_vec3(field(map, "origin")),
        alignment_factor: as_f32(field(map, "alignmentfactor")),
        cohesion_factor: as_f32(field(map, "cohesionfactor")),
        separation_factor: as_f32(field(map, "separationfactor")),
        neighbor_threshold: as_f32(field(map, "neighborthreshold")),
        max_speed: as_f32(field(map, "maxspeed")),
        variable_strength: as_f32(field(map, "variablestrength")),
        reduction_inner: as_f32(field(map, "reductioninner")),
        input: as_string(field(map, "input")),
        output: as_string(field(map, "output")),
        transform_function: as_string(field(map, "transformfunction")),
        transform_input_scale: as_f32(field(map, "transforminputscale")),
        operation: as_string(field(map, "operation")),
        output_range_min: as_vec3(field(map, "outputrangemin")),
        output_range_max: as_vec3(field(map, "outputrangemax")),
        flags: as_u32(field(map, "flags"), 0),
    }
}

fn parse_renderer(map: &Map<String, Value>, index: usize, unknown: &mut Vec<String>) -> Renderer {
    check_unknown(map, RENDERER_FIELDS, &format!("renderer[{index}]"), unknown);
    let name = as_string(field(map, "name")).unwrap_or_default();
    let kind = RendererKind::from_name(&name);
    if matches!(kind, RendererKind::Unknown(_)) {
        unknown.push(format!("renderer[{index}].name={name}"));
    }
    Renderer {
        id: as_i32(field(map, "id"), 0),
        kind,
        length: as_f32(field(map, "length")),
        max_length: as_f32(field(map, "maxlength")),
        min_length: as_f32(field(map, "minlength")),
        subdivision: as_u32(field(map, "subdivision"), 0),
        uv_smoothing: as_bool(field(map, "uvsmoothing")),
        uv_scale: as_vec3(field(map, "uvscale")),
        uv_scrolling: as_vec3(field(map, "uvscrolling")),
        fade_alpha: as_bool(field(map, "fadealpha")),
        segments: as_u32(field(map, "segments"), 0),
        axis: as_vec3(field(map, "axis")),
        orientation: as_f32(field(map, "orientation")).map(|v| v.round() as i32),
        flags: as_u32(field(map, "flags"), 0),
    }
}

fn parse_control_point(
    map: &Map<String, Value>,
    index: usize,
    unknown: &mut Vec<String>,
) -> ControlPoint {
    check_unknown(
        map,
        CONTROL_POINT_FIELDS,
        &format!("controlpoint[{index}]"),
        unknown,
    );
    let flags = as_u32(field(map, "flags"), 0);
    ControlPoint {
        id: as_i32(field(map, "id"), index as i32),
        offset: as_vec3(field(map, "offset")).unwrap_or(Vec3::ZERO),
        angles: as_vec3(field(map, "angles")),
        flags,
        parent: as_usize(field(map, "parentcontrolpoint")),
        lock_to_pointer: as_bool(field(map, "locktopointer")) || flags & 1 != 0,
    }
}

fn parse_child(map: &Map<String, Value>, index: usize, unknown: &mut Vec<String>) -> ChildLink {
    check_unknown(map, CHILD_FIELDS, &format!("children[{index}]"), unknown);
    let name = as_string(field(map, "name")).unwrap_or_default();
    let type_name = as_string(field(map, "type")).unwrap_or_default();
    let kind = ChildKind::from_name(&type_name);
    if matches!(kind, ChildKind::Unknown(_)) {
        unknown.push(format!("children[{index}].type={type_name}"));
    }
    ChildLink {
        id: as_i32(field(map, "id"), 0),
        name,
        kind,
        max_count: as_usize(field(map, "maxcount")),
        flags: as_u32(field(map, "flags"), 0),
        origin: as_vec3(field(map, "origin")).unwrap_or(Vec3::ZERO),
        angles: as_vec3(field(map, "angles")),
        scale: as_vec3(field(map, "scale")).unwrap_or(Vec3::ONE),
        probability: as_f32(field(map, "probability")),
        control_point_start_index: as_usize(field(map, "controlpointstartindex")),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum OverrideValue {
    Literal(f32),
    Bound { user: String, value: f32 },
    Script(String),
}

impl OverrideValue {
    pub fn literal(&self) -> Option<f32> {
        match self {
            Self::Literal(v) => Some(*v),
            Self::Bound { value, .. } => Some(*value),
            Self::Script(_) => None,
        }
    }

    fn parse(value: &Value) -> Option<Self> {
        match value {
            Value::Object(map) => {
                if let Some(script) = as_string(field(map, "script")) {
                    return Some(Self::Script(script));
                }
                let v = as_f32(field(map, "value"))?;
                Some(Self::Bound {
                    user: as_string(field(map, "user")).unwrap_or_default(),
                    value: v,
                })
            }
            _ => as_f32(Some(value)).map(Self::Literal),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum OverrideColor {
    Literal(Vec3),
    Bound { user: String, value: Vec3 },
    Script(String),
}

impl OverrideColor {
    pub fn literal(&self) -> Option<Vec3> {
        match self {
            Self::Literal(v) => Some(*v),
            Self::Bound { value, .. } => Some(*value),
            Self::Script(_) => None,
        }
    }

    fn parse(value: &Value) -> Option<Self> {
        match value {
            Value::Object(map) => {
                if let Some(script) = as_string(field(map, "script")) {
                    return Some(Self::Script(script));
                }
                let v = as_rgb01(field(map, "value"))?;
                Some(Self::Bound {
                    user: as_string(field(map, "user")).unwrap_or_default(),
                    value: v,
                })
            }
            _ => as_rgb01(Some(value)).map(Self::Literal),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct InstanceOverride {
    pub id: i32,
    pub rate: Option<OverrideValue>,
    pub count: Option<OverrideValue>,
    pub lifetime: Option<OverrideValue>,
    pub size: Option<OverrideValue>,
    pub speed: Option<OverrideValue>,
    pub alpha: Option<OverrideValue>,
    pub brightness: Option<OverrideValue>,
    pub color: Option<OverrideColor>,
    pub unknown_fields: Vec<String>,
}

impl InstanceOverride {
    const FIELDS: &'static [&'static str] = &[
        "id",
        "rate",
        "count",
        "lifetime",
        "size",
        "speed",
        "alpha",
        "brightness",
        "colorn",
        "color",
    ];

    pub fn from_json(value: &Value) -> Option<Self> {
        let map = value.as_object()?;
        let mut unknown = Vec::new();
        check_unknown(map, Self::FIELDS, "instanceoverride", &mut unknown);
        Some(Self {
            id: as_i32(field(map, "id"), 0),
            rate: field(map, "rate").and_then(OverrideValue::parse),
            count: field(map, "count").and_then(OverrideValue::parse),
            lifetime: field(map, "lifetime").and_then(OverrideValue::parse),
            size: field(map, "size").and_then(OverrideValue::parse),
            speed: field(map, "speed").and_then(OverrideValue::parse),
            alpha: field(map, "alpha").and_then(OverrideValue::parse),
            brightness: field(map, "brightness").and_then(OverrideValue::parse),
            color: field(map, "colorn")
                .or_else(|| field(map, "color"))
                .and_then(OverrideColor::parse),
            unknown_fields: unknown,
        })
    }
}

#[derive(Debug, Clone)]
struct SimOverrides {
    rate: f32,
    count: f32,
    lifetime: f32,
    size: f32,
    speed: f32,
    alpha: f32,
    brightness: f32,
    color: Option<Vec3>,
}

impl Default for SimOverrides {
    fn default() -> Self {
        Self {
            rate: 1.0,
            count: 1.0,
            lifetime: 1.0,
            size: 1.0,
            speed: 1.0,
            alpha: 1.0,
            brightness: 1.0,
            color: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TrailPoint {
    pub position: Vec3,
    pub age: f32,
}

#[derive(Debug, Clone)]
pub struct Particle {
    pub position: Vec3,
    pub offset: Vec3,
    pub velocity: Vec3,
    pub rotation: Vec3,
    pub angular_velocity: Vec3,
    pub size: f32,
    pub base_size: f32,
    pub color: Vec3,
    pub base_color: Vec3,
    pub alpha: f32,
    pub base_alpha: f32,
    pub age: f32,
    pub lifetime: f32,
    pub sequence: f32,
    pub remap: f32,
    pub seed: u64,
    pub alive: bool,
    pub trail: Vec<TrailPoint>,
}

impl Particle {
    fn reset(&mut self) {
        self.position = Vec3::ZERO;
        self.offset = Vec3::ZERO;
        self.velocity = Vec3::ZERO;
        self.rotation = Vec3::ZERO;
        self.angular_velocity = Vec3::ZERO;
        self.size = 1.0;
        self.base_size = 1.0;
        self.color = Vec3::ONE;
        self.base_color = Vec3::ONE;
        self.alpha = 1.0;
        self.base_alpha = 1.0;
        self.age = 0.0;
        self.lifetime = DEFAULT_LIFETIME;
        self.sequence = 0.0;
        self.remap = 1.0;
        self.seed = 0;
        self.alive = false;
        self.trail.clear();
    }

    pub fn render_position(&self) -> Vec3 {
        self.position + self.offset
    }
}

impl Default for Particle {
    fn default() -> Self {
        let mut p = Self {
            position: Vec3::ZERO,
            offset: Vec3::ZERO,
            velocity: Vec3::ZERO,
            rotation: Vec3::ZERO,
            angular_velocity: Vec3::ZERO,
            size: 1.0,
            base_size: 1.0,
            color: Vec3::ONE,
            base_color: Vec3::ONE,
            alpha: 1.0,
            base_alpha: 1.0,
            age: 0.0,
            lifetime: DEFAULT_LIFETIME,
            sequence: 0.0,
            remap: 1.0,
            seed: 0,
            alive: false,
            trail: Vec::new(),
        };
        p.reset();
        p
    }
}

#[derive(Debug, Clone)]
pub struct ChildEvent {
    pub link_index: usize,
    pub name: String,
    pub kind: ChildKind,
    pub position: Vec3,
    pub velocity: Vec3,
    pub color: Vec3,
    pub size: f32,
    pub alpha: f32,
    pub sequence: f32,
}

#[derive(Debug, Clone)]
struct Rng {
    state: u64,
}

impl Rng {
    fn new(seed: u64) -> Self {
        Self {
            state: if seed == 0 {
                0x9E37_79B9_7F4A_7C15
            } else {
                seed
            },
        }
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn f32(&mut self) -> f32 {
        ((self.next_u64() >> 40) as f32) / ((1u32 << 24) as f32)
    }

    fn range(&mut self, a: f32, b: f32) -> f32 {
        let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
        lo + (hi - lo) * self.f32()
    }

    fn unit_vec(&mut self) -> Vec3 {
        let z = self.range(-1.0, 1.0);
        let a = self.range(0.0, TAU);
        let r = (1.0 - z * z).max(0.0).sqrt();
        Vec3::new(r * a.cos(), r * a.sin(), z)
    }
}

fn splitmix64(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

fn hash01(seed: u64, key: u64) -> f32 {
    (splitmix64(seed ^ splitmix64(key)) >> 40) as f32 / ((1u32 << 24) as f32)
}

fn hash_range(seed: u64, key: u64, a: f32, b: f32) -> f32 {
    let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
    lo + (hi - lo) * hash01(seed, key)
}

fn hash3(ix: i32, iy: i32, iz: i32) -> f32 {
    let h = splitmix64(
        (ix as i64 as u64)
            .wrapping_mul(0x9E37_79B9)
            .wrapping_add((iy as i64 as u64).wrapping_mul(0x85EB_CA6B))
            .wrapping_add((iz as i64 as u64).wrapping_mul(0xC2B2_AE35)),
    );
    (h >> 40) as f32 / ((1u32 << 24) as f32) * 2.0 - 1.0
}

fn smoothstep(t: f32) -> f32 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn noise3(x: f32, y: f32, z: f32) -> f32 {
    let xi = x.floor();
    let yi = y.floor();
    let zi = z.floor();
    let fx = smoothstep(x - xi);
    let fy = smoothstep(y - yi);
    let fz = smoothstep(z - zi);
    let (x0, y0, z0) = (xi as i32, yi as i32, zi as i32);
    let (x1, y1, z1) = (x0 + 1, y0 + 1, z0 + 1);
    let c000 = hash3(x0, y0, z0);
    let c100 = hash3(x1, y0, z0);
    let c010 = hash3(x0, y1, z0);
    let c110 = hash3(x1, y1, z0);
    let c001 = hash3(x0, y0, z1);
    let c101 = hash3(x1, y0, z1);
    let c011 = hash3(x0, y1, z1);
    let c111 = hash3(x1, y1, z1);
    let x00 = c000 + (c100 - c000) * fx;
    let x10 = c010 + (c110 - c010) * fx;
    let x01 = c001 + (c101 - c001) * fx;
    let x11 = c011 + (c111 - c011) * fx;
    let y0v = x00 + (x10 - x00) * fy;
    let y1v = x01 + (x11 - x01) * fy;
    y0v + (y1v - y0v) * fz
}

fn noise_vec(p: Vec3, time: f32) -> Vec3 {
    Vec3::new(
        noise3(p.x + time, p.y, p.z),
        noise3(p.x, p.y + 37.31 + time, p.z),
        noise3(p.x, p.y, p.z + 71.73 + time),
    )
}

fn fbm(p: Vec3, time: f32) -> f32 {
    let mut sum = 0.0;
    let mut amp = 0.5;
    let mut freq = 1.0;
    for _ in 0..4 {
        sum += noise3(p.x * freq + time, p.y * freq, p.z * freq) * amp;
        amp *= 0.5;
        freq *= 2.0;
    }
    sum
}

fn hsv_to_rgb(h: f32, s: f32, v: f32) -> Vec3 {
    let h = h.rem_euclid(1.0) * 6.0;
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

#[derive(Debug, Clone, Copy, Default)]
struct EmitterState {
    accumulator: f64,
    started: bool,
    instant_done: bool,
    cycle_time: f32,
    period_emitted: usize,
}

#[derive(Debug, Clone)]
struct SpawnState {
    position: Vec3,
    velocity: Vec3,
    rotation: Vec3,
    angular_velocity: Vec3,
    size: f32,
    color: Vec3,
    alpha: f32,
    lifetime: f32,
    sequence: f32,
    remap: f32,
}

impl Default for SpawnState {
    fn default() -> Self {
        Self {
            position: Vec3::ZERO,
            velocity: Vec3::ZERO,
            rotation: Vec3::ZERO,
            angular_velocity: Vec3::ZERO,
            size: 1.0,
            color: Vec3::ONE,
            alpha: 1.0,
            lifetime: DEFAULT_LIFETIME,
            sequence: 0.0,
            remap: 1.0,
        }
    }
}

pub struct Simulation {
    system: Arc<ParticleSystem>,
    seed: u64,
    rng: Rng,
    time: f64,
    accumulator: f64,
    particles: Vec<Particle>,
    free: Vec<usize>,
    alive: usize,
    emitter_states: Vec<EmitterState>,
    overrides: SimOverrides,
    control_points: Vec<Vec3>,
    events: Vec<ChildEvent>,
    audio: Vec<f32>,
    boids_snapshot: Vec<(bool, Vec3, Vec3)>,
    trail_capacity: usize,
}

impl Simulation {
    /// Create a simulation seeded with `seed`. The system is shared, not copied per step.
    pub fn new(system: &ParticleSystem, seed: u64) -> Self {
        let system = Arc::new(system.clone());
        let trail_capacity = system.trail_capacity();
        let control_points = system.control_points.iter().map(|cp| cp.offset).collect();
        Self {
            emitter_states: vec![EmitterState::default(); system.emitters.len()],
            system,
            seed,
            rng: Rng::new(seed),
            time: 0.0,
            accumulator: 0.0,
            particles: Vec::new(),
            free: Vec::new(),
            alive: 0,
            overrides: SimOverrides::default(),
            control_points,
            events: Vec::new(),
            audio: Vec::new(),
            boids_snapshot: Vec::new(),
            trail_capacity,
        }
    }

    pub fn system(&self) -> &ParticleSystem {
        &self.system
    }

    pub fn seed(&self) -> u64 {
        self.seed
    }

    pub fn time(&self) -> f32 {
        self.time as f32
    }

    pub fn particles(&self) -> &[Particle] {
        &self.particles
    }

    pub fn alive_particles(&self) -> impl Iterator<Item = &Particle> {
        self.particles.iter().filter(|p| p.alive)
    }

    pub fn alive_count(&self) -> usize {
        self.alive
    }

    pub fn max_particles(&self) -> usize {
        let scaled = (self.system.max_count as f64 * self.overrides.count as f64).round();
        scaled.clamp(0.0, MAX_PARTICLES_PER_SYSTEM as f64) as usize
    }

    pub fn control_points(&self) -> &[Vec3] {
        &self.control_points
    }

    pub fn set_control_point(&mut self, index: usize, position: Vec3) {
        if index < self.control_points.len() {
            self.control_points[index] = position;
        }
    }

    pub fn set_pointer(&mut self, x: f32, y: f32) {
        for (index, cp) in self.system.control_points.iter().enumerate() {
            if cp.lock_to_pointer {
                self.control_points[index] = Vec3::new(x, y, 0.0);
            }
        }
    }

    pub fn set_audio(&mut self, spectrum: &[f32]) {
        self.audio.clear();
        self.audio.extend_from_slice(spectrum);
    }

    pub fn take_events(&mut self) -> Vec<ChildEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn apply_override(&mut self, overrides: &InstanceOverride) {
        if let Some(v) = overrides.rate.as_ref().and_then(OverrideValue::literal) {
            self.overrides.rate = v.max(0.0);
        }
        if let Some(v) = overrides.count.as_ref().and_then(OverrideValue::literal) {
            self.overrides.count = v.max(0.0);
        }
        if let Some(v) = overrides.lifetime.as_ref().and_then(OverrideValue::literal) {
            self.overrides.lifetime = v.max(0.0);
        }
        if let Some(v) = overrides.size.as_ref().and_then(OverrideValue::literal) {
            self.overrides.size = v.max(0.0);
        }
        if let Some(v) = overrides.speed.as_ref().and_then(OverrideValue::literal) {
            self.overrides.speed = v;
        }
        if let Some(v) = overrides.alpha.as_ref().and_then(OverrideValue::literal) {
            self.overrides.alpha = v.max(0.0);
        }
        if let Some(v) = overrides
            .brightness
            .as_ref()
            .and_then(OverrideValue::literal)
        {
            self.overrides.brightness = v.max(0.0);
        }
        if let Some(color) = overrides.color.as_ref().and_then(OverrideColor::literal) {
            self.overrides.color = Some(color);
        }
    }

    pub fn reset(&mut self) {
        self.rng = Rng::new(self.seed);
        self.time = 0.0;
        self.accumulator = 0.0;
        self.particles.clear();
        self.free.clear();
        self.alive = 0;
        self.events.clear();
        self.emitter_states = vec![EmitterState::default(); self.system.emitters.len()];
        self.control_points = self
            .system
            .control_points
            .iter()
            .map(|cp| cp.offset)
            .collect();
        self.boids_snapshot.clear();
    }

    /// Advance by real time. Work is done in whole [`FIXED_DT`] steps.
    pub fn step(&mut self, dt: f32) {
        if !dt.is_finite() || dt <= 0.0 {
            return;
        }
        self.accumulator += dt as f64;
        while self.accumulator + f64::EPSILON >= FIXED_DT as f64 {
            self.fixed_step(FIXED_DT);
            self.accumulator -= FIXED_DT as f64;
        }
    }

    /// Advance to an absolute time. Seeking backwards resets and replays from zero, which keeps a
    /// frozen frame (and the golden-image harness) reproducible.
    pub fn seek_to(&mut self, time: f32) {
        if !time.is_finite() || time < 0.0 {
            return;
        }
        if (time as f64) + 1.0e-9 < self.time {
            self.reset();
        }
        let target = time as f64;
        while self.time + FIXED_DT as f64 <= target + 1.0e-9 {
            self.fixed_step(FIXED_DT);
        }
        self.accumulator = 0.0;
    }

    pub fn step_fixed(&mut self) {
        self.fixed_step(FIXED_DT);
    }

    fn fixed_step(&mut self, dt: f32) {
        let system = Arc::clone(&self.system);
        self.time += dt as f64;
        let t = self.time as f32;

        if system
            .operators
            .iter()
            .any(|op| matches!(op.kind, OperatorKind::Boids))
        {
            self.boids_snapshot.clear();
            self.boids_snapshot
                .resize(self.particles.len(), (false, Vec3::ZERO, Vec3::ZERO));
            for (i, particle) in self.particles.iter().enumerate() {
                if particle.alive {
                    self.boids_snapshot[i] = (true, particle.render_position(), particle.velocity);
                }
            }
        }

        let mut i = 0;
        while i < self.particles.len() {
            if self.particles[i].alive {
                let died = self.update_particle(i, dt, t);
                if died {
                    self.free.push(i);
                    self.alive -= 1;
                }
            }
            i += 1;
        }

        if t + EPS >= system.start_time {
            for emitter in 0..system.emitters.len() {
                self.emitter_step(emitter, dt, t);
            }
        }
    }

    fn emitter_step(&mut self, index: usize, dt: f32, t: f32) {
        let system = Arc::clone(&self.system);
        let emitter = &system.emitters[index];
        let local = t - system.start_time - emitter.delay.unwrap_or(0.0);
        if local < 0.0 {
            return;
        }
        if let Some(duration) = emitter.duration {
            if local > duration {
                return;
            }
        }

        let periodic = emitter.min_periodic_delay.is_some()
            || emitter.max_periodic_delay.is_some()
            || emitter.min_periodic_duration.is_some()
            || emitter.max_periodic_duration.is_some();
        let mut active = true;
        if periodic {
            let delay_min = emitter.min_periodic_delay.unwrap_or(0.0);
            let delay_max = emitter.max_periodic_delay.unwrap_or(delay_min);
            let duration_min = emitter.min_periodic_duration.unwrap_or(0.0);
            let duration_max = emitter.max_periodic_duration.unwrap_or(duration_min);
            let delay = delay_max.max(delay_min);
            let duration = duration_max.max(duration_min);
            let cycle = delay + duration;
            if cycle <= EPS {
                active = false;
            } else {
                let state = &mut self.emitter_states[index];
                if !state.started {
                    state.started = true;
                    state.cycle_time = 0.0;
                }
                state.cycle_time += dt;
                if state.cycle_time >= cycle {
                    state.cycle_time -= cycle;
                    state.period_emitted = 0;
                }
                active = state.cycle_time >= delay && state.cycle_time < cycle;
            }
        }

        let effective_max = self.max_particles();
        let state = &mut self.emitter_states[index];
        let mut instant_count = 0usize;
        if emitter.instantaneous && !state.instant_done && active {
            state.instant_done = true;
            instant_count = effective_max.saturating_sub(self.alive);
        }

        let mut rate_count = 0usize;
        if active {
            state.accumulator += emitter.rate as f64 * self.overrides.rate as f64 * dt as f64;
            let mut n = state.accumulator.floor() as usize;
            state.accumulator -= n as f64;
            if let Some(limit) = emitter.max_to_emit_per_period {
                let limit = limit.max(0.0) as usize;
                n = n.min(limit.saturating_sub(state.period_emitted));
                state.period_emitted += n;
            }
            rate_count = n;
        }

        let total = instant_count.saturating_add(rate_count);
        for _ in 0..total {
            if !self.spawn_particle(index) {
                break;
            }
        }
        if instant_count > 0 {
            let state = &mut self.emitter_states[index];
            state.instant_done = true;
        }
    }

    fn spawn_particle(&mut self, emitter_index: usize) -> bool {
        if self.alive >= self.max_particles() {
            return false;
        }
        let system = Arc::clone(&self.system);
        let emitter = &system.emitters[emitter_index];
        let mut state = SpawnState::default();

        let base = if let Some(cp) = emitter.control_point {
            self.control_points.get(cp).copied().unwrap_or(Vec3::ZERO)
        } else {
            Vec3::ZERO
        };
        let origin = base + emitter.origin;
        let direction = self.rng.unit_vec();
        match emitter.kind {
            EmitterKind::BoxRandom => {
                let mut offset = Vec3::ZERO;
                for (axis, (min, max)) in [
                    (0, (emitter.distance_min.x, emitter.distance_max.x)),
                    (1, (emitter.distance_min.y, emitter.distance_max.y)),
                    (2, (emitter.distance_min.z, emitter.distance_max.z)),
                ] {
                    let (lo, hi) = if min.abs() <= EPS {
                        (-max.abs(), max.abs())
                    } else {
                        (min.abs().min(max.abs()), min.abs().max(max.abs()))
                    };
                    let value = self.rng.range(lo, hi);
                    match axis {
                        0 => offset.x = value,
                        1 => offset.y = value,
                        _ => offset.z = value,
                    }
                }
                state.position = origin + offset;
            }
            _ => {
                let radius = self.rng.range(
                    emitter.distance_min.x.min(emitter.distance_max.x),
                    emitter.distance_min.x.max(emitter.distance_max.x),
                );
                let scaled = Vec3::new(
                    direction.x * emitter.directions.x,
                    direction.y * emitter.directions.y,
                    direction.z * emitter.directions.z,
                );
                state.position = origin + scaled * radius;
            }
        }

        let masked = Vec3::new(
            direction.x * emitter.directions.x,
            direction.y * emitter.directions.y,
            direction.z * emitter.directions.z,
        );
        let mut speed_dir = if masked.length() > EPS {
            masked.normalized_or_zero()
        } else {
            direction
        };
        if let Some(sign) = emitter.sign {
            speed_dir *= sign;
        }
        if let Some(cone) = emitter.cone {
            if cone > 0.0 {
                speed_dir.z *= (1.0 - cone).clamp(0.0, 1.0);
                speed_dir = speed_dir.normalized_or_zero();
            }
        }
        let speed = match (emitter.speed_min, emitter.speed_max) {
            (Some(a), Some(b)) => self.rng.range(a, b),
            (Some(a), None) => a,
            (None, Some(b)) => b,
            (None, None) => 0.0,
        };
        state.velocity = speed_dir * speed;

        let initializers = &system.initializers;
        for init in initializers {
            self.apply_initializer(init, &mut state);
        }

        let max_size = 1.0e6;
        state.lifetime = (state.lifetime * self.overrides.lifetime).max(0.001);
        state.size = (state.size * self.overrides.size * state.remap).clamp(0.0, max_size);
        state.velocity *= self.overrides.speed;
        state.alpha = (state.alpha * self.overrides.alpha).clamp(0.0, 1.0);
        state.color *= self.overrides.brightness;
        if let Some(color) = self.overrides.color {
            state.color *= color;
        }

        let index = if let Some(index) = self.free.pop() {
            index
        } else {
            if self.particles.len() >= MAX_PARTICLES_PER_SYSTEM {
                return false;
            }
            self.particles.push(Particle::default());
            self.particles.len() - 1
        };
        let trail_capacity = self.trail_capacity;
        let has_trail = self.system.has_trail_renderer();
        let particle = &mut self.particles[index];
        particle.reset();
        particle.seed = self.rng.next_u64();
        particle.position = state.position;
        particle.velocity = state.velocity;
        particle.rotation = state.rotation;
        particle.angular_velocity = state.angular_velocity;
        particle.size = state.size;
        particle.base_size = state.size;
        particle.color = state.color;
        particle.base_color = state.color;
        particle.alpha = state.alpha;
        particle.base_alpha = state.alpha;
        particle.lifetime = state.lifetime;
        particle.sequence = state.sequence;
        particle.remap = state.remap.clamp(0.0, MAX_PARTICLES_PER_SYSTEM as f32);
        particle.alive = true;
        if has_trail {
            particle.trail.reserve(trail_capacity.min(MAX_TRAIL_POINTS));
            particle.trail.push(TrailPoint {
                position: particle.render_position(),
                age: 0.0,
            });
        }
        self.alive += 1;
        true
    }

    fn apply_initializer(&mut self, init: &Initializer, state: &mut SpawnState) {
        match init.kind {
            InitializerKind::LifetimeRandom => {
                let (lo, hi) = range_bounds(init.min, init.max, DEFAULT_LIFETIME);
                state.lifetime = self.rng.range(lo, hi).max(0.001);
            }
            InitializerKind::SizeRandom => {
                let (lo, hi) = range_bounds(init.min, init.max, 1.0);
                let u = self.rng.f32().powf(init.exponent);
                state.size = (lo + (hi - lo) * u).max(0.0);
            }
            InitializerKind::ColorRandom => {
                let lo = init.min.map(rgb_from_vec).unwrap_or(Vec3::ONE);
                let hi = init.max.map(rgb_from_vec).unwrap_or(lo);
                state.color = Vec3::new(
                    self.rng.range(lo.x, hi.x).clamp(0.0, 1.0),
                    self.rng.range(lo.y, hi.y).clamp(0.0, 1.0),
                    self.rng.range(lo.z, hi.z).clamp(0.0, 1.0),
                );
            }
            InitializerKind::HsvColorRandom => {
                let hue = self
                    .rng
                    .range(init.hue_min.unwrap_or(0.0), init.hue_max.unwrap_or(1.0));
                let sat = self.rng.range(
                    init.saturation_min.unwrap_or(0.0),
                    init.saturation_max.unwrap_or(1.0),
                );
                let val = self
                    .rng
                    .range(init.value_min.unwrap_or(1.0), init.value_max.unwrap_or(1.0));
                state.color = hsv_to_rgb(hue, sat.clamp(0.0, 1.0), val.clamp(0.0, 1.0));
            }
            InitializerKind::VelocityRandom => {
                let lo = init.min.unwrap_or(Vec3::ZERO);
                let hi = init.max.unwrap_or(lo);
                state.velocity += Vec3::new(
                    self.rng.range(lo.x, hi.x),
                    self.rng.range(lo.y, hi.y),
                    self.rng.range(lo.z, hi.z),
                );
            }
            InitializerKind::RotationRandom => {
                let lo = init.min.unwrap_or(Vec3::ZERO);
                let hi = init.max.unwrap_or(lo);
                state.rotation = Vec3::new(
                    self.rng.range(lo.x, hi.x),
                    self.rng.range(lo.y, hi.y),
                    self.rng.range(lo.z, hi.z),
                );
            }
            InitializerKind::AngularVelocityRandom => {
                let lo = init.min.unwrap_or(Vec3::ZERO);
                let hi = init.max.unwrap_or(lo);
                state.angular_velocity = Vec3::new(
                    self.rng.range(lo.x, hi.x),
                    self.rng.range(lo.y, hi.y),
                    self.rng.range(lo.z, hi.z),
                );
            }
            InitializerKind::AlphaRandom => {
                let (lo, hi) = range_bounds(init.min, init.max, 1.0);
                let u = self.rng.f32().powf(init.exponent);
                state.alpha = (lo + (hi - lo) * u).clamp(0.0, 1.0);
            }
            InitializerKind::TurbulentVelocityRandom => {
                let scale = init.scale.unwrap_or(1.0);
                let speed_lo = init.speed_min.unwrap_or(100.0);
                let speed_hi = init.speed_max.unwrap_or(speed_lo);
                let phase = self
                    .rng
                    .range(init.phase_min.unwrap_or(0.0), init.phase_max.unwrap_or(TAU));
                let offset = init.offset.unwrap_or(0.0);
                let time_scale = init.time_scale.unwrap_or(1.0);
                let dir = noise_vec(
                    state.position * scale + Vec3::splat(offset),
                    phase * time_scale,
                )
                .normalized_or_zero();
                let speed = self.rng.range(speed_lo, speed_hi);
                state.velocity += dir * speed;
            }
            InitializerKind::MapSequenceBetweenControlPoints
            | InitializerKind::MapSequenceAroundControlPoint => {
                state.sequence = self.rng.f32();
                if let Some(count) = init.count {
                    state.sequence = (state.sequence * count.max(1.0)).fract();
                }
            }
            InitializerKind::PositionOffsetRandom => {
                let distance = init.distance.unwrap_or(0.0);
                let dir = self.rng.unit_vec();
                state.position += dir * distance * init.scale.unwrap_or(1.0);
            }
            InitializerKind::RemapInitialValue => {
                let point = init
                    .input_control_point0
                    .and_then(|i| self.control_points.get(i).copied())
                    .unwrap_or(Vec3::ZERO);
                let distance = (state.position - point).length();
                let range = init.input_range_max.unwrap_or(1.0).max(EPS);
                let value = (distance / range).clamp(0.0, 1.0);
                let factor = match init.operation.as_deref() {
                    Some("add") => 1.0 + value,
                    Some("subtract") => 1.0 - value,
                    Some("replace") => value,
                    _ => value,
                };
                state.remap = (state.remap * factor).max(EPS);
            }
            InitializerKind::Unknown(_) => {}
        }
    }

    fn update_particle(&mut self, index: usize, dt: f32, t: f32) -> bool {
        let system = Arc::clone(&self.system);
        let cps = &self.control_points;
        let audio = &self.audio;
        let snapshot = &self.boids_snapshot;
        let trail_capacity = self.trail_capacity;
        let p = &mut self.particles[index];
        p.age += dt;

        if p.age >= p.lifetime {
            p.alive = false;
            let event = ChildEvent {
                link_index: 0,
                name: String::new(),
                kind: ChildKind::EventDeath,
                position: p.render_position(),
                velocity: p.velocity,
                color: p.color,
                size: p.size,
                alpha: p.alpha,
                sequence: p.sequence,
            };
            for (link_index, link) in system.children.iter().enumerate() {
                if matches!(link.kind, ChildKind::EventDeath) {
                    let probability = link.probability.unwrap_or(1.0);
                    if probability >= 1.0 || hash01(p.seed, link_index as u64) <= probability {
                        let mut ev = event.clone();
                        ev.link_index = link_index;
                        ev.name = link.name.clone();
                        ev.kind = link.kind.clone();
                        self.events.push(ev);
                    }
                }
            }
            return true;
        }

        let seed = p.seed;
        let position = p.position;
        let age = p.age;
        let lifetime = p.lifetime;
        let mut velocity = p.velocity;
        let mut angular_velocity = p.angular_velocity;
        let mut alpha = p.base_alpha;
        let mut size = p.base_size;
        let mut color = p.base_color;
        let mut offset = Vec3::ZERO;
        let mut accel = Vec3::ZERO;
        let mut drag = 0.0f32;
        let mut angular_drag = 0.0f32;

        for op in &system.operators {
            let key = op.id as u64;
            match op.kind {
                OperatorKind::Movement => {
                    if let Some(gravity) = op.gravity {
                        accel += gravity;
                    }
                    if let Some(force) = op.force {
                        accel += force;
                    }
                    drag += op.drag.unwrap_or(0.0).max(0.0);
                }
                OperatorKind::AngularMovement => {
                    if let Some(force) = op.force {
                        angular_velocity += force * dt;
                    }
                    angular_drag += op.drag.unwrap_or(0.0).max(0.0);
                }
                OperatorKind::AlphaFade => {
                    let fade_in = match op.fade_in_time {
                        Some(t) if t > EPS => (age / t).clamp(0.0, 1.0),
                        _ => 1.0,
                    };
                    let fade_out = match op.fade_out_time {
                        Some(t) if t > EPS => {
                            let start = (lifetime - t).max(0.0);
                            if age > start {
                                ((lifetime - age) / t).clamp(0.0, 1.0)
                            } else {
                                1.0
                            }
                        }
                        _ => 1.0,
                    };
                    alpha = p.base_alpha * fade_in * fade_out;
                }
                OperatorKind::AlphaChange => {
                    let factor = change_factor(op, age);
                    alpha = p.base_alpha * factor;
                }
                OperatorKind::SizeChange => {
                    let factor = change_factor(op, age);
                    size = p.base_size * factor;
                }
                OperatorKind::ColorChange => {
                    if op.start_value.is_some() || op.end_value.is_some() {
                        let start = op.start_value.unwrap_or(p.base_color);
                        let end = op.end_value.unwrap_or(Vec3::ZERO);
                        color = start.lerp(end, window_fraction(op, age));
                    }
                }
                OperatorKind::OscillateAlpha => {
                    let phase = hash_range(
                        seed,
                        key,
                        op.phase_min.unwrap_or(0.0),
                        op.phase_max.unwrap_or(TAU),
                    );
                    let freq = hash_range(
                        seed,
                        key ^ 0x11,
                        op.frequency_min.unwrap_or(1.0),
                        op.frequency_max.unwrap_or(op.frequency_min.unwrap_or(1.0)),
                    );
                    let lo = op.scale_min.unwrap_or(0.0);
                    let hi = op.scale_max.unwrap_or(1.0);
                    let s = 0.5 + 0.5 * (TAU * freq * age + phase).sin();
                    alpha *= (lo + (hi - lo) * s) * blend_factor(op, age, lifetime);
                }
                OperatorKind::OscillatePosition => {
                    let lo = op.scale_min.unwrap_or(0.0);
                    let hi = op.scale_max.unwrap_or(1.0);
                    let amp = hash_range(seed, key, lo, hi);
                    let freq = hash_range(
                        seed,
                        key ^ 0x22,
                        op.frequency_min.unwrap_or(1.0),
                        op.frequency_max.unwrap_or(op.frequency_min.unwrap_or(1.0)),
                    );
                    let phase = hash_range(
                        seed,
                        key ^ 0x33,
                        op.phase_min.unwrap_or(0.0),
                        op.phase_max.unwrap_or(TAU),
                    );
                    let mask = op.mask.unwrap_or(Vec3::ONE);
                    let s = (TAU * freq * age + phase).sin();
                    offset += mask * (amp * s);
                }
                OperatorKind::OscillateSize => {
                    let phase = hash_range(
                        seed,
                        key,
                        op.phase_min.unwrap_or(0.0),
                        op.phase_max.unwrap_or(TAU),
                    );
                    let freq = hash_range(
                        seed,
                        key ^ 0x44,
                        op.frequency_min.unwrap_or(1.0),
                        op.frequency_max.unwrap_or(op.frequency_min.unwrap_or(1.0)),
                    );
                    let lo = op.scale_min.unwrap_or(1.0);
                    let hi = op.scale_max.unwrap_or(1.0);
                    let s = 0.5 + 0.5 * (TAU * freq * age + phase).sin();
                    size *= (lo + (hi - lo) * s) * blend_factor(op, age, lifetime);
                }
                OperatorKind::Turbulence => {
                    let scale = op.scale.unwrap_or(0.01);
                    let time_scale = op.time_scale.unwrap_or(1.0);
                    let phase = hash_range(
                        seed,
                        key,
                        op.phase_min.unwrap_or(0.0),
                        op.phase_max.unwrap_or(TAU),
                    );
                    let mut dir = noise_vec(position * scale + Vec3::splat(phase), t * time_scale)
                        .normalized_or_zero();
                    dir *= op.mask.unwrap_or(Vec3::ONE);
                    let speed = hash_range(
                        seed,
                        key ^ 0x55,
                        op.speed_min.unwrap_or(0.0),
                        op.speed_max.unwrap_or(op.speed_min.unwrap_or(0.0)),
                    );
                    velocity += dir * (speed * dt * blend_factor(op, age, lifetime));
                }
                OperatorKind::Vortex | OperatorKind::VortexV2 => {
                    let axis = op
                        .axis
                        .unwrap_or(Vec3::new(0.0, 0.0, 1.0))
                        .normalized_or_zero();
                    let center = op
                        .control_point
                        .and_then(|i| cps.get(i).copied())
                        .unwrap_or(Vec3::ZERO)
                        + op.origin.unwrap_or(Vec3::ZERO);
                    let rel = position - center;
                    let radial = rel - axis * axis.dot(rel);
                    let distance = radial.length();
                    let speed = lerp_by_distance(
                        distance,
                        op.distance_inner.unwrap_or(0.0),
                        op.distance_outer
                            .unwrap_or(op.distance_inner.unwrap_or(0.0)),
                        op.speed_inner.unwrap_or(0.0),
                        op.speed_outer.unwrap_or(op.speed_inner.unwrap_or(0.0)),
                    );
                    let tangential = axis.cross(radial).normalized_or_zero();
                    velocity += tangential * (speed * dt * blend_factor(op, age, lifetime));
                    if matches!(op.kind, OperatorKind::VortexV2) {
                        if let (Some(radius), Some(width)) = (op.ring_radius, op.ring_width) {
                            let delta = (distance - radius).abs();
                            if delta <= width.max(EPS) {
                                let pull = op.ring_pull_distance.unwrap_or(0.0)
                                    * (1.0 - delta / width.max(EPS));
                                velocity += radial.normalized_or_zero() * (pull * dt);
                            }
                        }
                    }
                }
                OperatorKind::ControlPointAttract => {
                    let point = op
                        .control_point
                        .and_then(|i| cps.get(i).copied())
                        .unwrap_or(Vec3::ZERO)
                        + op.origin.unwrap_or(Vec3::ZERO);
                    let delta = point - position;
                    let distance = delta.length();
                    let threshold = op.threshold.unwrap_or(f32::INFINITY);
                    if distance > EPS && distance <= threshold {
                        let strength = op.scale.unwrap_or(0.0);
                        accel += delta.normalized_or_zero() * (strength / distance.max(1.0));
                    }
                }
                OperatorKind::Boids => {
                    let threshold = op.neighbor_threshold.unwrap_or(100.0).max(EPS);
                    let mut cohesion = Vec3::ZERO;
                    let mut alignment = Vec3::ZERO;
                    let mut separation = Vec3::ZERO;
                    let mut neighbors = 0.0f32;
                    for (j, &(alive, pos, vel)) in snapshot.iter().enumerate() {
                        if j == index || !alive {
                            continue;
                        }
                        let delta = pos - position;
                        let distance = delta.length();
                        if distance > EPS && distance < threshold {
                            cohesion += delta;
                            alignment += vel;
                            separation += delta * (1.0 / (distance * distance));
                            neighbors += 1.0;
                        }
                    }
                    if neighbors > 0.0 {
                        cohesion *= 1.0 / neighbors;
                        alignment *= 1.0 / neighbors;
                        velocity += (cohesion * op.cohesion_factor.unwrap_or(0.0)
                            + (alignment - velocity) * op.alignment_factor.unwrap_or(0.0)
                            + separation * op.separation_factor.unwrap_or(0.0))
                            * dt;
                    }
                }
                OperatorKind::CapVelocity => {
                    let max = op.max_speed.unwrap_or(0.0);
                    let speed = velocity.length();
                    if max > 0.0 && speed > max {
                        velocity *= max / speed;
                    }
                }
                OperatorKind::MaintainDistanceBetweenControlPoints => {
                    let first = op.control_point.unwrap_or(0);
                    let second = first + 1;
                    if let (Some(&a), Some(&b)) = (cps.get(first), cps.get(second)) {
                        let target = a.lerp(b, p.sequence.clamp(0.0, 1.0));
                        velocity += (target - position) * (dt * 0.5);
                    }
                }
                OperatorKind::MaintainDistanceToControlPoint => {
                    let point = op
                        .control_point
                        .and_then(|i| cps.get(i).copied())
                        .unwrap_or(Vec3::ZERO);
                    let delta = point - position;
                    let strength = op.variable_strength.unwrap_or(1.0);
                    velocity += delta.normalized_or_zero() * (strength * dt);
                }
                OperatorKind::ReduceMovementNearControlPoint => {
                    let point = op
                        .control_point
                        .and_then(|i| cps.get(i).copied())
                        .unwrap_or(Vec3::ZERO);
                    let distance = (position - point).length();
                    let inner = op.distance_inner.unwrap_or(0.0);
                    let outer = op.distance_outer.unwrap_or(inner).max(inner);
                    let reduction = op.reduction_inner.unwrap_or(0.0).max(0.0);
                    let near = 1.0 / (1.0 + reduction);
                    let factor = if distance <= inner {
                        near
                    } else if distance < outer {
                        near + (1.0 - near) * ((distance - inner) / (outer - inner).max(EPS))
                    } else {
                        1.0
                    };
                    velocity *= factor;
                }
                OperatorKind::RemapValue => {
                    let value = eval_remap(op, t, age, position, cps, audio, seed);
                    let range = match (op.output_range_min, op.output_range_max) {
                        (Some(lo), Some(hi)) => lo.lerp(hi, value),
                        (Some(lo), None) => lo * value,
                        (None, Some(hi)) => hi * value,
                        (None, None) => Vec3::splat(value),
                    };
                    match op.output.as_deref() {
                        Some("opacity") | Some("alpha") => {
                            alpha *= range.x.clamp(0.0, 4.0);
                        }
                        Some("size") => {
                            size *= range.x.clamp(0.0, 1000.0);
                        }
                        Some("velocity") => velocity = range,
                        Some("speed") => {
                            velocity = velocity.normalized_or_zero() * range.x;
                        }
                        _ => {}
                    }
                }
                OperatorKind::Unknown(_) => {}
            }
        }

        velocity += accel * dt;
        if drag > 0.0 {
            velocity *= 1.0 / (1.0 + drag * dt);
        }
        if angular_drag > 0.0 {
            angular_velocity *= 1.0 / (1.0 + angular_drag * dt);
        }

        p.position += velocity * dt;
        p.velocity = velocity;
        p.angular_velocity = angular_velocity;
        p.rotation += angular_velocity * dt;
        p.offset = offset;
        p.size = size.clamp(0.0, 1.0e6);
        p.alpha = alpha.clamp(0.0, 1.0);
        p.color = Vec3::new(color.x.max(0.0), color.y.max(0.0), color.z.max(0.0));

        if !p.trail.is_empty() {
            p.trail.push(TrailPoint {
                position: p.render_position(),
                age: p.age,
            });
            while p.trail.len() > trail_capacity {
                p.trail.remove(0);
            }
        }
        false
    }
}

fn range_bounds(min: Option<Vec3>, max: Option<Vec3>, fallback: f32) -> (f32, f32) {
    let lo = min.map(|v| v.x).unwrap_or(fallback);
    let hi = max.map(|v| v.x).unwrap_or(lo);
    if lo <= hi {
        (lo, hi)
    } else {
        (hi, lo)
    }
}

fn rgb_from_vec(v: Vec3) -> Vec3 {
    let max = v.x.max(v.y).max(v.z);
    if max > 1.0 {
        v * (1.0 / 255.0)
    } else {
        v
    }
}

fn window_fraction(op: &Operator, age: f32) -> f32 {
    let start = op.start_time.unwrap_or(0.0);
    let end = op.end_time.unwrap_or(start + 1.0);
    ((age - start) / (end - start).max(EPS)).clamp(0.0, 1.0)
}

fn change_factor(op: &Operator, age: f32) -> f32 {
    let start = op.start_value.map(|v| v.x).unwrap_or(1.0);
    let end = op.end_value.map(|v| v.x).unwrap_or(0.0);
    start + (end - start) * window_fraction(op, age)
}

fn blend_factor(op: &Operator, age: f32, lifetime: f32) -> f32 {
    let fade_in = match (op.blend_in_start, op.blend_in_end) {
        (Some(start), Some(end)) if end > start => ((age - start) / (end - start)).clamp(0.0, 1.0),
        (Some(start), Some(_)) => {
            if age >= start {
                1.0
            } else {
                0.0
            }
        }
        _ => 1.0,
    };
    let fade_out = match (op.blend_out_start, op.blend_out_end) {
        (Some(start), Some(end)) if end > start => ((end - age) / (end - start)).clamp(0.0, 1.0),
        (Some(start), Some(_)) => {
            if age <= start {
                1.0
            } else {
                0.0
            }
        }
        _ => 1.0,
    };
    let _ = lifetime;
    fade_in * fade_out
}

fn lerp_by_distance(distance: f32, inner: f32, outer: f32, a: f32, b: f32) -> f32 {
    if outer <= inner + EPS {
        return b;
    }
    let t = ((distance - inner) / (outer - inner)).clamp(0.0, 1.0);
    a + (b - a) * t
}

fn eval_remap(
    op: &Operator,
    time: f32,
    age: f32,
    position: Vec3,
    control_points: &[Vec3],
    audio: &[f32],
    seed: u64,
) -> f32 {
    let input = op.input.as_deref().unwrap_or("particlesystemtime");
    let mut value = if input.contains("audiospectrum") {
        audio.first().copied().unwrap_or(0.0)
    } else if input.contains("controlpoint") {
        let point = op
            .control_point
            .and_then(|i| control_points.get(i).copied())
            .unwrap_or(Vec3::ZERO);
        ((position - point).length() / 100.0).clamp(0.0, 1.0)
    } else if input.contains("age") || input.contains("lifetime") {
        age
    } else if input.contains("random") {
        hash01(seed, op.id as u64)
    } else {
        time
    };
    value *= op.transform_input_scale.unwrap_or(1.0);
    let transformed = match op.transform_function.as_deref() {
        Some("sine") => 0.5 + 0.5 * (value * TAU).sin(),
        Some("triangle") => 2.0 * (value.rem_euclid(1.0) - 0.5).abs(),
        Some("sawtooth") => value.rem_euclid(1.0),
        Some("square") => {
            if value.rem_euclid(1.0) < 0.5 {
                0.0
            } else {
                1.0
            }
        }
        Some("simplexnoise") => noise3(value, 0.0, 0.0) * 0.5 + 0.5,
        Some("fbmnoise") => fbm(Vec3::new(value, 0.0, 0.0), 0.0) * 0.5 + 0.5,
        Some("remap") | Some("linear") | None => value.clamp(0.0, 1.0),
        _ => value.clamp(0.0, 1.0),
    };
    match op.operation.as_deref() {
        Some("add") => transformed,
        Some("subtract") => 1.0 - transformed,
        Some("replace") => transformed,
        _ => transformed,
    }
    .clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(json: &str) -> ParticleSystem {
        ParticleSystem::parse_str(json).expect("system parses")
    }

    fn approx(a: f32, b: f32) -> bool {
        (a - b).abs() <= 1.0e-3
    }

    #[test]
    fn parses_full_system() {
        let system = parse(
            r#"{
                "material": "particles/test.json",
                "maxcount": 50,
                "starttime": 2.5,
                "flags": 3,
                "animationmode": "randomframe",
                "sequencemultiplier": 0.5,
                "emitter": [{
                    "id": 4, "name": "boxrandom", "rate": 12,
                    "origin": "1 2 3", "distancemin": "-1 0 0", "distancemax": "1 2 3",
                    "directions": "1 1 0", "speedmin": 5, "speedmax": 10,
                    "instantaneous": false, "controlpoint": 0
                }],
                "initializer": [
                    {"id": 0, "name": "lifetimerandom", "min": 1, "max": 2},
                    {"id": 1, "name": "hsvcolorrandom", "huemin": 0.1, "huemax": 0.2}
                ],
                "operator": [
                    {"id": 0, "name": "movement", "gravity": "0 -9.8 0", "drag": 0.5},
                    {"id": 1, "name": "remapvalue", "input": "particlesystemtime",
                     "output": "opacity", "outputrangemin": "0 0 0", "outputrangemax": "1 1 1"}
                ],
                "renderer": [{"id": 0, "name": "spritetrail", "maxlength": 12}],
                "controlpoint": [{"id": 0, "flags": 1, "offset": "4 0 0"}],
                "children": [{"id": 0, "name": "eventfollow", "type": "eventdeath", "probability": 0.5}]
            }"#,
        );
        assert_eq!(system.material, "particles/test.json");
        assert_eq!(system.max_count, 50);
        assert!(approx(system.start_time, 2.5));
        assert_eq!(system.flags, 3);
        assert_eq!(system.animation_mode.as_deref(), Some("randomframe"));
        assert_eq!(system.emitters.len(), 1);
        assert_eq!(system.emitters[0].kind, EmitterKind::BoxRandom);
        assert_eq!(system.emitters[0].id, 4);
        assert!(approx(system.emitters[0].rate, 12.0));
        assert!(approx(system.emitters[0].origin.y, 2.0));
        assert!(approx(system.emitters[0].distance_max.z, 3.0));
        assert_eq!(system.emitters[0].control_point, Some(0));
        assert_eq!(system.initializers.len(), 2);
        assert_eq!(system.initializers[1].kind, InitializerKind::HsvColorRandom);
        assert_eq!(system.operators.len(), 2);
        assert_eq!(system.operators[0].kind, OperatorKind::Movement);
        assert_eq!(system.operators[1].kind, OperatorKind::RemapValue);
        assert_eq!(system.operators[1].output.as_deref(), Some("opacity"));
        assert_eq!(system.renderers.len(), 1);
        assert_eq!(system.renderers[0].kind, RendererKind::SpriteTrail);
        assert_eq!(system.trail_capacity(), 12);
        assert!(system.has_trail_renderer());
        assert_eq!(system.control_points.len(), 1);
        assert!(system.control_points[0].lock_to_pointer);
        assert_eq!(system.children.len(), 1);
        assert_eq!(system.children[0].kind, ChildKind::EventDeath);
        assert!(
            system.unknown_fields.is_empty(),
            "{:?}",
            system.unknown_fields
        );
    }

    #[test]
    fn tracks_unknown_fields_and_names() {
        let system = parse(
            r#"{
                "maxcount": 1, "bogus": 2,
                "emitter": [{"name": "weirdshape", "rate": 1}],
                "initializer": [{"name": "weirdinit"}],
                "operator": [{"name": "weirdop"}],
                "renderer": [{"name": "weirdrenderer"}],
                "children": [{"type": "weirdchild"}]
            }"#,
        );
        assert!(system.unknown_fields.iter().any(|f| f == "system.bogus"));
        assert!(system
            .unknown_fields
            .iter()
            .any(|f| f == "emitter[0].name=weirdshape"));
        assert!(system
            .unknown_fields
            .iter()
            .any(|f| f == "initializer[0].name=weirdinit"));
        assert!(system
            .unknown_fields
            .iter()
            .any(|f| f == "operator[0].name=weirdop"));
        assert!(system
            .unknown_fields
            .iter()
            .any(|f| f == "renderer[0].name=weirdrenderer"));
        assert!(system
            .unknown_fields
            .iter()
            .any(|f| f == "children[0].type=weirdchild"));
    }

    #[test]
    fn parses_instance_override() {
        let value: serde_json::Value = serde_json::from_str(
            r#"{
                "id": 2,
                "rate": {"user": "speed", "value": 3.5},
                "count": null,
                "size": 2,
                "alpha": 0.25,
                "colorn": [255, 0, 128]
            }"#,
        )
        .unwrap();
        let overrides = InstanceOverride::from_json(&value).expect("override parses");
        assert_eq!(overrides.id, 2);
        assert_eq!(
            overrides.rate.as_ref().and_then(OverrideValue::literal),
            Some(3.5)
        );
        assert_eq!(overrides.count, None);
        assert_eq!(
            overrides.size.as_ref().and_then(OverrideValue::literal),
            Some(2.0)
        );
        assert_eq!(
            overrides.alpha.as_ref().and_then(OverrideValue::literal),
            Some(0.25)
        );
        let color = overrides
            .color
            .as_ref()
            .and_then(OverrideColor::literal)
            .unwrap();
        assert!((color.x - 1.0).abs() < 1.0e-3);
        assert!((color.z - 128.0 / 255.0).abs() < 1.0e-3);
    }

    const FLOW_JSON: &str = r#"{
        "maxcount": 32,
        "starttime": 0,
        "emitter": [{
            "id": 0, "name": "boxrandom", "rate": 40,
            "distancemin": "-2 -2 0", "distancemax": "2 2 0",
            "speedmin": 1, "speedmax": 4, "directions": "1 1 0"
        }],
        "initializer": [
            {"id": 0, "name": "lifetimerandom", "min": 0.5, "max": 1.5},
            {"id": 1, "name": "sizerandom", "min": 0.2, "max": 0.8},
            {"id": 2, "name": "velocityrandom", "min": "-1 -1 0", "max": "1 1 0"},
            {"id": 3, "name": "colorrandom", "min": "0.2 0.4 0.6", "max": "1 1 1"}
        ],
        "operator": [
            {"id": 0, "name": "movement", "gravity": "0 -2 0", "drag": 0.1},
            {"id": 1, "name": "turbulence", "scale": 0.02, "speedmin": 2, "speedmax": 5,
             "timescale": 0.5, "phasemin": 0, "phasemax": 3.14},
            {"id": 2, "name": "alphafade", "fadeintime": 0.1, "fadeouttime": 0.2},
            {"id": 3, "name": "sizechange", "startvalue": "1 1 1", "endvalue": "0.2 0.2 0.2"}
        ],
        "renderer": [{"id": 0, "name": "sprite"}]
    }"#;

    fn snapshot(sim: &Simulation) -> Vec<(f32, f32, f32, f32)> {
        sim.alive_particles()
            .map(|p| (p.position.x, p.position.y, p.size, p.alpha))
            .collect()
    }

    #[test]
    fn simulation_is_deterministic() {
        let system = parse(FLOW_JSON);
        let mut a = Simulation::new(&system, 0x1234_5678);
        let mut b = Simulation::new(&system, 0x1234_5678);
        for _ in 0..120 {
            a.step_fixed();
            b.step_fixed();
        }
        assert!(a.alive_count() > 0);
        assert_eq!(snapshot(&a), snapshot(&b));
        assert!((a.time() - 2.0).abs() < 1.0e-4);

        let mut c = Simulation::new(&system, 0x8765_4321);
        for _ in 0..120 {
            c.step_fixed();
        }
        assert_ne!(snapshot(&a), snapshot(&c));
    }

    #[test]
    fn start_time_delays_emission() {
        let system = parse(
            r#"{
                "maxcount": 4, "starttime": 1.0,
                "emitter": [{"name": "sphererandom", "rate": 60, "distancemax": 1}],
                "initializer": [{"name": "lifetimerandom", "min": 2, "max": 2}],
                "renderer": [{"name": "sprite"}]
            }"#,
        );
        let mut sim = Simulation::new(&system, 1);
        sim.step(0.9);
        assert_eq!(sim.alive_count(), 0);
        sim.step(0.2);
        assert!(sim.alive_count() > 0);
    }

    #[test]
    fn max_count_caps_spawning() {
        let system = parse(
            r#"{
                "maxcount": 7,
                "emitter": [{"name": "sphererandom", "rate": 10000}],
                "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5}],
                "renderer": [{"name": "sprite"}]
            }"#,
        );
        let mut sim = Simulation::new(&system, 2);
        sim.step(1.0);
        assert_eq!(sim.alive_count(), 7);
        assert_eq!(sim.max_particles(), 7);
    }

    #[test]
    fn instance_override_scales_capacity() {
        let system = parse(
            r#"{
                "maxcount": 10,
                "emitter": [{"name": "sphererandom", "rate": 10000}],
                "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5}],
                "renderer": [{"name": "sprite"}]
            }"#,
        );
        let value: serde_json::Value =
            serde_json::from_str(r#"{"id": 0, "count": 2, "size": 0.5}"#).unwrap();
        let overrides = InstanceOverride::from_json(&value).unwrap();
        let mut sim = system.with_instance_override(&overrides, 3);
        assert_eq!(sim.max_particles(), 20);
        sim.step(1.0);
        assert_eq!(sim.alive_count(), 20);
        assert!(sim.alive_particles().all(|p| approx(p.size, 0.5)));
    }

    #[test]
    fn lifetime_kills_and_emits_death_events() {
        let system = parse(
            r#"{
                "maxcount": 3,
                "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": true, "distancemax": 1}],
                "initializer": [{"name": "lifetimerandom", "min": 0.1, "max": 0.1}],
                "renderer": [{"name": "sprite"}],
                "children": [{"id": 0, "name": "deathfx", "type": "eventdeath", "probability": 1}]
            }"#,
        );
        let mut sim = Simulation::new(&system, 4);
        sim.step(0.05);
        assert_eq!(sim.alive_count(), 3);
        sim.step(0.2);
        assert_eq!(sim.alive_count(), 0);
        let events = sim.take_events();
        assert_eq!(events.len(), 3);
        assert!(events
            .iter()
            .all(|e| e.kind == ChildKind::EventDeath && e.name == "deathfx"));
        assert!(sim.take_events().is_empty());
    }

    #[test]
    fn trails_are_capped_and_record_positions() {
        let system = parse(
            r#"{
                "maxcount": 1,
                "emitter": [{"name": "sphererandom", "rate": 60, "speedmin": 10, "speedmax": 10,
                             "directions": "1 0 0"}],
                "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}],
                "renderer": [{"name": "spritetrail", "maxlength": 4}]
            }"#,
        );
        let mut sim = Simulation::new(&system, 5);
        sim.step(0.5);
        let particle = sim.alive_particles().next().expect("particle exists");
        assert!(!particle.trail.is_empty());
        assert!(particle.trail.len() <= 4);
        assert!(particle.position.length() > 1.0);
    }

    #[test]
    fn control_point_sets_spawn_origin() {
        let system = parse(
            r#"{
                "maxcount": 1,
                "emitter": [{"name": "sphererandom", "rate": 60, "controlpoint": 0, "distancemin": 0, "distancemax": 0}],
                "initializer": [{"name": "lifetimerandom", "min": 5, "max": 5}],
                "renderer": [{"name": "sprite"}],
                "controlpoint": [{"id": 0, "offset": "5 6 7"}]
            }"#,
        );
        let mut sim = Simulation::new(&system, 6);
        sim.step_fixed();
        let p = sim.alive_particles().next().expect("particle exists");
        assert!((p.position.x - 5.0).abs() < 1.0e-3);
        assert!((p.position.y - 6.0).abs() < 1.0e-3);
        assert!((p.position.z - 7.0).abs() < 1.0e-3);
        sim.set_control_point(0, Vec3::new(1.0, 2.0, 3.0));
        assert_eq!(sim.control_points()[0], Vec3::new(1.0, 2.0, 3.0));
    }

    #[test]
    fn seek_backwards_replays_deterministically() {
        let system = parse(FLOW_JSON);
        let mut stepped = Simulation::new(&system, 7);
        stepped.seek_to(1.0);
        let at_one = snapshot(&stepped);
        stepped.seek_to(0.5);
        let at_half = snapshot(&stepped);

        let mut fresh = Simulation::new(&system, 7);
        fresh.seek_to(0.5);
        assert_eq!(at_half, snapshot(&fresh));
        assert_ne!(at_one, at_half);
    }

    #[test]
    #[ignore = "needs the local Wallpaper Engine scene library"]
    fn parses_real_scene_packages() {
        let home = match std::env::var("HOME") {
            Ok(home) => home,
            Err(_) => return,
        };
        let root = std::path::PathBuf::from(home)
            .join("Library/Application Support/LiveWallpaper/Library");
        if !root.exists() {
            return;
        }
        let cases = [
            ("3695791724", "particles/presets/ember.json"),
            ("3695791724", "particles/workshop/3291675677/DBEffect.json"),
            ("3008153534", "particles/presets/fog2.json"),
        ];
        let mut parsed = 0;
        for (scene, name) in cases {
            let path = root.join(scene).join("scene.pkg");
            if !path.exists() {
                continue;
            }
            let pkg = crate::vfs::Pkg::open(&path).expect("package opens");
            let Some(bytes) = pkg.get(name) else {
                continue;
            };
            let text = String::from_utf8_lossy(&bytes);
            let system = ParticleSystem::parse_str(&text).expect("particle json parses");
            assert!(!system.emitters.is_empty(), "{name}");
            assert!(!system.renderers.is_empty(), "{name}");
            let mut sim = Simulation::new(&system, 11);
            sim.step(system.start_time.max(0.0) + 2.0);
            assert!(sim.alive_count() > 0, "{name} emitted nothing");
            parsed += 1;
        }
        if parsed == 0 {
            eprintln!("no local particle assets found");
        }
    }
}

#[cfg(test)]
mod asset_audit {
    use super::*;

    #[test]
    #[ignore = "needs the local Wallpaper Engine assets"]
    fn parses_all_shared_particle_assets() {
        let home = match std::env::var("HOME") {
            Ok(home) => home,
            Err(_) => return,
        };
        let root = std::path::PathBuf::from(home)
            .join("Library/Application Support/LiveWallpaper/WallpaperEngineAssets/particles");
        if !root.exists() {
            return;
        }
        let mut stack = vec![root];
        let mut files = 0usize;
        let mut systems = 0usize;
        let mut unknown = Vec::new();
        let mut failures = Vec::new();
        while let Some(dir) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                    continue;
                }
                if path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                files += 1;
                let Ok(text) = std::fs::read_to_string(&path) else {
                    continue;
                };
                match ParticleSystem::parse_str(&text) {
                    Ok(system) => {
                        systems += 1;
                        for field in &system.unknown_fields {
                            unknown.push(format!("{}: {field}", path.display()));
                        }
                        let mut sim = Simulation::new(&system, 1);
                        sim.step(system.start_time.max(0.0) + 5.0);
                    }
                    Err(e) => failures.push(format!("{}: {e}", path.display())),
                }
            }
        }
        assert!(files > 0, "no particle assets found");
        assert!(systems > 0, "no particle systems parsed");
        assert!(failures.is_empty(), "{failures:#?}");
        assert!(unknown.is_empty(), "unknown fields:\n{unknown:#?}");
    }
}
