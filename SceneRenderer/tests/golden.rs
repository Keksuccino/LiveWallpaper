//! Golden-image regression harness.
//!
//! Ignored by default: it needs the scenes installed in the local library. It renders every scene
//! in `Library/` at 640x360, t = 1.0 s, and compares the result against a golden PNG stored in
//! `~/Library/Caches/LiveWallpaper/golden/<id>.png`. Goldens are our own renders of copyrighted
//! scenes, so they never enter git; a missing golden is created on the first run and must be
//! looked at before it is trusted.
//!
//! ```bash
//! LW_GOLDEN_UPDATE=1 cargo +stable test --offline --test golden -- --ignored --nocapture
//! cargo +stable test --offline --test golden -- --ignored
//! ```

use std::path::{Path, PathBuf};

const WIDTH: u32 = 640;
const HEIGHT: u32 = 360;
const TIME: f64 = 1.0;
/// Mean absolute channel difference allowed between two renders.
const MEAN_TOL: f64 = 2.0 / 255.0;
/// A pixel counts as changed when any channel differs by more than this.
const PIXEL_TOL: f64 = 16.0 / 255.0;
/// At most this share of pixels may be changed.
const MAX_CHANGED: f64 = 0.01;

fn library_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Library/Application Support/LiveWallpaper/Library"))
}

fn golden_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Library/Caches/LiveWallpaper/golden"))
}

/// Scene folders that contain something the renderer can open.
fn local_scenes(library: &Path) -> Vec<(String, PathBuf)> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(library) else {
        return out;
    };
    for e in entries.flatten() {
        let path = e.path();
        let Some(id) = e.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if path.join("scene.pkg").is_file() || path.is_dir() && path.join("scene.json").is_file() {
            out.push((id, path));
        }
    }
    out.sort();
    out
}

/// Renders one frame as RGBA8 (the API returns BGRA8).
fn render_rgba(path: &Path) -> Result<(Vec<u8>, Vec<String>), String> {
    let r = scene_renderer::Renderer::new(path.to_string_lossy().into_owned(), None)
        .map_err(|e| format!("load: {e}"))?;
    r.set_frame_size(WIDTH, HEIGHT);
    let mut px = r.render_frame(TIME).map_err(|e| format!("render: {e}"))?;
    for p in px.chunks_mut(4) {
        p.swap(0, 2);
    }
    Ok((px, r.load_errors()))
}

fn load_rgba(path: &Path) -> Option<Vec<u8>> {
    let img = image::open(path).ok()?.into_rgba8();
    if img.width() != WIDTH || img.height() != HEIGHT {
        return None;
    }
    Some(img.into_raw())
}

/// Mean absolute channel difference plus the share of pixels that differ clearly.
fn diff(got: &[u8], want: &[u8]) -> (f64, f64) {
    let mut sum = 0u64;
    let mut changed = 0u64;
    let pixels = got.len() / 4;
    for (g, w) in got
        .as_chunks::<4>()
        .0
        .iter()
        .zip(want.as_chunks::<4>().0.iter())
    {
        let mut worst = 0u8;
        for c in 0..4 {
            let d = g[c].abs_diff(w[c]);
            sum += d as u64;
            worst = worst.max(d);
        }
        if f64::from(worst) / 255.0 > PIXEL_TOL {
            changed += 1;
        }
    }
    let mean = sum as f64 / got.len() as f64;
    (mean, changed as f64 / pixels as f64)
}

/// Renders every installed scene and compares it with its golden.
///
/// Scenes without a golden are written on the first run (or with `LW_GOLDEN_UPDATE=1`) and then
/// need a look by a human before they count as a baseline.
#[test]
#[ignore = "needs the local scene library"]
fn golden_scenes() {
    let Some(library) = library_dir() else {
        panic!("HOME is not set");
    };
    let scenes = local_scenes(&library);
    assert!(
        !scenes.is_empty(),
        "no scenes found in {}",
        library.display()
    );
    let golden = golden_dir().expect("HOME is not set");
    let update = std::env::var_os("LW_GOLDEN_UPDATE").is_some_and(|v| v == "1");

    let mut failures = Vec::new();
    for (id, path) in &scenes {
        let pkg = if path.join("scene.pkg").is_file() {
            path.join("scene.pkg")
        } else {
            path.clone()
        };
        let (px, warnings) = match render_rgba(&pkg) {
            Ok(v) => v,
            Err(e) => {
                failures.push(format!("{id}: {e}"));
                continue;
            }
        };
        for w in &warnings {
            println!("{id}: warning: {w}");
        }
        let golden_path = golden.join(format!("{id}.png"));
        if update || !golden_path.is_file() {
            std::fs::create_dir_all(&golden).expect("golden dir");
            image::save_buffer(&golden_path, &px, WIDTH, HEIGHT, image::ColorType::Rgba8)
                .expect("write golden");
            println!(
                "{id}: golden written to {} (inspect it before trusting it)",
                golden_path.display()
            );
            continue;
        }
        let Some(want) = load_rgba(&golden_path) else {
            failures.push(format!(
                "{id}: golden unreadable or wrong size: {}",
                golden_path.display()
            ));
            continue;
        };
        let (mean, changed) = diff(&px, &want);
        if mean > MEAN_TOL || changed > MAX_CHANGED {
            failures.push(format!(
                "{id}: mean diff {mean:.4} (tol {MEAN_TOL:.4}), changed {:.2}% (tol {:.2}%)",
                changed * 100.0,
                MAX_CHANGED * 100.0
            ));
        } else {
            println!(
                "{id}: ok mean diff {mean:.4}, changed {:.3}%",
                changed * 100.0
            );
        }
    }
    assert!(
        failures.is_empty(),
        "golden mismatches:\n{}",
        failures.join("\n")
    );
}
