//! SceneScript: the JavaScript a scene attaches to object values (clock text, audio-driven
//! scale, visualiser bars). One QuickJS runtime per scene runs every script; the environment the
//! scripts see is `script_prelude.js`. All traffic between Rust and JavaScript is JSON text, once
//! per script at load and once per frame, which keeps this file free of per-type bindings.

use std::cell::RefCell;
use std::rc::Rc;

use rquickjs::loader::{BuiltinLoader, BuiltinResolver};
use rquickjs::{CatchResultExt, Context, Function, Module, Object, Runtime};
use serde_json::{Map, Value};

use crate::Error;

const PRELUDE: &str = include_str!("script_prelude.js");

/// Helper modules a script may import by name: module name, prelude object, exported names.
const MODULES: [(&str, &str, &[&str]); 3] = [
    (
        "WEMath",
        "__WEMath",
        &["PI", "deg2rad", "rad2deg", "clamp", "mix", "lerp", "smoothStep", "fract"],
    ),
    ("WEVector", "__WEVector", &["Vec2", "Vec3", "Vec4", "angleVector2", "vectorAngle2"]),
    ("WEColor", "__WEColor", &["rgb2hsv", "hsv2rgb", "normalizeColor", "expandColor"]),
];

/// A layer a script created with `thisScene.createLayer`.
#[derive(Debug, Clone)]
pub struct Created {
    pub id: i64,
    pub path: String,
    /// The `__workshopId` of the creating script: its asset paths live under `workshop/<id>/`.
    pub workshop: String,
}

/// What scripts changed since the last call.
#[derive(Debug, Default)]
pub struct Events {
    /// New value of a scripted field, by script id.
    pub values: Vec<(usize, Value)>,
    /// Layer fields set through `thisLayer` / `thisScene` objects, by layer id.
    pub dirty: Vec<(i64, Map<String, Value>)>,
    /// Scene settings (`thisScene.bloom` and the like) written by scripts, by documented name.
    pub scene: Map<String, Value>,
    pub created: Vec<Created>,
    /// Draw-order moves: layer id, new index.
    pub moves: Vec<(i64, usize)>,
    /// Everything in the scripts' `localStorage`, when they changed it.
    pub storage: Option<Value>,
}

impl Events {
    fn parse(text: &str) -> Self {
        let v: Value = serde_json::from_str(text).unwrap_or(Value::Null);
        let values = v["values"]
            .as_object()
            .into_iter()
            .flatten()
            .filter_map(|(k, v)| Some((k.parse().ok()?, v.clone())))
            .collect();
        let dirty = v["dirty"]
            .as_object()
            .into_iter()
            .flatten()
            .filter_map(|(k, v)| Some((k.parse().ok()?, v.as_object()?.clone())))
            .collect();
        let scene = v["scene"].as_object().cloned().unwrap_or_default();
        let created = v["created"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| {
                Some(Created {
                    id: c["id"].as_i64()?,
                    path: c["path"].as_str()?.to_string(),
                    workshop: c["workshop"].as_str().unwrap_or("").to_string(),
                })
            })
            .collect();
        let moves = v["moves"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|m| Some((m["id"].as_i64()?, m["index"].as_u64()? as usize)))
            .collect();
        let storage = Some(v["storage"].clone()).filter(Value::is_object);
        Self { values, dirty, scene, created, moves, storage }
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
            && self.dirty.is_empty()
            && self.scene.is_empty()
            && self.created.is_empty()
            && self.moves.is_empty()
            && self.storage.is_none()
    }
}

/// Per-frame input to the scripts.
#[derive(Debug, Clone)]
pub struct FrameState {
    pub time: f32,
    pub frame_time: f32,
    /// Fraction of the local day, 0..1.
    pub time_of_day: f32,
    pub screen: [f32; 2],
    pub canvas: [f32; 2],
    /// Pointer in screen pixels and in scene units.
    pub cursor: [f32; 2],
    pub cursor_world: [f32; 2],
    /// Left button held.
    pub cursor_down: bool,
    /// Audio spectrum, 0..1 per band, any band count.
    pub left: Vec<f32>,
    pub right: Vec<f32>,
    /// Ids of the sound objects that are playing.
    pub playing: Vec<i64>,
    /// This frame's pose of every puppet scripts work with, by layer id (`Value::Null` when no
    /// script uses the puppet calls).
    pub puppets: Value,
}

