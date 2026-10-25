//! Glue between the engine and the SceneScript host: what scripts see of the layers, and how
//! their results land back in the scene.

use serde_json::{json, Map, Value};

use super::{Engine, FrameInput};
use crate::particles;
use crate::scene::{floats, Bound, Scene};
use crate::script::{Created, Events, FrameState, Host};

/// What a script write requires before the next draw.
#[derive(Debug, Default, Clone, Copy)]
struct Changes {
    place: bool,
    text: bool,
    rebuild: bool,
}

fn fixed(value: Value) -> Bound {
    Bound { value, user: None, condition: None }
}

impl Engine {
    /// Starts the scene's scripts, if it has any. Failures become load warnings; the scene still
    /// draws with the values stored in the file.
    pub(super) fn start_scripts(&mut self) {
        if self.scene.scripts.is_empty() {
            return;
        }
        let mut host = match Host::new() {
            Ok(h) => h,
            Err(e) => {
                self.warnings.push(format!("{e}; scripts disabled"));
                return;
            }
        };
        if let Err(e) = host.set_layers(&self.script_layers()) {
            self.warnings.push(format!("{e}; scripts disabled"));
            return;
        }
        // What the scripts stored in earlier runs; a missing or unreadable file is a first run.
        let stored = self.script_storage.as_ref().and_then(|p| std::fs::read_to_string(p).ok());
        if let Some(text) = stored.filter(|t| serde_json::from_str::<Map<String, Value>>(t).is_ok()) {
            if let Err(e) = host.set_storage(&text) {
                self.warnings.push(format!("{e}; stored script values not restored"));
            }
        }
        let mut all = Events::default();
        for id in 0..self.scene.scripts.len() {
            let spec = self.scene.scripts[id].clone();
            let Some(index) = self.layer_index(spec.layer_id) else { continue };
            let Some(value) = self.field_value(index, &spec.field) else {
                self.warnings.push(format!(
                    "layer {}: script on {} not supported",
                    self.scene.layers[index].name, spec.field
                ));
                continue;
            };
            match host.add(id, spec.layer_id, &spec.field, &spec.source, &spec.properties, &value) {
                Ok(e) => {
                    all.values.extend(e.values);
                    all.dirty.extend(e.dirty);
                    all.created.extend(e.created);
                    all.moves.extend(e.moves);
                }
                Err(e) => self.warnings.push(format!(
                    "layer {}: {} script: {e}",
                    self.scene.layers[index].name, spec.field
                )),
            }
        }
        for line in host.take_log() {
            self.warnings.push(line);
        }
        self.script_host = Some(host);
        self.apply_script_events(all);
        // Scripts learn the stored property values the way they learn later changes.
        let values: Map<String, Value> = self.props.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        self.notify_scripts(&values);
    }

    /// Hands changed user property values to the scripts (`engine.userProperties` and their
    /// `applyUserProperties`) and applies what they change in return.
    pub(super) fn notify_scripts(&mut self, values: &Map<String, Value>) {
        let Some(host) = self.script_host.as_mut() else { return };
        let events = host.user_properties(values, &self.color_properties);
        self.warnings.extend(host.take_log());
        match events {
            Ok(events) if !events.is_empty() => self.apply_script_events(events),
            Ok(_) => {}
            Err(e) => self.warnings.push(format!("{e}; user properties not sent to scripts")),
        }
    }

    /// Runs one frame of every script and applies what they changed.
    pub(super) fn run_scripts(&mut self, input: FrameInput, screen: [f32; 2]) {
        // The pointer in scene units (y up), through the same view the frame is drawn with.
        let (l, r, t, b) = self.view_rect(screen[0], screen[1]);
        let Some(host) = self.script_host.as_mut() else { return };
        let (w, h) = (self.scene.width, self.scene.height);
        let [px, py] = input.pointer;
        let state = FrameState {
            time: input.time,
            frame_time: input.frame_time,
            time_of_day: super::day_time(),
            screen,
            canvas: [w, h],
            cursor: [input.pointer[0] * screen[0], input.pointer[1] * screen[1]],
            cursor_world: [l + px * (r - l), h - (t + py * (b - t))],
            cursor_down: input.pointer_down,
            left: self.audio[0].clone(),
            right: self.audio[1].clone(),
            playing: self.sounds.playing(),
        };
        let events = match host.frame(&state) {
            Ok(e) => e,
            Err(e) => {
                self.warnings.push(format!("{e}; scripts stopped"));
                self.script_host = None;
                return;
            }
        };
        let log = host.take_log();
        self.warnings.extend(log);
        if !events.is_empty() {
            self.apply_script_events(events);
        }
    }

