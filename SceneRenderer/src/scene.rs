//! `scene.json` and the model/material/effect files it points to, reduced to what the renderer draws.

use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;

use serde_json::Value;

use crate::timeline::Timeline;
use crate::vfs::Vfs;
use crate::Error;

/// A value that a user property may override: `{"user": "name", "value": v}` or
/// `{"user": {"name": "name", "condition": "1"}, "value": v}` (a combo-property comparison).
/// A keyframed value (`{"animation": {...}, "value": v}`) also carries its timeline.
#[derive(Debug, Clone)]
pub struct Bound {
    pub value: Value,
    pub user: Option<String>,
    pub condition: Option<String>,
    pub timeline: Option<Rc<Timeline>>,
}

/// A JSON object whose fields may be user bindings (`{"user": .., "value": ..}`), with each one
/// replaced by what the user set, or its default. Used for overrides, which are read as plain values.
pub fn resolve_user_values(value: &Value, props: &HashMap<String, Value>) -> Value {
    let Some(map) = value.as_object() else {
        return value.clone();
    };
    let resolved = map
        .iter()
        .map(|(key, field)| {
            let field = match field.as_object() {
                Some(inner) if inner.contains_key("value") || inner.contains_key("user") => {
                    Bound::parse(Some(field), Value::Null).get(props)
                }
                _ => field.clone(),
            };
            (key.clone(), field)
        })
        .collect();
    Value::Object(resolved)
}

impl Bound {
    /// A plain value.
    pub fn fixed(value: Value) -> Self {
        Self { value, user: None, condition: None, timeline: None }
    }

    pub(crate) fn parse(v: Option<&Value>, default: Value) -> Self {
        let Some(v) = v else {
            return Self::fixed(default);
        };
        let Some(obj) = v
            .as_object()
            .filter(|o| o.contains_key("user") || o.contains_key("value") || o.contains_key("script"))
        else {
            return Self::fixed(v.clone());
        };
        let value = obj.get("value").cloned().unwrap_or(default);
        let (user, condition) = match obj.get("user") {
            Some(Value::String(s)) => (Some(s.clone()), None),
            Some(Value::Object(u)) => (
                u.get("name").and_then(Value::as_str).map(str::to_string),
                u.get("condition")
                    .map(|c| c.as_str().map_or_else(|| c.to_string(), str::to_string)),
            ),
            _ => (None, None),
        };
        Self {
            value,
            user,
            condition,
            timeline: obj.get("animation").and_then(Timeline::parse).map(Rc::new),
        }
    }

    /// The effective value at scene time `time`: `get`, then the timeline if there is one.
    pub fn at(&self, props: &HashMap<String, Value>, time: f32) -> Value {
        let value = self.get(props);
        match &self.timeline {
            Some(t) => Value::from(t.apply(&floats(&value), time)),
            None => value,
        }
    }

    /// The value no longer changes after `time`.
    pub fn settled(&self, time: f32) -> bool {
        self.timeline.as_ref().is_none_or(|t| t.settled(time))
    }

    /// The effective value given the current user property values.
    pub fn get(&self, props: &HashMap<String, Value>) -> Value {
        let Some(p) = self.user.as_ref().and_then(|u| props.get(u)) else {
            return self.value.clone();
        };
        match &self.condition {
            Some(cond) => {
                let current = p.as_str().map_or_else(|| p.to_string(), str::to_string);
                Value::Bool(&current == cond)
            }
            None => p.clone(),
        }
    }

    pub fn truthy(&self, props: &HashMap<String, Value>) -> bool {
        truthy(&self.get(props))
    }
}

pub fn truthy(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        Value::String(s) => !s.is_empty() && s != "0" && s != "false",
        _ => false,
    }
}

