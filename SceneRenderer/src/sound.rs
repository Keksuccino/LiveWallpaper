//! Sound objects: music and ambience files a scene plays while it is on screen. AVFoundation
//! decodes them (mp3, wav, m4a, ...); there is no decoder of our own.
//!
//! Wallpaper Engine's three playback modes: `loop` plays the object's files one after another
//! without end (background music), `random` plays one file now and then with a pause of
//! `mintime`...`maxtime` seconds in between (ambience), `single` plays its file once each time it
//! is started. `startsilent` objects wait for a script to start them (`thisScene.getLayer(name)
//! .play()`); scripts can also pause, stop and change the volume of any sound object.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use objc2::msg_send;
use objc2::rc::{Allocated, Retained};
use objc2::runtime::{AnyClass, AnyObject, Bool};
use objc2_foundation::NSData;
use serde_json::Value;

use crate::scene::{floats, Bound};
use crate::vfs::Vfs;

#[link(name = "AVFoundation", kind = "framework")]
extern "C" {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Loop,
    Random,
    Single,
}

/// One sound object of the scene.
#[derive(Debug, Clone)]
pub struct SoundSpec {
    pub id: i64,
    pub name: String,
    pub files: Vec<String>,
    /// The object's own level, 0...1; may follow a user property.
    pub volume: Bound,
    pub mode: Mode,
    /// `queuemode` "random": the next file is picked at random instead of in order.
    pub shuffle: bool,
    /// Pause before each play in `random` mode, in seconds.
    pub min_time: f32,
    pub max_time: f32,
    /// Waits for a script to start it.
    pub start_silent: bool,
}

impl SoundSpec {
    pub fn parse(obj: &Value) -> Option<Self> {
        let files: Vec<String> = obj["sound"]
            .as_array()?
            .iter()
            .filter_map(|f| f.as_str().map(str::to_string))
            .collect();
        if files.is_empty() {
            return None;
        }
        let num = |key: &str, d: f32| obj[key].as_f64().map_or(d, |v| v as f32);
        let (min_time, max_time) = (num("mintime", 0.0).max(0.0), num("maxtime", 0.0).max(0.0));
        Some(Self {
            id: obj["id"].as_i64().unwrap_or(-1),
            name: obj["name"].as_str().unwrap_or("").to_string(),
            files,
            volume: Bound::parse(obj.get("volume"), Value::from(1.0)),
            mode: match obj["playbackmode"].as_str() {
                Some("random") => Mode::Random,
                Some("single") => Mode::Single,
                _ => Mode::Loop,
            },
            shuffle: obj["queuemode"].as_str() == Some("random"),
            min_time: min_time.min(max_time),
            max_time,
            start_silent: obj["startsilent"].as_bool() == Some(true),
        })
    }
}

/// What a sound object is doing.
#[derive(Debug, Clone, Copy, PartialEq)]
enum State {
    /// Not started, finished, or stopped.
    Idle,
    /// A file is playing (or paused while the scene cannot be heard).
    Playing,
    /// `random` mode between two plays: the next one starts at this time.
    Waiting(Instant),
    /// Paused by a script; `play` resumes where it stopped.
    Paused,
}

/// A sound object's players (one per file) and where it is.
struct Track {
    spec: SoundSpec,
    players: Vec<Retained<AnyObject>>,
    current: usize,
    state: State,
    /// Level a script set; `None` follows the scene file (or its user property).
    script_volume: Option<f32>,
    own_volume: f32,
}

/// The scene's sound objects. Created silent; the render loop drives them.
pub struct Sounds {
    tracks: Vec<Track>,
    /// The scene plays, is on screen and is not muted.
    audible: bool,
    /// The user's level (wallpaper volume times the master volume).
    volume: f32,
    rng: u64,
}

impl std::fmt::Debug for Sounds {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Sounds({})", self.tracks.len())
    }
}

