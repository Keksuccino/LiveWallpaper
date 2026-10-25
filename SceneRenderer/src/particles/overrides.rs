//! Instance overrides: the per-object `instanceoverride` values that scale a shared particle
//! file. They do not act on the particles; they rewrite the definition's numbers (the original
//! values are kept, so a changed override is applied to them afresh):
//!
//! - `count` scales emission rates and per-period caps, not `maxcount`;
//! - `speed` scales emission speeds, velocity initializers, gravity, forces and attraction;
//! - `lifetime` and `size` scale their initializers (`size` also a size change's values);
//! - `rate` speeds up the system's clock;
//! - `alpha` and a colour tint start every particle;
//! - `colorn` shifts the colours the system defines in hue, saturation and value, or tints the
//!   particles when the system defines none.

use serde_json::Value;

use super::model::{
    Definition, Initializer, OperatorKind, FLAG_NO_COLOR_OVERRIDE, FLAG_NO_COUNT_OVERRIDE,
    FLAG_NO_LIFETIME_OVERRIDE, FLAG_NO_SIZE_OVERRIDE, FLAG_NO_SPEED_OVERRIDE,
};
use super::{hsv_to_rgb, rgb_to_hsv, Range, Range3, Vec3, CONTROL_POINTS};

/// A colour override closer than this to the system's own colour changes nothing.
const COLOR_TOLERANCE: f32 = 0.9 / 255.0;

/// The overrides a scene object sets; unset ones keep the file's values.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct InstanceOverride {
    pub alpha: Option<f32>,
    pub size: Option<f32>,
    pub count: Option<f32>,
    pub speed: Option<f32>,
    pub lifetime: Option<f32>,
    /// Clock speed of the system.
    pub rate: Option<f32>,
    /// Only used by HDR scenes, which this renderer does not draw.
    pub brightness: Option<f32>,
    pub color: Option<Vec3>,
    pub control_points: [Option<Vec3>; CONTROL_POINTS],
    /// Radians.
    pub control_point_angles: [Option<Vec3>; CONTROL_POINTS],
}

impl InstanceOverride {
    /// From the scene object's `instanceoverride` (or one key of it), with user bindings already
    /// resolved to plain values. Keys whose value is not a number (or vector) stay unset.
    pub fn from_json(value: &Value) -> Option<Self> {
        let map = value.as_object()?;
        let num = |key: &str| map.get(key).and_then(Value::as_f64).map(|v| v as f32);
        let vec = |key: &str| -> Option<Vec3> {
            match map.get(key)? {
                Value::Number(n) => Some(Vec3::splat(n.as_f64()? as f32)),
                Value::String(s) => {
                    let mut parts = s
                        .split_whitespace()
                        .map(|p| p.parse::<f32>().unwrap_or(0.0));
                    Some(Vec3::new(
                        parts.next().unwrap_or(0.0),
                        parts.next().unwrap_or(0.0),
                        parts.next().unwrap_or(0.0),
                    ))
                }
                _ => None,
            }
        };
        Some(Self {
            alpha: num("alpha"),
            size: num("size"),
            count: num("count"),
            speed: num("speed"),
            lifetime: num("lifetime"),
            rate: num("rate").map(|r| r.max(0.01)),
            brightness: num("brightness"),
            // The older `color` key holds 0..255 and wins over `colorn`; a negative colour
            // means unset.
            color: vec("color")
                .map(|c| c * (1.0 / 255.0))
                .or_else(|| vec("colorn"))
                .filter(|c| c.x >= 0.0),
            control_points: std::array::from_fn(|i| vec(&format!("controlpoint{i}"))),
            control_point_angles: std::array::from_fn(|i| vec(&format!("controlpointangle{i}"))),
        })
    }