pub struct Host {
    // Field order matters: the context must drop before its runtime.
    ctx: Context,
    _rt: Runtime,
    log: Rc<RefCell<Vec<String>>>,
    count: usize,
}

impl std::fmt::Debug for Host {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Host").field("scripts", &self.count).finish()
    }
}

fn js(e: impl std::fmt::Display) -> Error {
    Error::Unsupported(format!("script: {e}"))
}

impl Host {
    pub fn new() -> Result<Self, Error> {
        let rt = Runtime::new().map_err(js)?;
        // Scene scripts are small; these bounds stop a runaway script from taking the process.
        rt.set_memory_limit(64 << 20);
        rt.set_max_stack_size(1 << 20);
        let mut resolver = BuiltinResolver::default();
        let mut loader = BuiltinLoader::default();
        for (name, global, exports) in MODULES {
            // Named exports one by one: QuickJS drops destructured `export const { .. } = m`.
            let mut source = format!("const m = globalThis.{global};\nexport default m;\n");
            for e in exports {
                source.push_str(&format!("export const {e} = m.{e};\n"));
            }
            resolver.add_module(name);
            loader.add_module(name, source);
        }
        rt.set_loader(resolver, loader);
        let ctx = Context::full(&rt).map_err(js)?;
        let log = Rc::new(RefCell::new(Vec::new()));
        let sink = log.clone();
        ctx.with(|ctx| -> Result<(), Error> {
            let f = Function::new(ctx.clone(), move |s: String| {
                let mut l = sink.borrow_mut();
                // Keep the log bounded: a script logging every frame must not grow memory.
                if l.len() < 64 {
                    l.push(s);
                }
            })
            .map_err(js)?;
            ctx.globals().set("__wm_log", f).map_err(js)?;
            ctx.eval::<(), _>(PRELUDE).catch(&ctx).map_err(js)?;
            Ok(())
        })?;
        Ok(Self { ctx, _rt: rt, log, count: 0 })
    }

    /// Replaces the scripts' view of the scene's layers (draw order, current values).
    pub fn set_layers(&mut self, layers: &Value) -> Result<(), Error> {
        let text = layers.to_string();
        self.call("__wm_layers", text).map(|_| ())
    }

    /// Evaluates one script module and runs its `init`. Returns the events it caused, with the
    /// script's starting value under its id.
    pub fn add(
        &mut self,
        id: usize,
        layer_id: i64,
        field: &str,
        source: &str,
        properties: &Value,
        value: &Value,
    ) -> Result<Events, Error> {
        self.count += 1;
        let props = if properties.is_object() { properties.to_string() } else { "{}".into() };
        let out = self.ctx.with(|ctx| -> Result<String, Error> {
            let begin: Function = ctx.globals().get("__wm_begin").map_err(js)?;
            begin.call::<_, ()>((layer_id, props)).catch(&ctx).map_err(js)?;
            let name = format!("layer{layer_id}/{field}");
            let module = Module::declare(ctx.clone(), name, source).catch(&ctx).map_err(js)?;
            let (module, done) = module.eval().catch(&ctx).map_err(js)?;
            done.finish::<()>().catch(&ctx).map_err(js)?;
            let ns: Object = module.namespace().catch(&ctx).map_err(js)?;
            let register: Function = ctx.globals().get("__wm_register").map_err(js)?;
            register
                .call::<_, String>((id, ns, layer_id, field, value.to_string()))
                .catch(&ctx)
                .map_err(js)
        })?;
        Ok(Events::parse(&out))
    }

