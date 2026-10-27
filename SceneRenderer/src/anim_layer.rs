//! A puppet's animation layer as it plays: Wallpaper Engine's playback state for the layers a
//! scene lists and those scripts create (see `NOTES.md`, "Animation layers").
//!
//! Each frame a visible layer that is neither paused nor finished moves on by the elapsed time
//! times its rate: a loop wraps around, a mirrored animation turns at either end and runs back,
//! a single one stops at its end and is finished. Each of those is an "ended" event. The weight
//! fades in over `blendtime` (at most half the animation) from the start while `blendin` is set,
//! which clears itself once the fade is done unless the animation is single, and out towards the
//! end while `blendout` is set.

/// How an animation plays, from its mode string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Loop,
    Mirror,
    Single,
}

impl Mode {
    pub fn of(flag: &str) -> Self {
        match flag {
            "mirror" => Self::Mirror,
            "single" => Self::Single,
            _ => Self::Loop,
        }
    }
}

/// One animation layer of a puppet.
#[derive(Debug, Clone, PartialEq)]
pub struct AnimLayer {
    /// Names the layer for scripts while layers come and go.
    pub uid: u32,
    /// The scene's animation layer it comes from; scripts create the others.
    pub from_scene: Option<usize>,
    /// Index into the model's animations; `None` when the model has none with the layer's id.
    pub animation: Option<usize>,
    pub name: String,
    pub rate: f32,
    pub blend: f32,
    pub additive: bool,
    pub visible: bool,
    pub blend_in: bool,
    pub blend_out: bool,
    pub blend_time: f32,
    /// Seconds into the animation.
    pub time: f32,
    /// A mirrored animation running back.
    reverse: bool,
    pub paused: bool,
    /// A single animation that reached its end.
    pub finished: bool,
    /// Removed at its first ended event (`playSingleAnimation`).
    pub once: bool,
    /// `setFrame` this frame: the next step reports no ended event.
    held: bool,
}

impl AnimLayer {
    /// A layer of animation `animation` with Wallpaper Engine's defaults: rate and blend 1,
    /// visible, a blend time of half a second.
    pub fn new(uid: u32, animation: Option<usize>) -> Self {
        Self {
            uid,
            from_scene: None,
            animation,
            name: String::new(),
            rate: 1.0,
            blend: 1.0,
            additive: false,
            visible: true,
            blend_in: false,
            blend_out: false,
            blend_time: 0.5,
            time: 0.0,
            reverse: false,
            paused: false,
            finished: false,
            once: false,
            held: false,
        }
    }

    /// Plays on by `dt` seconds of an animation `duration` seconds long; returns whether it
    /// ended (wrapped, turned or finished).
    pub fn advance(&mut self, dt: f32, duration: f32, mode: Mode) -> bool {
        if !self.visible || self.paused || self.finished || duration <= 0.0 {
            return false;
        }
        let held = std::mem::take(&mut self.held);
        let direction = if self.reverse { -1.0 } else { 1.0 };
        self.time += dt * self.rate * direction;
        let ended = match mode {
            Mode::Loop if self.time >= duration || self.time < 0.0 => {
                self.time = self.time.rem_euclid(duration);
                true
            }
            Mode::Mirror if self.time > duration => {
                self.time = (2.0 * duration - self.time).max(0.0);
                self.reverse = !self.reverse;
                true
            }
            Mode::Mirror if self.time < 0.0 => {
                self.time = (-self.time).min(duration);
                self.reverse = !self.reverse;
                true
            }
            Mode::Single if self.time >= duration => {
                self.time = duration;
                self.finished = true;
                true
            }
            Mode::Single if self.time < 0.0 => {
                self.time = 0.0;
                false
            }
            _ => false,
        };
        if mode != Mode::Single && self.blend_in && self.time >= self.ramp(duration) {
            self.blend_in = false;
        }
        ended && !held
    }

