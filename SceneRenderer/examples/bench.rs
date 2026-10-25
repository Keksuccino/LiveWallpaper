//! Plays a scene into an off-window CAMetalLayer at a fixed size and fps, then prints the
//! process CPU time and peak memory.
//!
//! Usage: bench <scene.pkg> [seconds] [fps] [width height] [--align cover|fill|center|stretch|free]
//! [--blur] [--scale s] [--hold]
use objc2_quartz_core::CAMetalLayer;
use scene_renderer::{Alignment, Framing};

fn flag(a: &[String], name: &str) -> Option<usize> {
    a.iter().position(|x| x == name)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let secs: u64 = a.get(2).and_then(|s| s.parse().ok()).unwrap_or(20);
    let fps: f32 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(30.0);
    let w: u32 = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(3024);
    let h: u32 = a.get(5).and_then(|s| s.parse().ok()).unwrap_or(1964);
    let r = scene_renderer::Renderer::new(a[1].clone(), None).expect("load");
    let layer = CAMetalLayer::new();
    r.attach_layer(
        "bench".into(),
        objc2::rc::Retained::as_ptr(&layer) as u64,
        w,
        h,
    );
    // `LW_PROPS="name=json,..."` sets user properties first, to time a scene with parts off.
    for pair in std::env::var("LW_PROPS").unwrap_or_default().split(',').filter(|p| !p.is_empty()) {
        if let Some((name, value)) = pair.split_once('=') {
            r.apply_property(name.to_string(), value.to_string());
        }
    }
    if let Some(i) = flag(&a, "--align") {
        let alignment = match a.get(i + 1).map(String::as_str) {
            Some("fill") => Alignment::Fill,
            Some("center") => Alignment::Center,
            Some("stretch") => Alignment::Stretch,
            Some("free") => Alignment::Free,
            _ => Alignment::Cover,
        };
        r.set_framing(Framing { alignment, blur_bars: flag(&a, "--blur").is_some(), ..Framing::default() });
    }
    if let Some(i) = flag(&a, "--scale") {
        let s = a.get(i + 1).and_then(|s| s.parse().ok()).unwrap_or(1.0);
        r.set_render_scale(s);
    }
    r.set_fps_cap(fps);
    r.play();
    let start = std::time::Instant::now();
    std::thread::sleep(std::time::Duration::from_secs(secs));
    // SAFETY: zeroing a plain-old-data struct is always valid; `libc_rusage` matches the C layout
    // of the leading rusage fields on this platform and the tail is never read.
    let mut usage: libc_rusage = unsafe { std::mem::zeroed() };
    // SAFETY: `usage` is a valid writable pointer to the struct the callee fills in.
    unsafe { getrusage(0, &mut usage) };
    let cpu = usage.ru_utime.tv_sec as f64
        + usage.ru_utime.tv_usec as f64 / 1e6
        + usage.ru_stime.tv_sec as f64
        + usage.ru_stime.tv_usec as f64 / 1e6;
    println!(
        "pid {} wall {:.1}s cpu {:.2}s ({:.1}% of one core) peak rss {:.0} MB",
        std::process::id(),
        start.elapsed().as_secs_f64(),
        cpu,
        100.0 * cpu / start.elapsed().as_secs_f64(),
        usage.ru_maxrss as f64 / 1048576.0
    );
    let st = r.stats();
    println!(
        "frames {} gpu {:.2} ms/frame",
        st.frames, st.gpu_ms_per_frame
    );
    if a.iter().any(|x| x == "--hold") {
        std::thread::sleep(std::time::Duration::from_secs(600));
    }
}

#[repr(C)]
struct Timeval {
    tv_sec: i64,
    tv_usec: i32,
}
#[repr(C)]
struct libc_rusage {
    ru_utime: Timeval,
    ru_stime: Timeval,
    ru_maxrss: i64,
    rest: [i64; 13],
}
extern "C" {
    fn getrusage(who: i32, usage: *mut libc_rusage) -> i32;
}
