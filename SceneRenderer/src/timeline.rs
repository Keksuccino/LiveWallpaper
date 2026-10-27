//! Keyframed scene values: `{"animation": {"c0": [...], "options": {...}}, "value": ...}`.
//!
//! Each channel (`c0`, `c1`, ...) animates one component of the value. A keyframe stores its
//! frame, its value, a `back` and a `front` handle (`x`, `y`, each with `enabled`) and an optional
//! `step` flag, which holds the previous keyframe's value up to this one; the options give the
//! frame rate, the length in frames and the play mode. These are the fields Wallpaper Engine
//! reads; the editor's `magic`, `lockangle` and `locklength` only shape the handles it writes.
//!
//! Between two keyframes the value follows the cubic Bézier through `(frame, value)`,
//! `(frame + front.x * span / 2, value + front.y)`, `(next + back.x * span / 2, next value +
//! back.y)` and the next keyframe, in frame and value space; the curve parameter for a frame is
//! found by halving steps until the curve's frame is within 0.01 of it. This is Wallpaper
//! Engine's own evaluation (see `NOTES.md`), constants included.

use std::cell::Cell;

use serde_json::Value;

/// How the frames play after the last one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Loop,
    /// Forward, then backward, and again.
    Mirror,
    /// Once, then the last frame holds.
    Single,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Keyframe {
    pub frame: f32,
    pub value: f32,
    /// Handle towards the previous keyframe, `(x, y)`.
    pub back: Option<[f32; 2]>,
    /// Handle towards the next keyframe.
    pub front: Option<[f32; 2]>,
    /// The value holds until the next keyframe.
    pub step: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Timeline {
    /// One curve per component, keyframes in frame order.
    pub channels: Vec<Vec<Keyframe>>,
    pub fps: f32,
    /// Frames before the animation ends or repeats.
    pub length: f32,
    pub mode: Mode,
    /// The curves are offsets from the stored value instead of the value itself.
    pub relative: bool,
    /// The name scripts find it by (`getAnimation`).
    pub name: String,
    /// Plays from the scene's start unless the file says it waits for a script (`startpaused`).
    playback: Cell<Playback>,
}

/// Where a timeline's playback stands: playing since scene time `since` from frame `from`, or
/// held at `from`.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Playback {
    playing: bool,
    since: f32,
    from: f32,
    rate: f32,
}

impl Timeline {
    /// The timeline of a `{"animation": {...}}` object, if it has a usable one.
    pub fn parse(animation: &Value) -> Option<Self> {
        let options = animation.get("options")?;
        let mut channels = Vec::new();
        while let Some(keys) = animation
            .get(format!("c{}", channels.len()))
            .and_then(Value::as_array)
        {
            let mut keys: Vec<Keyframe> = keys.iter().filter_map(keyframe).collect();
            keys.sort_by(|a, b| a.frame.total_cmp(&b.frame));
            channels.push(keys);
        }
        if channels.iter().all(Vec::is_empty) {
            return None;
        }
        let num = |key: &str, default: f64| {
            options.get(key).and_then(Value::as_f64).unwrap_or(default) as f32
        };
        Some(Self {
            channels,
            fps: num("fps", 30.0).max(1.0),
            length: num("length", 0.0).max(0.0),
            mode: match options.get("mode").and_then(Value::as_str) {
                Some("single") => Mode::Single,
                Some("mirror") => Mode::Mirror,
                _ => Mode::Loop,
            },
            relative: animation.get("relative").and_then(Value::as_bool) == Some(true),
            playback: Cell::new(Playback {
                playing: options.get("startpaused").and_then(Value::as_bool) != Some(true),
                since: 0.0,
                from: 0.0,
                rate: 1.0,
            }),
            name: options
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        })
    }

    /// The frame shown `time` seconds into the scene.
    pub fn frame_at(&self, time: f32) -> f32 {
        self.wrap(self.unwrapped(time))
    }

    /// Frames played by `time`, before the play mode folds them into the animation's length.
    fn unwrapped(&self, time: f32) -> f32 {
        let p = self.playback.get();
        if p.playing {
            p.from + (time - p.since).max(0.0) * self.fps * p.rate
        } else {
            p.from
        }
    }