    /// Runs every script's `update` for one frame.
    pub fn frame(&mut self, s: &FrameState) -> Result<Events, Error> {
        let input = serde_json::json!({
            "time": s.time,
            "dt": s.frame_time,
            "tod": s.time_of_day,
            "screen": s.screen,
            "canvas": s.canvas,
            "cursor": s.cursor,
            "cursorWorld": s.cursor_world,
            "down": s.cursor_down,
            "left": s.left,
            "right": s.right,
            "playing": s.playing,
            "puppets": s.puppets,
        });
        let out = self.call("__wm_frame", input.to_string())?;
        Ok(Events::parse(&out))
    }

    /// Puts back what the scripts kept in `localStorage` in an earlier run (a JSON object).
    pub fn set_storage(&mut self, json: &str) -> Result<(), Error> {
        self.call("__wm_storage", json.to_string()).map(|_| ())
    }

    /// User property values that changed (all of them once after the scripts started), for
    /// `engine.userProperties` and every script's `applyUserProperties`. `colors` names the
    /// colour properties, which scripts see as vectors.
    pub fn user_properties(&mut self, values: &Map<String, Value>, colors: &[String]) -> Result<Events, Error> {
        let input = serde_json::json!({ "values": values, "colors": colors });
        let out = self.call("__wm_user_properties", input.to_string())?;
        Ok(Events::parse(&out))
    }

    /// Whether any script wants to run every frame.
    pub fn animated(&self) -> bool {
        self.ctx.with(|ctx| {
            ctx.globals()
                .get::<_, Function>("__wm_animated")
                .and_then(|f| f.call::<_, bool>(()))
                .unwrap_or(false)
        })
    }

    /// Messages scripts printed, and errors they threw, since the last call.
    pub fn take_log(&mut self) -> Vec<String> {
        std::mem::take(&mut *self.log.borrow_mut())
    }

    fn call(&self, name: &str, arg: String) -> Result<String, Error> {
        self.ctx.with(|ctx| {
            let f: Function = ctx.globals().get(name).map_err(js)?;
            f.call::<_, String>((arg,)).catch(&ctx).map_err(js)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn host_with_layer() -> Host {
        let mut h = Host::new().expect("runtime");
        h.set_layers(&json!([{ "id": 7, "name": "clock", "origin": "10 20 0", "scale": "1 1 1",
            "angles": "0 0 0", "color": "1 1 1", "alpha": 1.0, "visible": true, "text": "" }]))
            .expect("layers");
        h
    }

    fn frame_state(time: f32) -> FrameState {
        FrameState {
            time,
            frame_time: 1.0 / 30.0,
            time_of_day: 0.5,
            screen: [1920.0, 1080.0],
            canvas: [1920.0, 1080.0],
            cursor: [0.0, 0.0],
            cursor_world: [0.0, 0.0],
            cursor_down: false,
            left: vec![1.0; 64],
            right: vec![0.0; 64],
            playing: vec![],
            puppets: Value::Null,
        }
    }

    fn frame(h: &mut Host, time: f32) -> Events {
        h.frame(&frame_state(time)).expect("frame")
    }

    #[test]
    fn a_text_script_returns_its_value_and_reads_its_properties() {
        let mut h = host_with_layer();
        let src = "'use strict';\n\
            export var scriptProperties = createScriptProperties()\n\
              .addText({ name: 'delimiter', value: ':' }).finish();\n\
            export function update(value) { return 'a' + scriptProperties.delimiter + 'b'; }";
        let e = h.add(0, 7, "text", src, &json!({ "delimiter": "-" }), &json!("x")).expect("add");
        assert_eq!(e.values, vec![(0, json!("x"))]);
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!("a-b"))]);
    }