/// Numbers from `1.0`, `"1 2 3"` or `[1, 2, 3]`.
pub fn floats(v: &Value) -> Vec<f32> {
    match v {
        Value::Number(n) => vec![n.as_f64().unwrap_or(0.0) as f32],
        Value::Bool(b) => vec![f32::from(u8::from(*b))],
        // Shader defaults and some scene values separate components with commas: "0.0, 1.0".
        Value::String(s) => s
            .split(|c: char| c.is_whitespace() || c == ',')
            .filter_map(|x| x.parse().ok())
            .collect(),
        Value::Array(a) => a.iter().flat_map(floats).collect(),
        Value::Object(o) => o.get("value").map(floats).unwrap_or_default(),
        Value::Null => Vec::new(),
    }
}

/// Wallpaper Engine's `alignment` values and the offset of the box centre each gives, in sizes,
/// y up: the named point of the box sits on the layer's origin.
const ALIGNMENTS: [(&str, [f32; 2]); 9] = [
    ("center", [0.0, 0.0]),
    ("top", [0.0, -0.5]),
    ("topright", [-0.5, -0.5]),
    ("right", [-0.5, 0.0]),
    ("bottomright", [-0.5, 0.5]),
    ("bottom", [0.0, 0.5]),
    ("bottomleft", [0.5, 0.5]),
    ("left", [0.5, 0.0]),
    ("topleft", [0.5, -0.5]),
];

/// An image layer's `alignment` as an offset; an unknown or missing value is the centre.
pub(crate) fn alignment(value: &Value) -> [f32; 2] {
    let name = value.as_str().unwrap_or("");
    ALIGNMENTS.iter().find(|(n, _)| *n == name).map_or([0.0; 2], |(_, o)| *o)
}

/// The `alignment` name of an offset.
pub(crate) fn alignment_name(offset: [f32; 2]) -> &'static str {
    ALIGNMENTS.iter().find(|(_, o)| *o == offset).map_or("center", |(n, _)| n)
}

fn vec_n<const N: usize>(v: Option<&Value>, default: [f32; N]) -> [f32; N] {
    let f = v.map(floats).unwrap_or_default();
    let mut out = default;
    for (o, x) in out.iter_mut().zip(f) {
        *o = x;
    }
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Blend {
    Normal,
    Translucent,
    Additive,
    Disabled,
}

impl Blend {
    fn parse(s: Option<&str>) -> Self {
        match s.unwrap_or("translucent") {
            "normal" => Self::Normal,
            "additive" => Self::Additive,
            "disabled" => Self::Disabled,
            _ => Self::Translucent,
        }
    }
}

/// Which triangles a model material leaves out (`cullmode`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Cull {
    /// `normal`: the back faces.
    Back,
    /// `reversed`: the front faces.
    Front,
    /// `nocull`: none.
    None,
}

#[derive(Debug, Clone)]
pub struct Material {
    pub shader: String,
    pub blend: Blend,
    /// Texture names by slot; `None` keeps the shader default or the bound render target.
    pub textures: Vec<Option<String>>,
    pub combos: BTreeMap<String, i64>,
    /// `constantshadervalues`, keyed by the uniform annotation's `material` name. A value that
    /// follows a user property (`usershadervalues`) without a constant of its own is `Null`: the
    /// shader's default applies until the property is set.
    pub constants: HashMap<String, Bound>,
    /// Depth and culling of a model's material; image layers ignore them.
    pub cull: Cull,
    pub depth_test: bool,
    pub depth_write: bool,
}

impl Material {
    pub(crate) fn load(vfs: &Vfs, path: &str) -> Result<Self, Error> {
        Self::load_blended(vfs, path, Blend::Translucent)
    }

    /// A material whose file may leave `blending` out, taking `blend` then: image materials are
    /// translucent, model materials opaque (an `arsenal` texture keeps detail in its alpha).
    pub(crate) fn load_blended(vfs: &Vfs, path: &str, blend: Blend) -> Result<Self, Error> {
        let json = vfs.json(path)?;
        let pass = &json["passes"][0];
        let enabled = |key: &str| pass[key].as_str() != Some("disabled");
        let mut m = Self {
            shader: pass["shader"]
                .as_str()
                .unwrap_or("genericimage2")
                .to_string(),
            blend: pass["blending"].as_str().map_or(blend, |b| Blend::parse(Some(b))),
            textures: Vec::new(),
            combos: BTreeMap::new(),
            constants: HashMap::new(),
            cull: match pass["cullmode"].as_str() {
                Some("nocull") => Cull::None,
                Some("reversed") => Cull::Front,
                _ => Cull::Back,
            },
            depth_test: enabled("depthtest"),
            depth_write: enabled("depthwrite"),
        };
        m.apply_overrides(pass);
        Ok(m)
    }