    pub(super) fn scripts_animated(&self) -> bool {
        self.script_host.as_ref().is_some_and(Host::animated)
    }

    /// The scripts' view of every layer, in draw order, followed by the sound objects.
    fn script_layers(&self) -> Value {
        let sounds = self.sounds.script_view().into_iter().map(|(id, name, volume, playing)| {
            json!({ "id": id, "name": name, "sound": true, "volume": volume, "playing": playing })
        });
        let layers = self
            .scene
            .layers
            .iter()
            .map(|l| {
                json!({
                    "id": l.id,
                    "name": l.name,
                    "parent": l.parent,
                    "origin": text3(&l.origin.get(&self.props)),
                    "scale": text3(&l.scale.get(&self.props)),
                    "angles": text3(&l.angles.get(&self.props)),
                    "color": text3(&l.color.get(&self.props)),
                    "alpha": floats(&l.alpha.get(&self.props)).first().copied().unwrap_or(1.0),
                    "visible": l.visible.truthy(&self.props),
                    "text": l.text.as_ref().map(|t| t.value.clone()).unwrap_or_default(),
                    "size": format!("{} {}", l.size[0], l.size[1]),
                    "parallaxDepth": text3(&l.parallax_depth.get(&self.props)),
                    "effects": l.effects.iter().map(|e| json!({
                        "name": e.name,
                        "visible": e.visible.truthy(&self.props),
                        "passes": e.passes.iter().map(|p| {
                            p.material.constants.iter()
                                .map(|(k, v)| (k.clone(), v.get(&self.props)))
                                .collect::<Map<_, _>>()
                        }).collect::<Vec<_>>(),
                    })).collect::<Vec<_>>(),
                })
            })
            .chain(sounds)
            .collect();
        Value::Array(layers)
    }

    fn layer_index(&self, id: i64) -> Option<usize> {
        self.scene.layers.iter().position(|l| l.id == id)
    }

    /// Current value of a scripted field, as the scene file would store it.
    fn field_value(&self, index: usize, field: &str) -> Option<Value> {
        let l = &self.scene.layers[index];
        Some(match field {
            "origin" => l.origin.get(&self.props),
            "scale" => l.scale.get(&self.props),
            "angles" => l.angles.get(&self.props),
            "color" => l.color.get(&self.props),
            "alpha" => l.alpha.get(&self.props),
            "visible" => Value::Bool(l.visible.truthy(&self.props)),
            "text" => Value::String(l.text.as_ref()?.value.clone()),
            _ if field.starts_with("effects[") => {
                let (n, constant) = effect_field(field)?;
                let effect = l.effects.get(n)?;
                match constant {
                    None => Value::Bool(effect.visible.truthy(&self.props)),
                    Some((pass, key)) => {
                        effect.passes.get(pass)?.material.constants.get(key)?.get(&self.props)
                    }
                }
            }
            _ => {
                let key = field.strip_prefix("instanceoverride.")?;
                let v = l.particles.as_ref()?.instance_override.as_ref()?.get(key)?;
                v.get("value").cloned().unwrap_or_else(|| v.clone())
            }
        })
    }

    fn apply_script_events(&mut self, events: Events) {
        if let (Some(storage), Some(path)) = (&events.storage, &self.script_storage) {
            self.save_script_storage(path.clone(), storage);
        }
        let mut changes = Changes::default();
        for (id, value) in events.values {
            let Some(spec) = self.scene.scripts.get(id) else { continue };
            let (layer_id, field) = (spec.layer_id, spec.field.clone());
            self.set_field(layer_id, &field, value, &mut changes);
        }
        for (field, value) in events.scene {
            self.set_scene_field(&field, value);
        }
        for (layer_id, fields) in events.dirty {
            for (field, value) in fields {
                self.set_field(layer_id, &field, value, &mut changes);
            }
        }
        if !events.created.is_empty() || !events.moves.is_empty() {
            self.restructure(&events.created, &events.moves);
            changes.rebuild = true;
        }
        if changes.rebuild {
            self.rebuild();
        } else {
            if changes.place {
                self.replace_layers();
            }
            if changes.text {
                self.refresh_texts();
            }
        }
    }

    /// Writes the scripts' `localStorage`: to a temporary file first, so a crash never leaves half
    /// a file behind. Scripts write rarely (a high score, a setting), so this stays off the frame's
    /// hot path in practice.
    fn save_script_storage(&mut self, path: std::path::PathBuf, storage: &Value) {
        let partial = path.with_extension("partial");
        let written = std::fs::write(&partial, storage.to_string()).and_then(|_| std::fs::rename(&partial, &path));
        if let Err(e) = written {
            self.warnings.push(format!("script storage {}: {e}", path.display()));
        }
    }