    #[test]
    fn scripts_drive_a_layers_keyframed_animation_in_order() {
        let mut h = Host::new().expect("runtime");
        h.set_layers(&json!([{ "id": 7, "name": "eye", "origin": "0 0 0", "scale": "1 1 1",
            "angles": "0 0 0", "color": "1 1 1", "alpha": 1.0, "visible": true, "text": "",
            "animations": [{ "name": "click", "fps": 30, "frameCount": 90, "rate": 1, "playing": false, "frame": 0 }] }]))
            .expect("layers");
        let src = "'use strict';\n\
            export function update(value) {\n\
              const a = thisLayer.getAnimation('click');\n\
              if (!a.isPlaying()) { a.stop(); a.play(); }\n\
              thisLayer.getAnimation('missing').play();\n\
              return value;\n\
            }";
        let _ = h.add(0, 7, "alpha", src, &json!({}), &json!(1.0)).expect("add");
        let e = frame(&mut h, 1.0);
        let commands = e.dirty.iter().find(|(id, _)| *id == 7).map(|(_, f)| f.clone());
        let commands = commands.expect("the layer has changes");
        assert!(commands.iter().any(|(k, v)| k == "animation:click" && v == &json!("stop;play")), "{commands:?}");
        // The next frame starts a new queue; the animation now plays.
        let e = frame(&mut h, 1.1);
        assert!(e.dirty.iter().all(|(_, f)| f.iter().all(|(k, _)| k != "animation:click")));
    }

