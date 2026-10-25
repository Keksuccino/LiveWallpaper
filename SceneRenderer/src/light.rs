//! Light objects and the light uniforms of the engine's shaders.
//!
//! Two light systems exist side by side. A `point` light is a legacy light: the first four fill
//! `g_LightsPosition[4]` and `g_LightsColorRadius[4]` (colour times intensity, radius), which the
//! older model shaders (`generic`, the default scenes' own shaders) read with
//! `ComputeLightSpecular` from `common_fragment.h`. The `lpoint`, `lspot`, `ltube` and
//! `ldirectional` lights feed the `LightingV1` chunk instead (see `shader.rs`): per kind one array
//! entry each, sized by the `LIGHTS_POINT`, `LIGHTS_SPOT`, `LIGHTS_TUBE` and `LIGHTS_DIRECTIONAL`
//! combos. How each value is packed (radius in the colour's `w`, the falloff exponent in the
//! origin's `w`, the cosines of the cone angles, the facing along the light's own x axis) was read
//! from how Wallpaper Engine fills those arrays; the shading itself is the asset tree's
//! `ComputePBRLightShadow` in `common_pbr_2.h`.

use std::collections::HashMap;

use serde_json::Value;

use crate::scene::{floats, Bound};

/// Lights a legacy shader reads; more `point` lights are ignored.
pub const LEGACY_SLOTS: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// `point`: the four legacy slots.
    Legacy,
    Point,
    Spot,
    Tube,
    Directional,
}

impl Kind {
    fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "point" => Self::Legacy,
            "lpoint" => Self::Point,
            "lspot" => Self::Spot,
            "ltube" => Self::Tube,
            "ldirectional" => Self::Directional,
            _ => return None,
        })
    }
}

/// A light object as the scene lists it; every value may follow a user property.
#[derive(Debug, Clone)]
pub struct LightSpec {
    pub id: i64,
    pub parent: Option<i64>,
    pub kind: Kind,
    pub origin: Bound,
    pub angles: Bound,
    pub scale: Bound,
    pub visible: Bound,
    pub color: Bound,
    pub intensity: Bound,
    pub radius: Bound,
    /// Falloff exponent of the newer lights.
    pub exponent: Bound,
    /// Spot cone half angles, in degrees.
    pub inner_cone: Bound,
    pub outer_cone: Bound,
    /// A tube's second end, in the light's own space (its first end is the origin).
    pub control_point: Bound,
}

impl LightSpec {
    /// The light of a scene object, or `None` for a light kind we do not know. Missing values take
    /// the engine's defaults (black, intensity 0, radius 1, exponent 2, cones 20 and 30 degrees).
    pub fn parse(obj: &Value) -> Option<Self> {
        let kind = Kind::parse(obj["light"].as_str()?)?;
        let bound = |key: &str, default: Value| Bound::parse(obj.get(key), default);
        Some(Self {
            id: obj["id"].as_i64().unwrap_or(-1),
            parent: obj["parent"].as_i64(),
            kind,
            origin: bound("origin", Value::from("0 0 0")),
            angles: bound("angles", Value::from("0 0 0")),
            scale: bound("scale", Value::from("1 1 1")),
            visible: bound("visible", Value::Bool(true)),
            color: bound("color", Value::from("0 0 0")),
            intensity: bound("intensity", Value::from(0.0)),
            radius: bound("radius", Value::from(1.0)),
            exponent: bound("exponent", Value::from(2.0)),
            inner_cone: bound("innercone", Value::from(20.0)),
            outer_cone: bound("outercone", Value::from(30.0)),
            control_point: bound("controlpoint", Value::from("2 0 0")),
        })
    }
}

/// The light uniform values of one frame. The arrays of the newer lights hold one `vec4` (four
/// floats) per light, in scene order.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Lights {
    /// `g_LightsPosition[4]`: three floats per slot.
    pub legacy_position: [f32; 3 * LEGACY_SLOTS],
    /// `g_LightsColorRadius[4]`: colour times intensity, and the radius. An empty slot is black
    /// with radius 1, so its attenuation term never divides by zero.
    pub legacy_color_radius: [f32; 4 * LEGACY_SLOTS],
    pub point_origin: Vec<f32>,
    pub point_color: Vec<f32>,
    pub spot_origin: Vec<f32>,
    pub spot_direction: Vec<f32>,
    pub spot_color: Vec<f32>,
    pub spot_exponent: Vec<f32>,
    pub tube_origin_a: Vec<f32>,
    pub tube_origin_b: Vec<f32>,
    pub tube_color: Vec<f32>,
    pub directional_direction: Vec<f32>,
    pub directional_color: Vec<f32>,
}