    /// Takes over every value `other` sets.
    pub fn merge(&mut self, other: &Self) {
        let take = |a: &mut Option<f32>, b: Option<f32>| {
            if b.is_some() {
                *a = b;
            }
        };
        take(&mut self.alpha, other.alpha);
        take(&mut self.size, other.size);
        take(&mut self.count, other.count);
        take(&mut self.speed, other.speed);
        take(&mut self.lifetime, other.lifetime);
        take(&mut self.rate, other.rate);
        take(&mut self.brightness, other.brightness);
        if other.color.is_some() {
            self.color = other.color;
        }
        for i in 0..CONTROL_POINTS {
            if other.control_points[i].is_some() {
                self.control_points[i] = other.control_points[i];
            }
            if other.control_point_angles[i].is_some() {
                self.control_point_angles[i] = other.control_point_angles[i];
            }
        }
    }

    /// The starting alpha of every particle.
    pub fn alpha(&self) -> f32 {
        self.alpha.unwrap_or(1.0)
    }

    /// How fast the system's clock runs.
    pub fn rate(&self) -> f32 {
        self.rate.unwrap_or(1.0)
    }

    /// The colour override when it changes anything for `def`: it must differ from the system's
    /// own colour, and the system must not opt out.
    pub fn color_for(&self, def: &Definition) -> Option<Vec3> {
        let color = self.color?;
        if def.flags & FLAG_NO_COLOR_OVERRIDE != 0 {
            return None;
        }
        let own = def.reference_color.unwrap_or(Vec3::ONE);
        let d = (color - own).abs();
        (d.x.max(d.y).max(d.z) >= COLOR_TOLERANCE).then_some(color)
    }

    /// The colour every particle of `def` starts with: the override's tint for a system without
    /// colours of its own, white otherwise.
    pub fn tint_for(&self, def: &Definition) -> Vec3 {
        match self.color_for(def) {
            Some(color) if def.reference_color.is_none() => color,
            _ => Vec3::ONE,
        }
    }

    /// `def` with the overrides applied to its numbers.
    pub fn apply(&self, def: &Definition) -> Definition {
        let mut out = def.clone();
        // A system may opt out of single overrides.
        let factor = |value: Option<f32>, opt_out: u32| {
            if def.flags & opt_out == 0 {
                value.unwrap_or(1.0)
            } else {
                1.0
            }
        };
        let count = factor(self.count, FLAG_NO_COUNT_OVERRIDE);
        let speed = factor(self.speed, FLAG_NO_SPEED_OVERRIDE);
        let lifetime = factor(self.lifetime, FLAG_NO_LIFETIME_OVERRIDE);
        let size = factor(self.size, FLAG_NO_SIZE_OVERRIDE);
        let rate = self.rate();
        for e in &mut out.emitters {
            e.rate *= count;
            e.max_per_period = (e.max_per_period as f32 * count) as u32;
            e.speed = e.speed.scaled(speed);
        }
        // The shift from the system's own colour to the override, in HSV.
        let shift = self
            .color_for(def)
            .zip(def.reference_color)
            .map(|(color, own)| {
                let target = rgb_to_hsv(color);
                (target, target - rgb_to_hsv(own))
            });
        for init in &mut out.initializers {
            match init {
                Initializer::Lifetime { range, .. } => *range = range.scaled(lifetime),
                Initializer::Size { range, .. } => *range = range.scaled(size),
                Initializer::Velocity { range, .. }
                | Initializer::AngularVelocity { range, .. } => *range = range.scaled(speed),
                Initializer::InheritControlPointVelocity { range, .. } => {
                    *range = range.scaled(speed)
                }
                Initializer::TurbulentVelocity {
                    speed: s,
                    time_scale,
                    ..
                } => {
                    *s = s.scaled(speed);
                    *time_scale *= rate;
                }
                Initializer::MapAround {
                    count: c,
                    speed: s,
                    flags,
                    ..
                } => {
                    *s = s.scaled(speed);
                    if *flags & 1 != 0 {
                        *c *= count;
                    }
                }
                Initializer::MapBetween {
                    count: c, flags, ..
                } => {
                    if *flags & 0x10 != 0 {
                        *c *= count;
                    }
                }
                Initializer::Color { range, .. } => {
                    if let Some((_, delta)) = shift {
                        *range = shift_range(*range, delta);
                    }
                }
                Initializer::HsvColor {
                    hue_min,
                    hue_range,
                    saturation,
                    value,
                    ..
                } => {
                    if let Some((target, _)) = shift {
                        // The hue range is centred on the override; saturation and value ranges
                        // are centred too, kept inside 0..1.
                        *hue_min = target.x - *hue_range * 0.5;
                        *saturation = centred(*saturation, target.y);
                        *value = centred(*value, target.z);
                    }
                }
                Initializer::ColorList { colors, offset, .. } => {
                    if let (Some((target, _)), Some(first)) = (shift, colors.first()) {
                        *offset = target - *first;
                    }
                }
                _ => {}
            }
        }
        for op in &mut out.operators {
            match &mut op.kind {
                OperatorKind::Movement { gravity, .. } => *gravity *= speed,
                OperatorKind::AngularMovement { force, .. } => *force *= speed,
                OperatorKind::OscillatePosition { osc, .. } => {
                    osc.frequency = osc.frequency.scaled(speed)
                }
                OperatorKind::ControlPointAttract { scale, .. } => *scale *= speed,
                OperatorKind::Turbulence {
                    speed: s,
                    time_scale,
                    ..
                } => {
                    *s = s.scaled(speed);
                    *time_scale *= rate;
                }
                OperatorKind::Vortex {
                    speed_inner,
                    speed_span,
                    ..
                }
                | OperatorKind::VortexV2 {
                    speed_inner,
                    speed_span,
                    ..
                } => {
                    *speed_inner *= speed;
                    *speed_span *= speed;
                }
                // The engine scales the size change's values as well as the spawn size, so a
                // size override acts twice on systems with a size change.
                OperatorKind::SizeChange(change) => {
                    change.start *= size;
                    change.delta *= size;
                }
                OperatorKind::ColorChange { start, delta, .. } => {
                    if let Some((_, shift)) = shift {
                        let r = shift_range(Range3::new(*start, *start + *delta), shift);
                        *start = r.min;
                        *delta = r.span;
                    }
                }
                _ => {}
            }
        }
        out
    }
}