    /// Applies a pass object's `textures`, `combos` and `constantshadervalues` on top.
    fn apply_overrides(&mut self, pass: &Value) {
        if let Some(textures) = pass["textures"].as_array() {
            for (i, t) in textures.iter().enumerate() {
                if let Some(name) = t.as_str() {
                    if self.textures.len() <= i {
                        self.textures.resize(i + 1, None);
                    }
                    self.textures[i] = Some(name.to_string());
                }
            }
        }
        if let Some(combos) = pass["combos"].as_object() {
            for (k, v) in combos {
                let _ = self
                    .combos
                    .insert(k.clone(), floats(v).first().copied().unwrap_or(0.0) as i64);
            }
        }
        if let Some(values) = pass["constantshadervalues"].as_object() {
            for (k, v) in values {
                let _ = self
                    .constants
                    .insert(k.clone(), Bound::parse(Some(v), Value::Null));
            }
        }
        // `{"<user property>": "<material name>"}`: the property drives that shader value.
        if let Some(values) = pass["usershadervalues"].as_object() {
            for (property, key) in values {
                let Some(key) = key.as_str() else { continue };
                let constant = self.constants.entry(key.to_string()).or_insert_with(|| {
                    Bound::parse(None, Value::Null)
                });
                constant.user = Some(property.clone());
                constant.condition = None;
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct EffectPass {
    pub material: Material,
    pub target: Option<String>,
    /// (render target name or `previous`, texture slot).
    pub binds: Vec<(String, usize)>,
}

#[derive(Debug, Clone)]
pub struct Fbo {
    pub name: String,
    pub scale: f32,
}

#[derive(Debug, Clone)]
pub struct Effect {
    pub name: String,
    pub visible: Bound,
    pub passes: Vec<EffectPass>,
    pub fbos: Vec<Fbo>,
}

/// A text object's own fields; placement, colour and effects come from the layer.
#[derive(Debug, Clone)]
pub struct TextLayer {
    /// A package font path (`fonts/...otf`) or a system family name.
    pub font: String,
    pub point_size: f32,
    pub horizontal_align: String,
    pub vertical_align: String,
    /// Margin around the glyphs, in design units: `"x y"`, or one number for both in older files.
    pub padding: [f32; 2],
    /// The layer's `colorBlendMode` (0 draws normally), which blends the text with what is behind.
    pub color_blend_mode: i64,
    /// The static value; scripts would replace it every tick.
    pub value: String,
}

/// A particle object: the system JSON to simulate and its per-instance overrides.
#[derive(Debug, Clone)]
pub struct ParticleLayer {
    pub system: String,
    pub instance_override: Option<Value>,
}

/// One animation layer of a puppet, as the scene object lists it.
#[derive(Debug, Clone)]
pub struct PuppetAnimation {
    pub id: i64,
    /// `rate`, `blend` and `visible` may follow user properties like the rest of the scene.
    pub rate: Bound,
    pub blend: Bound,
    pub additive: bool,
    pub visible: Bound,
    /// `blendin`, `blendout` and `blendtime`: fades of the weight at the start and the end.
    pub blend_in: bool,
    pub blend_out: bool,
    pub blend_time: f32,
}

/// A puppet object: the model file and the animations that move it.
#[derive(Debug, Clone)]
pub struct PuppetLayer {
    pub model: String,
    pub animations: Vec<PuppetAnimation>,
}

#[derive(Debug, Clone)]
pub struct Layer {
    pub id: i64,
    pub name: String,
    pub parent: Option<i64>,
    /// Named attachment point of a puppet parent the layer follows.
    pub attachment: Option<String>,
    pub origin: Bound,
    pub scale: Bound,
    pub angles: Bound,
    pub size: [f32; 2],
    pub parallax_depth: Bound,
    pub alpha: Bound,
    pub color: Bound,
    pub brightness: f32,
    pub visible: Bound,
    /// Group objects only position their children.
    pub material: Option<Material>,
    /// Set for text objects; such layers have no material and are drawn from a bitmap.
    pub text: Option<TextLayer>,
    /// Set for particle objects; such layers have no material of their own.
    pub particles: Option<ParticleLayer>,
    /// Set for puppet models; the layer keeps its material but draws a skinned mesh.
    pub puppet: Option<PuppetLayer>,
    /// Set for model objects: the `.mdl` mesh drawn in 3D with its own materials.
    pub model: Option<String>,
    /// The image's model file says `fullscreen`: in a perspective scene the layer covers the
    /// whole target instead of being placed in 3D.
    pub fullscreen: bool,
    /// The image's model file says `passthrough` (a compose layer): its children draw into its
    /// own buffer, which its effects then work on.
    pub passthrough: bool,
    /// A compose layer starts its buffer from what is behind it (`copybackground`, the default)
    /// rather than empty.
    pub copy_background: bool,
    /// Where the layer's box sits on its origin, as an offset of its centre in sizes, y up
    /// (`alignment`: `"left"` puts the left edge on the origin, an offset of half a width).
    pub alignment: [f32; 2],
    pub effects: Vec<Effect>,
}

/// A script on one value of a scene object, e.g. `{"script": "...", "value": ...}` under `text`.
#[derive(Debug, Clone)]
pub struct ScriptSpec {
    pub layer_id: i64,
    /// Path of the value inside the object: `origin`, `text`, `instanceoverride.rate`, ...
    pub field: String,
    pub source: String,
    /// The `scriptproperties` the scene stores for this script.
    pub properties: Value,
}

/// Collects every `{"script": ...}` value under a scene object.
fn find_scripts(layer_id: i64, path: &str, v: &Value, out: &mut Vec<ScriptSpec>) {
    match v {
        Value::Object(map) => {
            if let Some(source) = map.get("script").and_then(Value::as_str) {
                out.push(ScriptSpec {
                    layer_id,
                    field: path.to_string(),
                    source: source.to_string(),
                    properties: map.get("scriptproperties").cloned().unwrap_or(Value::Null),
                });
                return;
            }
            for (k, child) in map {
                let p = if path.is_empty() { k.clone() } else { format!("{path}.{k}") };
                find_scripts(layer_id, &p, child, out);
            }
        }
        Value::Array(items) => {
            for (i, child) in items.iter().enumerate() {
                find_scripts(layer_id, &format!("{path}[{i}]"), child, out);
            }
        }
        _ => {}
    }
}

/// The scene's camera parallax settings, as authored (each may follow a user property).
#[derive(Debug, Clone)]
pub struct Parallax {
    pub enabled: Bound,
    pub amount: Bound,
    pub delay: Bound,
    pub mouse_influence: Bound,
}

/// Camera shake settings, as authored (each may follow a user property).
#[derive(Debug, Clone)]
pub struct CameraShake {
    pub enabled: Bound,
    pub amplitude: Bound,
    pub roughness: Bound,
    pub speed: Bound,
}

impl CameraShake {
    /// (amplitude, roughness, speed) in effect, or `None` while the shake is off.
    pub fn now(&self, props: &HashMap<String, Value>) -> Option<[f32; 3]> {
        if !self.enabled.truthy(props) {
            return None;
        }
        let num = |b: &Bound, d: f32| floats(&b.get(props)).first().copied().unwrap_or(d);
        Some([num(&self.amplitude, 0.5), num(&self.roughness, 1.0), num(&self.speed, 3.0)])
    }
}

/// Camera parallax with the user's property values applied.
#[derive(Debug, Clone, Copy)]
pub struct ParallaxNow {
    pub amount: f32,
    pub delay: f32,
    pub mouse_influence: f32,
}

impl Parallax {
    /// The settings in effect, or `None` while camera parallax is off.
    pub fn now(&self, props: &HashMap<String, Value>) -> Option<ParallaxNow> {
        if !self.enabled.truthy(props) {
            return None;
        }
        let num = |b: &Bound, d: f32| floats(&b.get(props)).first().copied().unwrap_or(d);
        Some(ParallaxNow {
            amount: num(&self.amount, 0.5),
            delay: num(&self.delay, 0.1),
            mouse_influence: num(&self.mouse_influence, 1.0),
        })
    }
}

/// Scene-wide glow around bright parts, from `general`.
#[derive(Debug, Clone)]
pub struct Bloom {
    pub enabled: Bound,
    pub strength: Bound,
    pub threshold: Bound,
    pub tint: Bound,
}

#[derive(Debug, Clone)]
pub struct Scene {
    /// SceneScript programs attached to object values, in file order.
    pub scripts: Vec<ScriptSpec>,
    pub sounds: Vec<crate::sound::SoundSpec>,
    pub bloom: Bloom,
    pub width: f32,
    pub height: f32,
    pub clear_color: Bound,
    /// `general.zoom`: how far the 2D view is zoomed in (1 shows the whole design).
    pub zoom: Bound,
    pub parallax: Parallax,
    pub shake: CameraShake,
    pub layers: Vec<Layer>,
    /// The camera models and perspective scenes are seen through.
    pub camera: crate::camera::Camera,
    /// Light objects, in scene order.
    pub lights: Vec<crate::light::LightSpec>,
    /// `general.ambientcolor` and `general.skylightcolor`: the light model shaders blend by how
    /// much a surface faces up.
    pub ambient: Bound,
    pub skylight: Bound,
    /// `general.hdr`: colours may exceed 1, so a text layer's brightness scales its colour.
    pub hdr: bool,
    /// Object kinds this renderer does not draw yet, with counts (reported as load warnings).
    pub skipped: BTreeMap<String, usize>,
}

impl Layer {
    /// The keyframed values of the layer's placement and colour.
    pub fn timelines(&self) -> impl Iterator<Item = &Timeline> {
        [&self.origin, &self.scale, &self.angles, &self.alpha, &self.color]
            .into_iter()
            .filter_map(|b| b.timeline.as_deref())
    }
}

impl Scene {
    /// No keyframed value changes after `time`.
    pub fn settled(&self, time: f32) -> bool {
        self.zoom.settled(time)
            && self.layers.iter().all(|l| l.timelines().all(|t| t.settled(time)))
    }

    pub fn load(vfs: &Vfs, warnings: &mut Vec<String>) -> Result<Self, Error> {
        let json = vfs.json("scene.json")?;
        let general = &json["general"];
        let ortho = &general["orthogonalprojection"];
        let width = ortho["width"].as_f64().unwrap_or(1920.0) as f32;
        let height = ortho["height"].as_f64().unwrap_or(1080.0) as f32;
        // Every one of these may be bound to a user property, like the scene's own sliders.
        let parallax = Parallax {
            enabled: Bound::parse(general.get("cameraparallax"), Value::Bool(false)),
            amount: Bound::parse(general.get("cameraparallaxamount"), Value::from(0.5)),
            delay: Bound::parse(general.get("cameraparallaxdelay"), Value::from(0.1)),
            // Scenes that never touched the slider leave it out; Wallpaper Engine's scene starts at 0.5.
            mouse_influence: Bound::parse(general.get("cameraparallaxmouseinfluence"), Value::from(0.5)),
        };
        let mut scene = Self {
            width,
            height,
            clear_color: Bound::parse(general.get("clearcolor"), Value::from("0 0 0")),
            zoom: Bound::parse(general.get("zoom"), Value::from(1.0)),
            parallax,
            shake: CameraShake {
                enabled: Bound::parse(general.get("camerashake"), Value::Bool(false)),
                amplitude: Bound::parse(general.get("camerashakeamplitude"), Value::from(0.5)),
                roughness: Bound::parse(general.get("camerashakeroughness"), Value::from(1.0)),
                speed: Bound::parse(general.get("camerashakespeed"), Value::from(3.0)),
            },
            layers: Vec::new(),
            camera: crate::camera::Camera::load(vfs, &json, warnings),
            lights: Vec::new(),
            ambient: Bound::parse(general.get("ambientcolor"), Value::from("0 0 0")),
            skylight: Bound::parse(general.get("skylightcolor"), Value::from("0 0 0")),
            hdr: general["hdr"].as_bool() == Some(true),
            skipped: BTreeMap::new(),
            scripts: Vec::new(),
            sounds: Vec::new(),
            bloom: Bloom {
                enabled: Bound::parse(general.get("bloom"), Value::Bool(false)),
                strength: Bound::parse(general.get("bloomstrength"), Value::from(2.0)),
                threshold: Bound::parse(general.get("bloomthreshold"), Value::from(0.65)),
                tint: Bound::parse(general.get("bloomtint"), Value::from("1 1 1")),
            },
        };
        // Each light with the number of layers before it, to find the layer it is drawn before.
        let mut light_places = Vec::new();
        for obj in json["objects"].as_array().into_iter().flatten() {
            find_scripts(obj["id"].as_i64().unwrap_or(-1), "", obj, &mut scene.scripts);
            let kind = ["image", "particle", "text", "sound", "light", "model"]
                .into_iter()
                .find(|k| obj.get(*k).is_some_and(|v| !v.is_null()));
            match kind {
                Some("image") | Some("text") | Some("particle") | None => {
                    match Self::layer(vfs, obj, kind.is_none(), warnings) {
                        Ok(layer) => scene.layers.push(layer),
                        Err(e) => warnings.push(format!(
                            "layer {}: {e}",
                            obj["name"].as_str().unwrap_or("?")
                        )),
                    }
                }
                Some("sound") => scene.sounds.extend(crate::sound::SoundSpec::parse(obj)),
                Some("light") => match crate::light::LightSpec::parse(obj) {
                    Some(light) => {
                        light_places.push(scene.layers.len());
                        scene.lights.push(light);
                    }
                    None => {
                        let kind = obj["light"].as_str().unwrap_or("?");
                        *scene.skipped.entry(format!("{kind} light")).or_default() += 1;
                    }
                },
                // A model object places its mesh like a group places its children.
                Some("model") => match Self::layer(vfs, obj, true, warnings) {
                    Ok(layer) => scene.layers.push(Layer {
                        model: obj["model"].as_str().map(str::to_string),
                        ..layer
                    }),
                    Err(e) => warnings.push(format!("model {}: {e}", obj["name"].as_str().unwrap_or("?"))),
                },
                Some(other) => *scene.skipped.entry(other.to_string()).or_default() += 1,
            }
        }
        for (light, place) in scene.lights.iter_mut().zip(light_places) {
            light.before = scene.layers.get(place).map(|l| l.id);
        }
        // An auto projection is as big as the largest image (the reference renderer's rule); the
        // fixed 1920x1080 would crop or letterbox such a scene.
        if ortho["auto"].as_bool() == Some(true) || width <= 0.0 || height <= 0.0 {
            let area = |l: &&Layer| l.size[0] * l.size[1];
            if let Some(l) = scene.layers.iter().max_by(|a, b| area(a).total_cmp(&area(b))).filter(|l| area(l) > 0.0) {
                (scene.width, scene.height) = (l.size[0], l.size[1]);
            }
        }
        Ok(scene)
    }

    /// One drawable object; also used for layers a script creates at run time.
    pub fn layer(
        vfs: &Vfs,
        obj: &Value,
        group: bool,
        warnings: &mut Vec<String>,
    ) -> Result<Layer, Error> {
        let name = obj["name"].as_str().unwrap_or("").to_string();
        let text = obj
            .get("text")
            .filter(|v| !v.is_null())
            // Missing keys take Wallpaper Engine's defaults: 32 pt, centred both ways, padding 32.
            .map(|t| TextLayer {
                font: obj["font"].as_str().unwrap_or("Helvetica").to_string(),
                point_size: obj["pointsize"].as_f64().unwrap_or(32.0) as f32,
                horizontal_align: obj["horizontalalign"]
                    .as_str()
                    .unwrap_or("center")
                    .to_string(),
                vertical_align: obj["verticalalign"].as_str().unwrap_or("center").to_string(),
                padding: vec_n(obj.get("padding"), [32.0, 32.0]),
                color_blend_mode: obj["colorBlendMode"].as_i64().unwrap_or(0),
                value: t["value"].as_str().unwrap_or("").to_string(),
            });
        let particles = obj
            .get("particle")
            .and_then(Value::as_str)
            .map(|system| ParticleLayer {
                system: system.to_string(),
                instance_override: obj
                    .get("instanceoverride")
                    .filter(|v| !v.is_null())
                    .cloned(),
            });
        let mut puppet = None;
        let mut fullscreen = false;
        let mut passthrough = false;
        let material = if group || text.is_some() || particles.is_some() {
            None
        } else {
            let model = vfs.json(obj["image"].as_str().unwrap_or(""))?;
            fullscreen = model["fullscreen"].as_bool() == Some(true);
            passthrough = model["passthrough"].as_bool() == Some(true);
            if let Some(path) = model["puppet"].as_str() {
                let animations = obj["animationlayers"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|a| PuppetAnimation {
                        id: a["animation"].as_i64().unwrap_or(-1),
                        rate: Bound::parse(a.get("rate"), Value::from(1.0)),
                        blend: Bound::parse(a.get("blend"), Value::from(1.0)),
                        additive: a["additive"].as_bool().unwrap_or(false),
                        visible: Bound::parse(a.get("visible"), Value::Bool(true)),
                        blend_in: a["blendin"].as_bool().unwrap_or(false),
                        blend_out: a["blendout"].as_bool().unwrap_or(false),
                        blend_time: a["blendtime"].as_f64().unwrap_or(0.5) as f32,
                    })
                    .collect();
                puppet = Some(PuppetLayer {
                    model: path.to_string(),
                    animations,
                });
            }
            let path = model["material"]
                .as_str()
                .ok_or_else(|| Error::Format("model has no material".into()))?;
            let mut material = Material::load(vfs, path)?;
            // The layer's colour blend mode blends it with what is behind it (reads the frame).
            if let Some(mode) = obj["colorBlendMode"].as_i64().filter(|&m| m != 0) {
                let _ = material.combos.insert("BLENDMODE".into(), mode);
            }
            Some(material)
        };
        let id = obj["id"].as_i64().unwrap_or(-1);
        let mut effects = Vec::new();
        for e in obj["effects"].as_array().into_iter().flatten() {
            match Self::effect(vfs, e) {
                Ok(effect) => effects.push(effect),
                Err(err) => {
                    warnings.push(format!("layer {name}: effect {} skipped: {err}", e["file"]))
                }
            }
        }
        // The editor may store the effect chain buffer a pass read when the scene was authored,
        // `_rt_imageLayerComposite_<own id>_a` or `_b`: Wallpaper Engine ping-pongs the chain
        // between the two, so that name is the output of the effect before. It reads the same
        // image as `previous` here, where the chain has no named buffers.
        let own = format!("_rt_imageLayerComposite_{id}_");
        for pass in effects.iter_mut().flat_map(|e| e.passes.iter_mut()) {
            for (slot, texture) in pass.material.textures.iter_mut().enumerate() {
                if texture.as_deref().is_some_and(|t| t.starts_with(&own)) {
                    *texture = None;
                    pass.binds.push(("previous".into(), slot));
                }
            }
        }
        Ok(Layer {
            id,
            name,
            parent: obj["parent"].as_i64(),
            attachment: obj["attachment"].as_str().filter(|a| !a.is_empty()).map(str::to_string),
            origin: Bound::parse(obj.get("origin"), Value::String("0 0 0".into())),
            scale: Bound::parse(obj.get("scale"), Value::String("1 1 1".into())),
            angles: Bound::parse(obj.get("angles"), Value::String("0 0 0".into())),
            size: vec_n(obj.get("size"), [0.0, 0.0]),
            // Wallpaper Engine's default: a layer moves fully with camera parallax unless its
            // depth says otherwise (scenes store "0 0" for the layers that stay).
            parallax_depth: Bound::parse(obj.get("parallaxDepth"), Value::from("1 1")),
            alpha: Bound::parse(obj.get("alpha"), Value::from(1.0)),
            color: Bound::parse(obj.get("color"), Value::String("1 1 1".into())),
            brightness: floats(obj.get("brightness").unwrap_or(&Value::from(1.0)))
                .first()
                .copied()
                .unwrap_or(1.0),
            visible: Bound::parse(obj.get("visible"), Value::Bool(true)),
            text,
            particles,
            puppet,
            model: None,
            fullscreen,
            passthrough,
            copy_background: obj["copybackground"].as_bool().unwrap_or(true),
            alignment: if material.is_some() { alignment(&obj["alignment"]) } else { [0.0; 2] },
            material,
            effects,
        })
    }

    fn effect(vfs: &Vfs, obj: &Value) -> Result<Effect, Error> {
        let file = obj["file"].as_str().unwrap_or("");
        let json = vfs.json(file)?;
        let overrides = obj["passes"].as_array().cloned().unwrap_or_default();
        let mut passes = Vec::new();
        for (i, p) in json["passes"].as_array().into_iter().flatten().enumerate() {
            let path = p["material"]
                .as_str()
                .ok_or_else(|| Error::Format("effect pass has no material".into()))?;
            let mut material = Material::load(vfs, path)?;
            if let Some(o) = overrides.get(i) {
                material.apply_overrides(o);
            }
            let binds = p["bind"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|b| {
                    Some((
                        b["name"].as_str()?.to_string(),
                        b["index"].as_u64()? as usize,
                    ))
                })
                .collect();
            passes.push(EffectPass {
                material,
                target: p["target"].as_str().map(str::to_string),
                binds,
            });
        }
        let fbos = json["fbos"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|f| {
                Some(Fbo {
                    name: f["name"].as_str()?.to_string(),
                    scale: f["scale"].as_f64().unwrap_or(1.0) as f32,
                })
            })
            .collect();
        Ok(Effect {
            name: json["name"].as_str().unwrap_or(file).to_string(),
            visible: Bound::parse(obj.get("visible"), Value::Bool(true)),
            passes,
            fbos,
        })
    }
}

/// A user property from `project.json` (`general.properties`).
#[derive(Debug, Clone)]
pub struct Property {
    pub name: String,
    pub kind: String,
    pub label: String,
    pub value: Value,
    pub order: i64,
}

pub fn project_properties(project: &Value) -> Vec<Property> {
    let mut out: Vec<Property> = project["general"]["properties"]
        .as_object()
        .into_iter()
        .flatten()
        .map(|(name, p)| Property {
            name: name.clone(),
            kind: p["type"].as_str().unwrap_or("").to_string(),
            label: p["text"].as_str().unwrap_or(name).to_string(),
            value: p["value"].clone(),
            order: p["order"].as_i64().unwrap_or(0),
        })
        .collect();
    out.sort_by_key(|p| p.order);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn bound_values_follow_user_properties() {
        let props: HashMap<String, Value> = [
            ("bg".to_string(), json!("2")),
            ("on".to_string(), json!(false)),
        ]
        .into();
        let combo = Bound::parse(
            Some(&json!({"user": {"name": "bg", "condition": "1"}, "value": true})),
            Value::Null,
        );
        assert!(!combo.truthy(&props));
        let plain = Bound::parse(Some(&json!({"user": "on", "value": true})), Value::Null);
        assert!(!plain.truthy(&props));
        let fixed = Bound::parse(Some(&json!("1 2 3")), Value::Null);
        assert_eq!(floats(&fixed.get(&props)), vec![1.0, 2.0, 3.0]);
    }

    #[test]
    fn comma_separated_values_keep_every_component() {
        assert_eq!(floats(&json!("0.0, 1.0")), vec![0.0, 1.0]);
        assert_eq!(floats(&json!("0.05,0.00")), vec![0.05, 0.0]);
    }
}