    /// Applies a scene setting a script wrote. Fields the renderer does not read yet are ignored.
    fn set_scene_field(&mut self, field: &str, value: Value) {
        let fixed = |value: Value| Bound { value, user: None, condition: None };
        match field {
            "bloom" => self.scene.bloom.enabled = fixed(value),
            "bloomstrength" => self.scene.bloom.strength = fixed(value),
            "bloomthreshold" => self.scene.bloom.threshold = fixed(value),
            "clearcolor" => {
                let rgb = floats(&value);
                if rgb.len() == 3 {
                    self.scene.clear_color = fixed(value);
                }
            }
            _ => {}
        }
    }

    fn set_field(&mut self, layer_id: i64, field: &str, value: Value, changes: &mut Changes) {
        if self.sounds.has(layer_id) {
            self.sounds.command(layer_id, field, &value);
            return;
        }
        let Some(index) = self.layer_index(layer_id) else { return };
        // `effect:<n>:visible` comes from an IEffect; the renderer checks it every frame.
        if let Some(rest) = field.strip_prefix("effect:") {
            if let Some((n, "visible")) = rest.split_once(':') {
                if let Ok(n) = n.parse::<usize>() {
                    if let Some(effect) = self.scene.layers[index].effects.get_mut(n) {
                        effect.visible = Bound { value, user: None, condition: None };
                    }
                }
            }
            return;
        }
        if let Some((n, constant)) = effect_field(field) {
            let props = &self.props;
            let Some(effect) = self.scene.layers[index].effects.get_mut(n) else { return };
            match constant {
                None => effect.visible = fixed(value),
                Some((pass, key)) => {
                    let Some(slot) =
                        effect.passes.get_mut(pass).and_then(|p| p.material.constants.get_mut(key))
                    else {
                        return;
                    };
                    // Constants are baked into the draw list, so only a visible change rebuilds;
                    // fade scripts creep towards their target by ever smaller steps.
                    let (old, new) = (floats(&slot.get(props)), floats(&value));
                    let moved = old.len() != new.len()
                        || old.iter().zip(&new).any(|(a, b)| (a - b).abs() > 1e-3);
                    if moved {
                        *slot = fixed(value);
                        changes.rebuild = true;
                    }
                }
            }
            return;
        }
        let props = &self.props;
        let layer = &mut self.scene.layers[index];
        match field {
            "origin" | "scale" | "angles" | "color" | "alpha" => {
                let slot = match field {
                    "origin" => &mut layer.origin,
                    "scale" => &mut layer.scale,
                    "angles" => &mut layer.angles,
                    "color" => &mut layer.color,
                    _ => &mut layer.alpha,
                };
                if slot.get(props) != value {
                    *slot = fixed(value);
                    changes.place = true;
                }
            }
            "visible" => {
                let now = crate::scene::truthy(&value);
                if layer.visible.truthy(props) != now {
                    layer.visible = fixed(Value::Bool(now));
                    changes.rebuild = true;
                }
            }
            "text" => {
                if let Some(t) = layer.text.as_mut() {
                    let s = value.as_str().map_or_else(|| value.to_string(), str::to_string);
                    if t.value != s {
                        t.value = s;
                        changes.text = true;
                    }
                }
            }
            "parallaxDepth" => {
                layer.parallax_depth = fixed(value);
                changes.place = true;
            }
            _ => {
                let Some(key) = field.strip_prefix("instanceoverride.") else { return };
                let Some(p) = layer.particles.as_mut() else { return };
                let o = p.instance_override.get_or_insert_with(|| Value::Object(Map::new()));
                if let Some(map) = o.as_object_mut() {
                    let _ = map.insert(key.to_string(), value.clone());
                }
                let single = json!({ key: value });
                if let (Some(sim), Some(o)) = (
                    self.particles.iter_mut().find(|p| p.layer == index),
                    particles::InstanceOverride::from_json(&single),
                ) {
                    sim.sim.apply_override(&o);
                }
            }
        }
    }