/// Moves both ends of a colour range by an HSV shift (hue wraps, saturation and value clamp).
fn shift_range(range: Range3, shift: Vec3) -> Range3 {
    let move_color = |rgb: Vec3| {
        let hsv = rgb_to_hsv(rgb);
        hsv_to_rgb(Vec3::new(
            (hsv.x + shift.x).rem_euclid(1.0),
            (hsv.y + shift.y).clamp(0.0, 1.0),
            (hsv.z + shift.z).clamp(0.0, 1.0),
        ))
    };
    Range3::new(move_color(range.min), move_color(range.min + range.span))
}

/// A range of the same width centred on `centre`, its start kept inside 0..1 and its width cut
/// to end at 1.
fn centred(range: Range, centre: f32) -> Range {
    let min = (centre - range.span * 0.5).clamp(0.0, 1.0);
    let span = if min + range.span > 1.0 {
        1.0 - min
    } else {
        range.span
    };
    Range { min, span }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn def(json: &str) -> Definition {
        Definition::parse_str(json, true).expect("parses")
    }

    #[test]
    fn parses_override_values() {
        let v: Value = serde_json::from_str(
            r#"{"count": 1.4, "lifetime": 1.41, "size": 1.2, "speed": 0.8, "rate": 0,
                "colorn": "0.3 0.7 0.9", "controlpoint1": "5 6 7", "alpha": null}"#,
        )
        .unwrap();
        let o = InstanceOverride::from_json(&v).expect("object");
        assert_eq!(o.count, Some(1.4));
        assert_eq!(o.alpha, None);
        assert_eq!(o.alpha(), 1.0);
        assert_eq!(o.rate, Some(0.01));
        assert_eq!(o.color, Some(Vec3::new(0.3, 0.7, 0.9)));
        assert_eq!(o.control_points[1], Some(Vec3::new(5.0, 6.0, 7.0)));
        let legacy: Value =
            serde_json::from_str(r#"{"color": "255 0 0", "colorn": "0 1 0"}"#).unwrap();
        assert_eq!(
            InstanceOverride::from_json(&legacy).unwrap().color,
            Some(Vec3::new(1.0, 0.0, 0.0))
        );
    }

    #[test]
    fn merging_keeps_unset_values() {
        let full: Value = serde_json::from_str(r#"{"count": 2, "size": 3}"#).unwrap();
        let single: Value = serde_json::from_str(r#"{"size": 0.5}"#).unwrap();
        let mut o = InstanceOverride::from_json(&full).unwrap();
        o.merge(&InstanceOverride::from_json(&single).unwrap());
        assert_eq!((o.count, o.size), (Some(2.0), Some(0.5)));
    }

    #[test]
    fn scales_the_definition() {
        let base = def(r#"{"maxcount": 10,
                "emitter": [{"name": "sphererandom", "rate": 4, "speedmin": 10, "speedmax": 20}],
                "initializer": [{"name": "lifetimerandom", "min": 1, "max": 3},
                                {"name": "sizerandom", "min": 10, "max": 20}],
                "operator": [{"name": "movement", "gravity": "0 -100 0"},
                             {"name": "sizechange", "startvalue": 1, "endvalue": 2}]}"#);
        let o = InstanceOverride {
            count: Some(2.0),
            speed: Some(0.5),
            lifetime: Some(2.0),
            size: Some(3.0),
            ..InstanceOverride::default()
        };
        let d = o.apply(&base);
        assert_eq!(d.max_count, 10);
        assert_eq!(d.emitters[0].rate, 8.0);
        assert_eq!(d.emitters[0].speed, Range::new(5.0, 10.0));
        assert_eq!(
            d.initializers[0],
            Initializer::Lifetime {
                range: Range::new(2.0, 6.0),
                exponent: 1.0
            }
        );
        assert_eq!(
            d.initializers[1],
            Initializer::Size {
                range: Range::new(30.0, 60.0),
                exponent: 1.0
            }
        );
        assert!(
            matches!(d.operators[0].kind, OperatorKind::Movement { gravity, .. } if gravity == Vec3::new(0.0, -50.0, 0.0))
        );
        assert!(
            matches!(d.operators[1].kind, OperatorKind::SizeChange(c) if c.start == 3.0 && c.delta == 3.0)
        );
        // A system may opt out of an override.
        let mut opted = base.clone();
        opted.flags |= FLAG_NO_COUNT_OVERRIDE;
        assert_eq!(o.apply(&opted).emitters[0].rate, 4.0);
    }

    #[test]
    fn colour_shifts_own_colours_and_tints_plain_systems() {
        let coloured = def(
            r#"{"initializer": [{"name": "colorrandom", "min": "255 0 0", "max": "255 0 0"}]}"#,
        );
        let blue = InstanceOverride {
            color: Some(Vec3::new(0.0, 0.0, 1.0)),
            ..InstanceOverride::default()
        };
        let shifted = blue.apply(&coloured);
        let Initializer::Color { range, .. } = &shifted.initializers[0] else {
            panic!("colour initializer");
        };
        assert!(
            (range.min - Vec3::new(0.0, 0.0, 1.0)).length() < 1.0e-4,
            "{range:?}"
        );
        assert_eq!(blue.tint_for(&coloured), Vec3::ONE);

        let plain = def(r#"{"initializer": [{"name": "lifetimerandom"}]}"#);
        assert_eq!(plain.reference_color, None);
        assert_eq!(blue.tint_for(&plain), Vec3::new(0.0, 0.0, 1.0));

        // An override equal to the system's own colour changes nothing.
        let same = InstanceOverride {
            color: Some(Vec3::new(1.0, 0.0, 0.0)),
            ..InstanceOverride::default()
        };
        assert_eq!(same.color_for(&coloured), None);
    }
}