impl Sounds {
    pub fn load(
        vfs: &Vfs,
        specs: &[SoundSpec],
        props: &HashMap<String, Value>,
        warnings: &mut Vec<String>,
    ) -> Self {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(1, |d| d.as_nanos() as u64)
            | 1;
        let mut sounds = Self { tracks: Vec::new(), audible: false, volume: 1.0, rng: seed };
        let Some(class) = AnyClass::get(c"AVAudioPlayer") else {
            if !specs.is_empty() {
                warnings.push("AVFoundation unavailable; sounds off".into());
            }
            return sounds;
        };
        for spec in specs {
            let mut players = Vec::new();
            for file in &spec.files {
                let Some(bytes) = vfs.read(file) else {
                    warnings.push(format!("sound {file}: missing"));
                    continue;
                };
                let data = NSData::with_bytes(&bytes);
                // SAFETY: AVAudioPlayer's documented initialiser; a null error pointer is allowed.
                let player: Option<Retained<AnyObject>> = unsafe {
                    let alloc: Allocated<AnyObject> = msg_send![class, alloc];
                    msg_send![alloc, initWithData: &*data, error: std::ptr::null_mut::<*mut AnyObject>()]
                };
                match player {
                    // SAFETY: plain message to a live player.
                    Some(p) => {
                        let _: Bool = unsafe { msg_send![&*p, prepareToPlay] };
                        players.push(p);
                    }
                    None => warnings.push(format!("sound {file}: format not supported")),
                }
            }
            if players.is_empty() {
                continue;
            }
            // One file on a loop repeats inside the player; everything else moves on in `tick`.
            if spec.mode == Mode::Loop && players.len() == 1 {
                // SAFETY: plain property setter on a live player.
                unsafe { let _: () = msg_send![&*players[0], setNumberOfLoops: -1isize]; }
            }
            let state = if spec.start_silent { State::Idle } else { State::Playing };
            let mut track = Track {
                spec: spec.clone(),
                players,
                current: 0,
                state,
                script_volume: None,
                own_volume: 1.0,
            };
            track.own_volume = track.level(props);
            // `random` ambience starts with a pause, like between two of its plays.
            if track.spec.mode == Mode::Random && state == State::Playing {
                let pause = sounds.pause(track.spec.min_time, track.spec.max_time);
                track.state = State::Waiting(Instant::now() + pause);
            }
            if track.spec.shuffle {
                track.current = sounds.pick(track.players.len());
            }
            sounds.tracks.push(track);
        }
        sounds
    }

    pub fn is_empty(&self) -> bool {
        self.tracks.is_empty()
    }

    /// Whether a sound object has this id (scripts address sound objects like layers).
    pub fn has(&self, id: i64) -> bool {
        self.tracks.iter().any(|t| t.spec.id == id)
    }

    /// The sound objects as scripts see them: id, name, level and whether it is playing.
    pub fn script_view(&self) -> Vec<(i64, &str, f32, bool)> {
        self.tracks
            .iter()
            .map(|t| (t.spec.id, t.spec.name.as_str(), t.own_volume, t.state == State::Playing))
            .collect()
    }

    /// Ids of the sound objects that are playing.
    pub fn playing(&self) -> Vec<i64> {
        self.tracks.iter().filter(|t| t.state == State::Playing).map(|t| t.spec.id).collect()
    }

    /// Starts or pauses everything that should play; `volume` is the user's level, which each
    /// object's own level multiplies.
    pub fn set(&mut self, audible: bool, volume: f32) {
        let was = self.audible;
        self.audible = audible;
        self.volume = volume;
        for track in &self.tracks {
            track.apply_volume(volume);
            if track.state == State::Playing && audible != was {
                track.run(audible);
            }
        }
    }

    /// User properties changed: levels that follow one are read again.
    pub fn apply_props(&mut self, props: &HashMap<String, Value>) {
        for track in &mut self.tracks {
            track.own_volume = track.level(props);
            track.apply_volume(self.volume);
        }
    }

    /// A script's `play`, `pause` or `stop` on the sound object `id`, or its new `volume`.
    pub fn command(&mut self, id: i64, field: &str, value: &Value) {
        let Some(i) = self.tracks.iter().position(|t| t.spec.id == id) else { return };
        match (field, value.as_str()) {
            ("sound", Some("play")) => {
                let track = &mut self.tracks[i];
                if track.state != State::Paused {
                    // A new start plays from the beginning (a click sound plays on every click).
                    track.rewind();
                }
                track.state = State::Playing;
                if self.audible {
                    track.run(true);
                }
            }
            ("sound", Some("pause")) if self.tracks[i].state == State::Playing => {
                self.tracks[i].run(false);
                self.tracks[i].state = State::Paused;
            }
            ("sound", Some("stop")) => {
                let track = &mut self.tracks[i];
                track.run(false);
                track.rewind();
                track.state = State::Idle;
            }
            ("volume", _) => {
                let track = &mut self.tracks[i];
                let level = floats(value).first().copied().unwrap_or(1.0).clamp(0.0, 1.0);
                track.script_volume = Some(level);
                track.own_volume = level;
                track.apply_volume(self.volume);
            }
            _ => {}
        }
    }

    /// Moves on what finished: the next file of a loop, the pause of `random` ambience, the end
    /// of a single play. Call it at `next_wake` (it does nothing while the scene cannot be heard).
    pub fn tick(&mut self) {
        if !self.audible {
            return;
        }
        let now = Instant::now();
        for i in 0..self.tracks.len() {
            match self.tracks[i].state {
                State::Waiting(at) if at <= now => {
                    let n = self.tracks[i].players.len();
                    let next = if n > 1 { self.pick(n) } else { 0 };
                    let track = &mut self.tracks[i];
                    track.current = next;
                    track.rewind();
                    track.state = State::Playing;
                    track.run(true);
                }
                State::Playing if !self.tracks[i].is_running() && !self.tracks[i].loops_itself() => {
                    let t = &self.tracks[i];
                    let (spec, n, current) = (&t.spec, t.players.len(), t.current);
                    let (mode, shuffle, lo, hi) = (spec.mode, spec.shuffle, spec.min_time, spec.max_time);
                    match mode {
                        Mode::Loop => {
                            let next = if shuffle && n > 1 { self.pick(n) } else { (current + 1) % n };
                            let track = &mut self.tracks[i];
                            track.current = next;
                            track.rewind();
                            track.run(true);
                        }
                        Mode::Random => {
                            let pause = self.pause(lo, hi);
                            self.tracks[i].state = State::Waiting(now + pause);
                        }
                        Mode::Single => self.tracks[i].state = State::Idle,
                    }
                }
                _ => {}
            }
        }
    }

