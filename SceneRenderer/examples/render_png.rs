//! Renders one frame of a scene to PNG.
//!
//! Usage: render_png <scene.pkg> <out.png> [time] [width height] [fit]
//! `fit` is one of fill, fit, stretch, unscaled, blurred.
use scene_renderer::FitMode;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let started = std::time::Instant::now();
    let r = scene_renderer::Renderer::new(a[1].clone()).expect("load");
    println!("loaded in {:?}", started.elapsed());
    for e in r.load_errors() {
        println!("warning: {e}");
    }
    let time: f64 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(1.0);
    let w: u32 = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(1920);
    let h: u32 = a.get(5).and_then(|s| s.parse().ok()).unwrap_or(1080);
    if let Some(mode) = a.get(6) {
        let mode = match mode.as_str() {
            "fit" => FitMode::Fit,
            "stretch" => FitMode::Stretch,
            "unscaled" => FitMode::Unscaled,
            "blurred" => FitMode::MatchBlurred,
            _ => FitMode::Fill,
        };
        r.set_fit_mode(mode);
    }
    r.resize(w, h);
    let started = std::time::Instant::now();
    let mut px = r.render_frame(time).expect("render");
    println!("frame in {:?}", started.elapsed());
    for p in px.chunks_mut(4) {
        p.swap(0, 2);
    }
    image::save_buffer(&a[2], &px, w, h, image::ColorType::Rgba8).expect("save");
}