    /// Re-places every layer after scripts moved, scaled, tinted or faded some of them.
    fn replace_layers(&mut self) {
        for i in 0..self.layers.len().min(self.scene.layers.len()) {
            if self.layers[i].placed.is_none() {
                continue;
            }
            let layer = self.scene.layers[i].clone();
            let image = self.layers[i].image.clone();
            let text_rect = self.layers[i].text_rect;
            let placed = self.place(i, &layer, image.as_deref());
            self.layers[i].placed = placed;
            self.layers[i].text_rect = text_rect;
        }
        let worlds: Vec<_> = self.particles.iter().map(|p| self.world(p.layer, 0)).collect();
        for (p, w) in self.particles.iter_mut().zip(worlds) {
            p.world = w;
        }
    }

    /// Adds the layers scripts created and applies their draw-order moves. Particle systems and
    /// puppets are keyed by layer index, so they are re-keyed through the layer ids.
    fn restructure(&mut self, created: &[Created], moves: &[(i64, usize)]) {
        let ids: Vec<i64> = self.scene.layers.iter().map(|l| l.id).collect();
        for c in created {
            let path = self.resolve_asset(&c.path, &c.workshop);
            // A registered asset is a particle system or an image model.
            let kind = if path.starts_with("particles/") { "particle" } else { "image" };
            let obj = json!({
                "id": c.id,
                "name": c.path,
                kind: path,
                "origin": "0 0 0",
                "scale": "1 1 1",
                "visible": true,
            });
            match Scene::layer(&self.vfs, &obj, false, &mut self.warnings) {
                Ok(layer) => self.scene.layers.push(layer),
                Err(e) => self.warnings.push(format!("script layer {}: {e}", c.path)),
            }
        }
        for &(id, to) in moves {
            let Some(from) = self.layer_index(id) else { continue };
            let layer = self.scene.layers.remove(from);
            let to = to.min(self.scene.layers.len());
            self.scene.layers.insert(to, layer);
        }
        let new_index = |old: usize| ids.get(old).and_then(|id| self.scene.layers.iter().position(|l| l.id == *id));
        let remap: Vec<Option<usize>> = (0..ids.len()).map(new_index).collect();
        self.particles.retain_mut(|p| match remap.get(p.layer).copied().flatten() {
            Some(n) => {
                p.layer = n;
                true
            }
            None => false,
        });
        self.puppets.retain_mut(|p| match remap.get(p.layer).copied().flatten() {
            Some(n) => {
                p.layer = n;
                true
            }
            None => false,
        });
        self.sync_script_layers();
    }

    /// Scripts name assets as their author saw them; a workshop script's files were moved under
    /// `<dir>/workshop/<id>/` when the scene was published.
    fn resolve_asset(&self, path: &str, workshop: &str) -> String {
        if self.vfs.read(path).is_some() || workshop.is_empty() {
            return path.to_string();
        }
        let moved = match path.split_once('/') {
            Some((dir, rest)) => format!("{dir}/workshop/{workshop}/{rest}"),
            None => format!("workshop/{workshop}/{path}"),
        };
        if self.vfs.read(&moved).is_some() {
            moved
        } else {
            path.to_string()
        }
    }

    /// Pushes the layer values to the scripts again, after a user property change.
    pub fn sync_script_layers(&mut self) {
        let layers = self.script_layers();
        if let Some(host) = self.script_host.as_mut() {
            let _ = host.set_layers(&layers);
        }
    }
}

/// A scene vector value as the "x y z" text scripts parse.
/// Splits `effects[n].visible` into `(n, None)` and
/// `effects[n].passes[m].constantshadervalues.<key>` into `(n, Some((m, key)))`.
fn effect_field(field: &str) -> Option<(usize, Option<(usize, &str)>)> {
    let (n, rest) = field.strip_prefix("effects[")?.split_once("].")?;
    let n = n.parse().ok()?;
    if rest == "visible" {
        return Some((n, None));
    }
    let (m, key) = rest.strip_prefix("passes[")?.split_once("].constantshadervalues.")?;
    Some((n, Some((m.parse().ok()?, key))))
}

fn text3(v: &Value) -> String {
    let f = floats(v);
    match f.len() {
        0 => "0 0 0".into(),
        1 => format!("{0} {0} {0}", f[0]),
        2 => format!("{} {} 0", f[0], f[1]),
        _ => format!("{} {} {}", f[0], f[1], f[2]),
    }
}

#[cfg(test)]
mod tests {
    use super::effect_field;

    #[test]
    fn effect_script_paths_are_split() {
        assert_eq!(effect_field("effects[0].visible"), Some((0, None)));
        assert_eq!(
            effect_field("effects[1].passes[0].constantshadervalues.alpha"),
            Some((1, Some((0, "alpha"))))
        );
        assert_eq!(effect_field("effects[1].passes[0].combos.X"), None);
        assert_eq!(effect_field("origin"), None);
    }
}