impl Lights {
    /// Packs the visible lights. `world` gives each light's world matrix (column-major, the
    /// engine's layout): its translation is the light's position, its x axis the way a spot faces.
    pub fn pack(
        specs: &[LightSpec],
        props: &HashMap<String, Value>,
        world: impl Fn(&LightSpec) -> [f32; 16],
    ) -> Self {
        let mut out = Self::default();
        for slot in out.legacy_color_radius.chunks_mut(4) {
            slot[3] = 1.0;
        }
        let mut legacy = 0;
        for spec in specs.iter().filter(|s| s.visible.truthy(props)) {
            let num = |b: &Bound| floats(&b.get(props)).first().copied().unwrap_or(0.0);
            let rgb = floats(&spec.color.get(props));
            let intensity = num(&spec.intensity);
            let color = [0, 1, 2].map(|i| rgb.get(i).copied().unwrap_or(0.0) * intensity);
            let m = world(spec);
            let position = [m[12], m[13], m[14]];
            let x_axis = [m[0], m[1], m[2]];
            let radius = num(&spec.radius);
            let exponent = num(&spec.exponent);
            let rgba = |w: f32| [color[0], color[1], color[2], w];
            let with = |v: [f32; 3], w: f32| [v[0], v[1], v[2], w];
            match spec.kind {
                Kind::Legacy if legacy < LEGACY_SLOTS => {
                    out.legacy_position[legacy * 3..legacy * 3 + 3].copy_from_slice(&position);
                    out.legacy_color_radius[legacy * 4..legacy * 4 + 4]
                        .copy_from_slice(&rgba(radius));
                    legacy += 1;
                }
                Kind::Legacy => {}
                Kind::Point => {
                    out.point_origin.extend(with(position, exponent));
                    out.point_color.extend(rgba(radius));
                }
                Kind::Spot => {
                    let cos = |b: &Bound| num(b).to_radians().cos();
                    out.spot_origin
                        .extend(with(position, cos(&spec.inner_cone)));
                    out.spot_direction
                        .extend(with(x_axis, cos(&spec.outer_cone)));
                    out.spot_color.extend(rgba(radius));
                    out.spot_exponent.extend([exponent, 0.0, 0.0, 0.0]);
                }
                Kind::Tube => {
                    let p = floats(&spec.control_point.get(props));
                    let p = [0, 1, 2].map(|i| p.get(i).copied().unwrap_or(0.0));
                    let end = [0, 1, 2]
                        .map(|r| m[r] * p[0] + m[4 + r] * p[1] + m[8 + r] * p[2] + m[12 + r]);
                    out.tube_origin_a.extend(with(position, exponent));
                    out.tube_origin_b.extend(with(end, 0.0));
                    out.tube_color.extend(rgba(radius));
                }
                // The vector towards the light: against its facing.
                Kind::Directional => {
                    out.directional_direction
                        .extend(with(x_axis.map(|v| -v), 0.0));
                    out.directional_color.extend(rgba(1.0));
                }
            }
        }
        out
    }

    /// The combos that size the `LightingV1` arrays; absent for a kind without lights, so the
    /// chunk leaves that kind out.
    pub fn combos(&self) -> impl Iterator<Item = (&'static str, i64)> + '_ {
        [
            ("LIGHTS_POINT", self.point_color.len()),
            ("LIGHTS_SPOT", self.spot_color.len()),
            ("LIGHTS_TUBE", self.tube_color.len()),
            ("LIGHTS_DIRECTIONAL", self.directional_color.len()),
        ]
        .into_iter()
        .filter(|(_, n)| *n > 0)
        .map(|(name, n)| (name, (n / 4) as i64))
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn translation(x: f32, y: f32, z: f32) -> [f32; 16] {
        [1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., x, y, z, 1.]
    }

    #[test]
    fn legacy_point_lights_fill_four_slots() {
        let light = |id: i64| {
            LightSpec::parse(&json!({
                "id": id, "light": "point", "color": "1 0.5 0", "intensity": 2.0, "radius": 10.0,
                "origin": format!("{id} 0 0"),
            }))
            .expect("a point light")
        };
        let specs: Vec<LightSpec> = (1..=5).map(light).collect();
        let props = HashMap::new();
        let lights = Lights::pack(&specs, &props, |s| {
            let o = floats(&s.origin.get(&props));
            translation(o[0], o[1], o[2])
        });
        assert_eq!(
            &lights.legacy_position[..6],
            &[1.0, 0.0, 0.0, 2.0, 0.0, 0.0]
        );
        assert_eq!(&lights.legacy_color_radius[..4], &[2.0, 1.0, 0.0, 10.0]);
        // The fifth light has no slot; none of them feeds the newer chunk.
        assert_eq!(lights.legacy_position[9], 4.0);
        assert_eq!(lights.combos().count(), 0);
    }

    #[test]
    fn newer_lights_pack_cones_and_facing() {
        let spot = LightSpec::parse(&json!({
            "light": "lspot", "color": "1 1 1", "intensity": 1.0, "radius": 5.0, "exponent": 3.0,
            "innercone": 60.0, "outercone": 90.0,
        }))
        .expect("a spot light");
        let hidden =
            LightSpec::parse(&json!({"light": "lpoint", "visible": false})).expect("light");
        // Rotated a quarter turn about z: the light's x axis points along +y.
        let world = [
            0., 1., 0., 0., -1., 0., 0., 0., 0., 0., 1., 0., 1., 2., 3., 1.,
        ];
        let lights = Lights::pack(&[spot, hidden], &HashMap::new(), |_| world);
        let close = |a: &[f32], b: &[f32]| a.iter().zip(b).all(|(a, b)| (a - b).abs() < 1e-5);
        assert!(
            close(&lights.spot_origin, &[1.0, 2.0, 3.0, 0.5]),
            "{:?}",
            lights.spot_origin
        );
        assert!(
            close(&lights.spot_direction, &[0.0, 1.0, 0.0, 0.0]),
            "{:?}",
            lights.spot_direction
        );
        assert_eq!(lights.spot_exponent, vec![3.0, 0.0, 0.0, 0.0]);
        assert_eq!(
            lights.combos().collect::<Vec<_>>(),
            vec![("LIGHTS_SPOT", 1)]
        );
    }
}
