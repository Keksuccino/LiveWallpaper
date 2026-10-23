//! Sound objects: music and ambience files a scene plays while it is on screen. AVFoundation
//! decodes them (mp3, wav, m4a); there is no decoder of our own.

use objc2::rc::{Allocated, Retained};
use objc2::runtime::{AnyClass, AnyObject, Bool};
use objc2::msg_send;
use objc2_foundation::NSData;
use serde_json::Value;

use crate::scene::floats;
use crate::vfs::Vfs;

#[link(name = "AVFoundation", kind = "framework")]
extern "C" {}

/// One sound object of the scene.
#[derive(Debug, Clone)]
pub struct SoundSpec {
    pub files: Vec<String>,
    pub volume: f32,
    /// "loop", "random" or "single".
    pub mode: String,
}

impl SoundSpec {
    pub fn parse(obj: &Value) -> Option<Self> {
        let files: Vec<String> = obj["sound"]
            .as_array()?
            .iter()
            .filter_map(|f| f.as_str().map(str::to_string))
            .collect();
        if files.is_empty() || obj["startsilent"].as_bool() == Some(true) {
            return None;
        }
        let volume = match &obj["volume"] {
            Value::Object(m) => m.get("value").map(floats),
            v => Some(floats(v)),
        }
        .and_then(|f| f.first().copied())
        .unwrap_or(1.0);
        Some(Self {
            files,
            volume: volume.clamp(0.0, 1.0),
            mode: obj["playbackmode"].as_str().unwrap_or("loop").to_string(),
        })
    }
}

/// The scene's players. Created muted and paused; the render loop drives them.
pub struct Sounds {
    players: Vec<(Retained<AnyObject>, f32)>,
    playing: bool,
}

impl std::fmt::Debug for Sounds {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Sounds({})", self.players.len())
    }
}

impl Sounds {
    pub fn load(vfs: &Vfs, specs: &[SoundSpec], warnings: &mut Vec<String>) -> Self {
        let mut players = Vec::new();
        let Some(class) = AnyClass::get(c"AVAudioPlayer") else {
            if !specs.is_empty() {
                warnings.push("AVFoundation unavailable; sounds off".into());
            }
            return Self { players, playing: false };
        };
        for spec in specs {
            // shortcut: random playlists and timed gaps (`mintime`/`maxtime`) play the first file
            // on a loop; upgrade when a scene with several files needs it.
            let file = &spec.files[0];
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
            let Some(player) = player else {
                warnings.push(format!("sound {file}: format not supported"));
                continue;
            };
            let loops: isize = if spec.mode == "single" { 0 } else { -1 };
            // SAFETY: plain property setters on a live player.
            unsafe {
                let _: () = msg_send![&*player, setNumberOfLoops: loops];
                let _: Bool = msg_send![&*player, prepareToPlay];
            }
            players.push((player, spec.volume));
        }
        Self { players, playing: false }
    }

    pub fn is_empty(&self) -> bool {
        self.players.is_empty()
    }

    /// Starts or pauses every player; `volume` is the user's level times each object's own.
    pub fn set(&mut self, play: bool, volume: f32) {
        for (player, own) in &self.players {
            // SAFETY: plain messages to a live player.
            unsafe {
                let _: () = msg_send![&**player, setVolume: own * volume];
                if play && !self.playing {
                    let _: Bool = msg_send![&**player, play];
                } else if !play && self.playing {
                    let _: () = msg_send![&**player, pause];
                }
            }
        }
        self.playing = play;
    }
}

impl Drop for Sounds {
    fn drop(&mut self) {
        for (player, _) in &self.players {
            // SAFETY: plain message to a live player.
            unsafe {
                let _: () = msg_send![&**player, stop];
            }
        }
    }
}