    fn ramp(&self, duration: f32) -> f32 {
        (duration * 0.5).min(self.blend_time)
    }

    /// The layer's weight with its fades applied.
    pub fn weight(&self, duration: f32) -> f32 {
        let ramp = self.ramp(duration);
        let mut weight = self.blend;
        if duration.min(self.blend_time) > f32::EPSILON {
            if self.blend_in {
                weight *= (self.time / ramp).min(1.0);
            }
            if self.blend_out {
                weight *= ((duration - self.time) / ramp).min(1.0);
            }
        }
        weight
    }

    /// Plays on; a finished layer starts over.
    pub fn play(&mut self) {
        if self.finished {
            self.time = 0.0;
        }
        self.paused = false;
        self.finished = false;
    }

    pub fn pause(&mut self) {
        self.paused = true;
    }

    /// Pauses at the start.
    pub fn stop(&mut self) {
        self.paused = true;
        self.time = 0.0;
        self.finished = false;
        self.reverse = false;
    }

    /// Jumps to frame `frame` of an animation of `fps`.
    pub fn set_frame(&mut self, frame: f32, fps: f32) {
        self.time = if fps > 0.0 { frame / fps } else { 0.0 };
        self.held = true;
    }

    pub fn playing(&self) -> bool {
        !self.paused && !self.finished
    }

    /// Starts over from the beginning, playing.
    pub fn restart(&mut self) {
        self.time = 0.0;
        self.reverse = false;
        self.paused = false;
        self.finished = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(mode: Mode, seconds: f32) -> (AnimLayer, usize) {
        let mut a = AnimLayer::new(0, Some(0));
        let mut ended = 0;
        let steps = (seconds / 0.1).round() as usize;
        for _ in 0..steps {
            ended += usize::from(a.advance(0.1, 2.0, mode));
        }
        (a, ended)
    }

    #[test]
    fn modes_wrap_turn_and_finish() {
        let (a, ended) = run(Mode::Loop, 2.5);
        assert!((a.time - 0.5).abs() < 1e-3 && ended == 1, "{a:?}");
        // A mirrored animation plays back instead of jumping.
        let (a, ended) = run(Mode::Mirror, 2.5);
        assert!((a.time - 1.5).abs() < 1e-3 && ended == 1, "{a:?}");
        let (a, _) = run(Mode::Mirror, 4.5);
        assert!((a.time - 0.5).abs() < 1e-3, "{a:?}");
        let (a, ended) = run(Mode::Single, 9.0);
        assert!(a.time == 2.0 && a.finished && ended == 1 && !a.playing());
    }

    #[test]
    fn fades_follow_the_blend_time() {
        let mut a = AnimLayer { blend_in: true, blend_out: true, ..AnimLayer::new(0, Some(0)) };
        a.advance(0.25, 2.0, Mode::Single);
        assert!((a.weight(2.0) - 0.5).abs() < 1e-6);
        a.advance(1.5, 2.0, Mode::Single);
        assert!((a.weight(2.0) - 0.5).abs() < 1e-6);
        // A looping layer fades in once.
        let mut a = AnimLayer { blend_in: true, ..AnimLayer::new(0, Some(0)) };
        a.advance(0.6, 2.0, Mode::Loop);
        a.advance(1.6, 2.0, Mode::Loop);
        assert_eq!(a.weight(2.0), 1.0);
    }

    #[test]
    fn scripts_pause_stop_and_set_frames() {
        let mut a = AnimLayer::new(0, Some(0));
        a.advance(1.0, 2.0, Mode::Loop);
        a.pause();
        a.advance(1.0, 2.0, Mode::Loop);
        assert_eq!(a.time, 1.0);
        a.play();
        a.set_frame(59.0, 30.0);
        // Setting a frame suppresses the ended event of the step that follows.
        assert!(!a.advance(0.2, 2.0, Mode::Loop));
        a.stop();
        assert!(a.time == 0.0 && !a.playing());
    }
}