    /// When `tick` has something to do next: a pause that ends, or a file that ends. `None` when
    /// nothing is due (silent, idle, or one file on a loop).
    pub fn next_wake(&self) -> Option<Instant> {
        if !self.audible {
            return None;
        }
        let now = Instant::now();
        self.tracks
            .iter()
            .filter_map(|t| match t.state {
                State::Waiting(at) => Some(at),
                State::Playing if !t.loops_itself() => {
                    // Slightly after the end, so the player has stopped by then.
                    let left = (t.duration() - t.position()).max(0.0) + 0.02;
                    Some(now + Duration::from_secs_f64(left))
                }
                _ => None,
            })
            .min()
    }

    /// A pause of `min`...`max` seconds before the next play of `random` ambience.
    fn pause(&mut self, min: f32, max: f32) -> Duration {
        Duration::from_secs_f32((min + (max - min) * self.unit()).max(0.0))
    }

    /// A random file index below `n`.
    fn pick(&mut self, n: usize) -> usize {
        ((self.unit() * n as f32) as usize).min(n.saturating_sub(1))
    }

    /// A random number in 0..1 (xorshift; nothing here needs more).
    fn unit(&mut self) -> f32 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        (self.rng >> 40) as f32 / (1u64 << 24) as f32
    }
}

impl Track {
    fn player(&self) -> &AnyObject {
        &self.players[self.current]
    }

    /// The object's own level from the scene file (or the user property it follows).
    fn level(&self, props: &HashMap<String, Value>) -> f32 {
        self.script_volume.unwrap_or_else(|| {
            floats(&self.spec.volume.get(props)).first().copied().unwrap_or(1.0).clamp(0.0, 1.0)
        })
    }

    fn loops_itself(&self) -> bool {
        self.spec.mode == Mode::Loop && self.players.len() == 1
    }

    fn apply_volume(&self, volume: f32) {
        for player in &self.players {
            // SAFETY: plain property setter on a live player.
            unsafe { let _: () = msg_send![&**player, setVolume: self.own_volume * volume]; }
        }
    }

    /// Plays or pauses the current file where it is.
    fn run(&self, play: bool) {
        // SAFETY: plain messages to a live player.
        unsafe {
            if play {
                let _: Bool = msg_send![self.player(), play];
            } else {
                let _: () = msg_send![self.player(), pause];
            }
        }
    }

    /// Back to the start of the current file.
    fn rewind(&self) {
        for player in &self.players {
            // SAFETY: plain messages to a live player.
            unsafe {
                let _: () = msg_send![&**player, stop];
                let _: () = msg_send![&**player, setCurrentTime: 0.0f64];
            }
        }
    }

    fn is_running(&self) -> bool {
        // SAFETY: plain property getter on a live player.
        let playing: Bool = unsafe { msg_send![self.player(), isPlaying] };
        playing.as_bool()
    }

    fn duration(&self) -> f64 {
        // SAFETY: plain property getter on a live player.
        unsafe { msg_send![self.player(), duration] }
    }

    fn position(&self) -> f64 {
        // SAFETY: plain property getter on a live player.
        unsafe { msg_send![self.player(), currentTime] }
    }
}

impl Drop for Sounds {
    fn drop(&mut self) {
        for player in self.tracks.iter().flat_map(|t| &t.players) {
            // SAFETY: plain message to a live player.
            unsafe {
                let _: () = msg_send![&**player, stop];
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn sound_objects_keep_their_modes_and_bindings() {
        let ambience = SoundSpec::parse(&json!({
            "id": 7, "name": "birds", "sound": ["a.mp3", "b.mp3"], "playbackmode": "random",
            "mintime": 4.0, "maxtime": 2.0, "queuemode": "random",
            "volume": {"user": "level", "value": 0.5},
        }))
        .expect("parses");
        assert_eq!(ambience.mode, Mode::Random);
        assert!(ambience.shuffle && !ambience.start_silent);
        // A minimum above the maximum is taken as the maximum.
        assert_eq!((ambience.min_time, ambience.max_time), (2.0, 2.0));
        let props: HashMap<String, Value> = [("level".to_string(), json!(0.25))].into();
        assert_eq!(floats(&ambience.volume.get(&props)), vec![0.25]);
        let click = SoundSpec::parse(&json!({
            "id": 8, "sound": ["c.wav"], "playbackmode": "single", "startsilent": true,
        }))
        .expect("parses");
        assert_eq!((click.mode, click.start_silent), (Mode::Single, true));
        assert!(SoundSpec::parse(&json!({"sound": []})).is_none());
    }
}