    #[test]
    fn sound_layers_obey_scripts_and_user_properties_reach_them() {
        let mut h = Host::new().expect("runtime");
        h.set_layers(&json!([
            { "id": 7, "name": "dino", "origin": "0 0 0", "scale": "1 1 1", "angles": "0 0 0",
              "color": "1 1 1", "alpha": 1.0, "visible": true, "text": "" },
            { "id": 9, "name": "jump", "sound": true, "volume": 1.0, "playing": false },
        ]))
        .expect("layers");
        let src = "'use strict';\n\
            let level = '';\n\
            export function applyUserProperties(p) { if (p.level) level = p.level; }\n\
            export function update(value) {\n\
              if (level === 'mario') { thisScene.getLayer('jump').play(); level = ''; }\n\
              return engine.userProperties.tint.x;\n\
            }";
        let _ = h.add(0, 7, "alpha", src, &json!({}), &json!(1.0)).expect("add");
        let values = json!({ "level": "mario", "tint": "0.5 0 0" });
        let _ = h.user_properties(values.as_object().unwrap(), &["tint".to_string()]).expect("props");
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!(0.5))]);
        let jump = e.dirty.iter().find(|(id, _)| *id == 9).map(|(_, d)| d.clone());
        assert_eq!(jump.and_then(|d| d.get("sound").cloned()), Some(json!("play")));
        // The sound object is not one of the drawn layers.
        let src = "'use strict';\nexport function update(v) { return thisScene.getLayerCount(); }";
        let _ = h.add(1, 7, "alpha", src, &json!({}), &json!(1.0)).expect("add");
        assert!(frame(&mut h, 2.0).values.contains(&(1, json!(1))));
    }

    #[test]
    fn local_storage_is_restored_and_reported_when_it_changes() {
        let mut h = host_with_layer();
        h.set_storage(r#"{"highscore": 7}"#).expect("storage");
        let src = "'use strict';\n\
            export function update(value) {\n\
              const best = localStorage.get('highscore', localStorage.LOCATION_GLOBAL);\n\
              if (best < 8) localStorage.set('highscore', best + 1, localStorage.LOCATION_GLOBAL);\n\
              return best;\n\
            }";
        let _ = h.add(0, 7, "alpha", src, &json!({}), &json!(1.0)).expect("add");
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!(7))]);
        assert_eq!(e.storage, Some(json!({ "highscore": 8 })));
        // Unchanged storage is not sent again.
        assert_eq!(frame(&mut h, 2.0).storage, None);
    }

    #[test]
    fn scene_settings_written_by_scripts_are_reported() {
        let mut h = host_with_layer();
        let src = "export function init() { thisScene.bloomstrength = 3; thisScene.clearcolor = '0.1 0.2 0.3'; }";
        let e = h.add(0, 7, "alpha", src, &Value::Null, &json!(1)).expect("add");
        assert_eq!(e.scene.get("bloomstrength"), Some(&json!(3)));
        assert_eq!(e.scene.get("clearcolor"), Some(&json!("0.1 0.2 0.3")));
    }

    #[test]
    fn a_vector_value_round_trips_as_text() {
        let mut h = host_with_layer();
        let src = "export function update(value) { return value.multiply(2); }";
        let _ = h.add(0, 7, "scale", src, &Value::Null, &json!("1 2 3")).expect("add");
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!("2 4 6"))]);
    }

    #[test]
    fn layer_writes_and_created_layers_are_reported() {
        let mut h = host_with_layer();
        let src = "let bar;\n\
            export function init() { bar = thisScene.createLayer('models/bar.json');\n\
              thisScene.sortLayer(bar, 0); }\n\
            export function update() { thisLayer.origin = new Vec3(1, 2, 3); bar.alpha = 0.5; }";
        let e = h.add(0, 7, "visible", src, &Value::Null, &json!(true)).expect("add");
        assert_eq!(e.created.len(), 1);
        assert_eq!(e.created[0].path, "models/bar.json");
        assert_eq!(e.moves, vec![(e.created[0].id, 0)]);
        let e = frame(&mut h, 1.0);
        let origin = e.dirty.iter().find(|(id, _)| *id == 7).map(|(_, d)| d["origin"].clone());
        assert_eq!(origin, Some(json!("1 2 3")));
        assert!(e.dirty.iter().any(|(_, d)| d.get("alpha") == Some(&json!(0.5))));
        assert!(e.values.is_empty());
    }

    #[test]
    fn audio_buffers_follow_the_spectrum() {
        let mut h = host_with_layer();
        let src = "const a = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);\n\
            export function update() { return a.left[3] + a.average[3]; }";
        let _ = h.add(0, 7, "alpha", src, &Value::Null, &json!(0)).expect("add");
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!(1.5))]);
    }

    #[test]
    fn a_throwing_script_is_disabled_and_logged() {
        let mut h = host_with_layer();
        let src = "export function update() { throw new Error('boom'); }";
        let _ = h.add(0, 7, "alpha", src, &Value::Null, &json!(1)).expect("add");
        let _ = frame(&mut h, 1.0);
        assert!(h.take_log().iter().any(|l| l.contains("boom")));
        assert!(!h.animated());
    }

    #[test]
    fn a_layer_is_dragged_by_cursor_events() {
        let mut h = host_with_layer();
        let src = "let drag = false, off;\n\
            export function cursorDown(e) { drag = true; off = thisLayer.origin.subtract(e.worldPosition); }\n\
            export function cursorUp(e) { drag = false; }\n\
            export function cursorMove(e) { if (drag) thisLayer.origin = e.worldPosition.add(off); }";
        let _ = h.add(0, 7, "origin", src, &Value::Null, &json!("10 20 0")).expect("add");
        let at = |h: &mut Host, x: f32, y: f32, down: bool| {
            h.frame(&FrameState { cursor_world: [x, y], cursor_down: down, ..frame_state(1.0) }).expect("frame")
        };
        // A press away from the layer (it has no size, so only its origin hits) moves nothing.
        let e = at(&mut h, 500.0, 500.0, true);
        assert!(e.dirty.is_empty(), "{:?}", h.take_log());
        let _ = at(&mut h, 500.0, 500.0, false);
        // Press on it, drag by (5, 5), release.
        let _ = at(&mut h, 10.0, 20.0, true);
        let e = at(&mut h, 15.0, 25.0, true);
        let origin = e.dirty.iter().find(|(id, _)| *id == 7).map(|(_, d)| d["origin"].clone());
        assert_eq!(origin, Some(json!("15 25 0")), "{:?}", h.take_log());
        let _ = at(&mut h, 15.0, 25.0, false);
        let e = at(&mut h, 99.0, 99.0, false);
        assert!(e.dirty.is_empty());
    }

    #[test]
    fn puppet_calls_read_this_frames_pose_and_report_overrides() {
        let mut h = Host::new().expect("runtime");
        h.set_layers(&json!([{ "id": 7, "name": "girl", "origin": "0 0 0", "scale": "1 1 1",
            "angles": "0 0 0", "color": "1 1 1", "alpha": 1.0, "visible": true, "text": "",
            "puppet": { "bones": [{ "name": "root", "parent": -1 }, { "name": "arm", "parent": 0 }],
                "shapes": ["smile"], "animations": [{ "id": 5, "name": "wave", "fps": 30, "frames": 60, "mode": "loop" }] } }]))
            .expect("layers");
        let src = "let wave, ended = 0;\n\
            export function update() {\n\
              const out = [thisLayer.getBoneCount(), thisLayer.getBoneIndex('arm'), thisLayer.getBoneParentIndex('arm')];\n\
              const t = thisLayer.getBoneTransform('arm');\n\
              out.push(t.m[12], t.m[13], thisLayer.getLocalBoneOrigin(1).x);\n\
              thisLayer.setLocalBoneOrigin(0, new Vec3(0, 20, 0));\n\
              out.push(thisLayer.getBoneTransform(1).m[13]);\n\
              thisLayer.setLocalBoneAngles(1, new Vec3(0, 0, Math.PI / 2));\n\
              out.push(Math.round(thisLayer.getLocalBoneAngles(1).z * 1000), thisLayer.getLocalBoneOrigin(1).x);\n\
              thisLayer.setBlendShapeWeight('smile', 0.75);\n\
              out.push(thisLayer.getBlendShapeWeight(0));\n\
              if (!wave) { wave = thisLayer.createAnimationLayer('wave', { rate: 2 }); wave.addEndedCallback(() => ended++); }\n\
              out.push(thisLayer.getAnimationLayerCount(), ended);\n\
              return out.join(',');\n\
            }";
        let _ = h.add(0, 7, "alpha", src, &Value::Null, &json!("")).expect("add");
        // Bone 0 at (0, 10), bone 1 five units along it; the layer sits 100 units right.
        let translate = |x: f32, y: f32| vec![1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., x, y, 0., 1.];
        let model = [translate(0.0, 10.0), translate(5.0, 10.0)].concat();
        let pose = |layers: Value, ended: Value| {
            json!({ "7": { "world": translate(100.0, 0.0), "model": model, "weights": [0.0], "layers": layers, "ended": ended } })
        };
        let at = |h: &mut Host, puppets: Value| {
            h.frame(&FrameState { puppets, ..frame_state(1.0) }).expect("frame")
        };
        let e = at(&mut h, pose(json!([]), json!([])));
        assert_eq!(e.values, vec![(0, json!("2,1,0,105,10,5,20,1571,5,0.75,1,0"))], "{:?}", h.take_log());
        let calls = e.dirty.iter().find(|(id, _)| *id == 7).and_then(|(_, d)| d["puppet"].as_str().map(str::to_string));
        let calls: Value = serde_json::from_str(&calls.expect("puppet calls")).expect("json");
        let ops: Vec<&str> = calls.as_array().expect("list").iter().map(|c| c["op"].as_str().unwrap_or("")).collect();
        assert_eq!(ops, ["bone", "bone", "bone", "shape", "create"]);
        let create = &calls[4];
        assert_eq!((&create["cfg"]["animation"], &create["cfg"]["rate"]), (&json!(5), &json!(2)));
        // The renderer reports the new layer and its first wrap: the callback runs before update.
        let uid = create["uid"].clone();
        let e = at(&mut h, pose(json!([{ "uid": uid, "name": "", "animation": 5, "playing": true }]), json!([uid])));
        assert!(matches!(&e.values[..], [(0, Value::String(s))] if s.ends_with(",1,1")), "{:?}", e.values);
    }

    #[test]
    fn helper_modules_can_be_imported() {
        let mut h = host_with_layer();
        let src = "import * as WEMath from 'WEMath';\n\
            export function update() { return WEMath.clamp(5, 0, 1); }";
        let _ = h.add(0, 7, "alpha", src, &Value::Null, &json!(0)).expect("add");
        let e = frame(&mut h, 1.0);
        assert_eq!(e.values, vec![(0, json!(1))], "{:?}", h.take_log());
    }
}