    fn wrap(&self, frame: f32) -> f32 {
        if self.length <= 0.0 {
            return 0.0;
        }
        match self.mode {
            Mode::Single => frame.clamp(0.0, self.length),
            Mode::Loop => frame.rem_euclid(self.length),
            Mode::Mirror => {
                let f = frame.rem_euclid(2.0 * self.length);
                if f > self.length {
                    2.0 * self.length - f
                } else {
                    f
                }
            }
        }
    }

    /// No longer changes after `time`: it is held, or a single run has ended.
    pub fn settled(&self, time: f32) -> bool {
        !self.playback.get().playing || self.finished(time)
    }

    fn finished(&self, time: f32) -> bool {
        self.mode == Mode::Single && self.unwrapped(time) >= self.length
    }

    /// Whether it plays at `time` (a single run that has ended does not).
    pub fn playing(&self, time: f32) -> bool {
        !self.settled(time)
    }

    /// The speed factor scripts may change.
    pub fn rate(&self) -> f32 {
        self.playback.get().rate
    }

    /// Applies a script's command at scene time `time`: `play` continues (a single run that has
    /// ended starts over), `pause` holds the current frame, `stop` goes back to the first frame,
    /// `frame:<n>` jumps to a frame and `rate:<r>` changes the speed.
    pub fn command(&self, command: &str, time: f32) {
        let mut p = self.playback.get();
        let now = self.frame_at(time);
        match command {
            "play" => {
                if !p.playing || self.finished(time) {
                    p.from = if self.finished(time) { 0.0 } else { now };
                    p.since = time;
                    p.playing = true;
                }
            }
            "pause" => {
                p.from = now;
                p.playing = false;
            }
            "stop" => {
                p.from = 0.0;
                p.playing = false;
            }
            _ => {
                if let Some(frame) = command.strip_prefix("frame:").and_then(|f| f.parse().ok()) {
                    p.from = frame;
                    p.since = time;
                } else if let Some(rate) = command.strip_prefix("rate:").and_then(|r| r.parse().ok()) {
                    p.from = now;
                    p.since = time;
                    p.rate = rate;
                }
            }
        }
        self.playback.set(p);
    }

    /// The animated value at `time` from the stored one (`base`, one or more numbers).
    pub fn apply(&self, base: &[f32], time: f32) -> Vec<f32> {
        let frame = self.frame_at(time);
        let n = base.len().max(self.channels.len());
        (0..n)
            .map(|i| {
                let stored = base.get(i).copied().unwrap_or(0.0);
                match self.channels.get(i).and_then(|keys| sample(keys, frame)) {
                    Some(v) if self.relative => stored + v,
                    Some(v) => v,
                    None => stored,
                }
            })
            .collect()
    }
}

fn keyframe(k: &Value) -> Option<Keyframe> {
    let handle = |side: &str| -> Option<[f32; 2]> {
        let h = k.get(side)?;
        if h.get("enabled").and_then(Value::as_bool) == Some(false) {
            return None;
        }
        let num = |key: &str| h.get(key).and_then(Value::as_f64).unwrap_or(0.0) as f32;
        Some([num("x"), num("y")])
    };
    Some(Keyframe {
        frame: k.get("frame")?.as_f64()? as f32,
        value: k.get("value")?.as_f64()? as f32,
        back: handle("back"),
        front: handle("front"),
        step: k.get("step").and_then(Value::as_bool) == Some(true),
    })
}

/// The curve's value at `frame`; before the first keyframe the first holds, after the last the
/// last. `None` for a channel without keyframes.
fn sample(keys: &[Keyframe], frame: f32) -> Option<f32> {
    let first = keys.first()?;
    let last = keys.last()?;
    if frame <= first.frame {
        return Some(first.value);
    }
    if frame >= last.frame {
        return Some(last.value);
    }
    let i = keys.windows(2).position(|w| frame < w[1].frame)?;
    let (a, b) = (&keys[i], &keys[i + 1]);
    let span = b.frame - a.frame;
    if b.step || span <= 0.0 {
        return Some(a.value);
    }
    // Control points in (frame, value); a disabled handle sits on its keyframe.
    let half = span * 0.5;
    let [ax, ay] = a.front.map_or([0.0, 0.0], |[x, y]| [x * half, y]);
    let [bx, by] = b.back.map_or([0.0, 0.0], |[x, y]| [x * half, y]);
    let xs = [a.frame, a.frame + ax, b.frame + bx, b.frame];
    let ys = [a.value, a.value + ay, b.value + by, b.value];
    Some(bezier(ys, solve_t(xs, frame)))
}

