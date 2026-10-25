//! Renders one frame of a scene to PNG.
//!
//! Usage: render_png <scene.pkg> <out.png> [time] [width height] [alignment]
//! `alignment` is one of cover, fill, center, stretch, free; `+flip` and `+blur` may follow
//! (`fill+blur`). `WM_FRAMING=position,x,y,zoom` sets the placement (defaults 0.5,0.5,0.5,1).
//! `WM_GRADE=brightness,contrast,saturation,hue` turns the colour options on (0...1, 0.5 neutral).
//! `WM_FILTER=name,strength` picks an image filter from `materials/lut`.
//! `WM_AA=4` turns on multisampling with that many samples.
//! `WM_AUDIO=0.6` feeds a test spectrum.
//! `WM_PROPS="name=json,name=json"` sets user properties first, e.g. `WM_PROPS=clock=1`.
use scene_renderer::{Alignment, ColorGrade, Framing};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let started = std::time::Instant::now();
    let r = scene_renderer::Renderer::new(a[1].clone(), None).expect("load");
    println!("loaded in {:?}", started.elapsed());
    for e in r.load_errors() {
        println!("warning: {e}");
    }
    let time: f64 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(1.0);
    let w: u32 = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(1920);
    let h: u32 = a.get(5).and_then(|s| s.parse().ok()).unwrap_or(1080);
    let numbers = |name: &str| -> Vec<f32> {
        std::env::var(name).unwrap_or_default().split(',').filter_map(|v| v.parse().ok()).collect()
    };
    if let Some(spec) = a.get(6) {
        let mut parts = spec.split('+');
        let alignment = match parts.next() {
            Some("fill") => Alignment::Fill,
            Some("center") => Alignment::Center,
            Some("stretch") => Alignment::Stretch,
            Some("free") => Alignment::Free,
            _ => Alignment::Cover,
        };
        let options: Vec<&str> = parts.collect();
        let n = numbers("WM_FRAMING");
        let at = |i: usize, d: f32| n.get(i).copied().unwrap_or(d);
        r.set_framing(Framing {
            alignment,
            position: at(0, 0.5),
            x: at(1, 0.5),
            y: at(2, 0.5),
            zoom: at(3, 1.0),
            flip: options.contains(&"flip"),
            blur_bars: options.contains(&"blur"),
        });
    }
    let grade = numbers("WM_GRADE");
    let filter = std::env::var("WM_FILTER").unwrap_or_default();
    let (filter, strength) = filter.split_once(',').unwrap_or((filter.as_str(), "1"));
    if grade.len() == 4 || !filter.is_empty() {
        let at = |i: usize| grade.get(i).copied().unwrap_or(0.5);
        r.set_color_grade(ColorGrade {
            adjust: grade.len() == 4,
            brightness: at(0),
            contrast: at(1),
            saturation: at(2),
            hue: at(3),
            filter: filter.to_string(),
            filter_strength: strength.parse().unwrap_or(1.0),
        });
    }
    if let Some(samples) = std::env::var("WM_AA").ok().and_then(|v| v.parse().ok()) {
        r.apply_antialiasing(samples);
    }
    // `WM_HIDE_TEXT=1` hides script-computed text, as the lock screen recording does.
    r.set_hide_scripted_text(std::env::var("WM_HIDE_TEXT").is_ok());
    for pair in std::env::var("WM_PROPS").unwrap_or_default().split(',').filter(|p| !p.is_empty()) {
        if let Some((name, value)) = pair.split_once('=') {
            r.apply_property(name.to_string(), value.to_string());
        }
    }
    // `WM_AUDIO=0.6` feeds a flat spectrum at that level, to see audio-driven layers.
    if let Some(level) = std::env::var("WM_AUDIO").ok().and_then(|v| v.parse::<f32>().ok()) {
        r.set_audio_response(true);
        let bands: Vec<f32> = (0..64).map(|i| level * (1.0 - i as f32 / 128.0)).collect();
        r.set_audio_spectrum(bands.clone(), bands);
    }
    // `WM_POINTER=0.1,0.9` puts the pointer there (0...1, top-left origin).
    if let Some((x, y)) = std::env::var("WM_POINTER").ok().and_then(|v| {
        let (x, y) = v.split_once(',')?;
        Some((x.parse().ok()?, y.parse().ok()?))
    }) {
        r.set_pointer(x, y);
    }
    r.set_frame_size(w, h);
    let started = std::time::Instant::now();
    let mut px = r.render_frame(time).expect("render");
    println!("frame in {:?}", started.elapsed());
    for e in r.load_errors() {
        println!("after frame: {e}");
    }
    for p in px.chunks_mut(4) {
        p.swap(0, 2);
    }
    image::save_buffer(&a[2], &px, w, h, image::ColorType::Rgba8).expect("save");
}