fn bezier([p0, p1, p2, p3]: [f32; 4], t: f32) -> f32 {
    let u = 1.0 - t;
    u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3
}

/// The curve parameter whose frame is `x`: from 0, steps that halve each time (the first is
/// 0.999 / 2) move forward while the curve's frame is at or before `x` and back otherwise, until
/// it is within 0.01 frames.
fn solve_t(xs: [f32; 4], x: f32) -> f32 {
    let (mut t, mut step) = (0.0f32, 0.999f32);
    for _ in 0..1000 {
        let at = bezier(xs, t);
        if (at - x).abs() < 0.01 {
            break;
        }
        step *= 0.5;
        if at <= x {
            t += step;
        } else {
            t -= step;
        }
    }
    t.clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fade() -> Timeline {
        // The dimming layer of one scene: 0 -> 0.5 at frame 60 -> 0 at frame 100, played once.
        Timeline::parse(&json!({
            "c0": [
                {"frame": 0, "value": 0, "front": {"enabled": true, "x": 1, "y": 0}},
                {"frame": 60, "value": 0.5, "back": {"enabled": true, "x": -0.8, "y": 0}, "front": {"enabled": true, "x": 1, "y": 0}},
                {"frame": 100, "value": 0, "back": {"enabled": true, "x": -1, "y": 0}}
            ],
            "options": {"fps": 30, "length": 180, "mode": "single"}
        }))
        .unwrap()
    }

    #[test]
    fn keyframes_are_hit_and_the_last_one_holds() {
        let t = fade();
        assert!(t.apply(&[0.3], 0.0)[0].abs() < 1e-4);
        assert!((t.apply(&[0.3], 2.0)[0] - 0.5).abs() < 1e-4);
        assert!(t.apply(&[0.3], 10.0)[0].abs() < 1e-4);
        assert!(t.settled(10.0) && !t.settled(1.0));
    }

    #[test]
    fn flat_handles_ease_in_and_out() {
        let t = fade();
        let early = t.apply(&[0.0], 0.2)[0];
        let middle = t.apply(&[0.0], 1.0)[0];
        assert!(early > 0.0 && early < 0.25 * 0.5, "{early}");
        assert!((middle - 0.25).abs() < 0.05, "{middle}");
    }

    #[test]
    fn relative_channels_add_to_the_stored_value() {
        let t = Timeline::parse(&json!({
            "c0": [{"frame": 0, "value": 10}], "c1": [{"frame": 0, "value": -5}],
            "options": {"fps": 30, "length": 30, "mode": "loop"}, "relative": true
        }))
        .unwrap();
        assert_eq!(t.apply(&[100.0, 200.0, 0.0], 0.5), vec![110.0, 195.0, 0.0]);
    }

    #[test]
    fn mirror_plays_back_and_paused_holds_the_first_frame() {
        let mut t = fade();
        t.mode = Mode::Mirror;
        assert!((t.frame_at(7.0) - 150.0).abs() < 1e-3);
        t.command("stop", 7.0);
        assert_eq!(t.frame_at(9.0), 0.0);
    }

    #[test]
    fn scripts_play_pause_and_restart_a_single_run() {
        let t = Timeline::parse(&json!({
            "c0": [{"frame": 0, "value": 0}, {"frame": 30, "value": 1}],
            "options": {"fps": 30, "length": 30, "mode": "single", "startpaused": true}
        }))
        .unwrap();
        assert!(t.settled(5.0) && t.frame_at(5.0) == 0.0);
        t.command("play", 5.0);
        assert!((t.frame_at(5.5) - 15.0).abs() < 1e-3 && t.playing(5.5));
        t.command("pause", 5.5);
        assert!((t.frame_at(9.0) - 15.0).abs() < 1e-3);
        t.command("play", 9.0);
        assert!(t.settled(20.0) && t.frame_at(20.0) == 30.0);
        // Played to its end, it starts over.
        t.command("play", 20.0);
        assert!((t.frame_at(20.5) - 15.0).abs() < 1e-3);
        t.command("stop", 20.5);
        assert_eq!(t.frame_at(30.0), 0.0);
    }
}
