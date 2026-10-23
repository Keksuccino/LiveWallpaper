//! Dumps a file from a scene package, e.g. `puppet_info <scene.pkg> scene.json`.
//! For a `.tex` file, prints its header; with a third argument, saves an uncompressed one as PNG.
//! For a `.mdl` file, lists its animations and how far frame 0 is from the bind pose.
use std::path::Path;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let home = std::env::var("HOME").unwrap();
    let assets = format!("{home}/Library/Application Support/LiveWallpaper/WallpaperEngineAssets");
    let vfs = scene_renderer::vfs::Vfs::open(Path::new(&a[1]), Some(Path::new(&assets))).unwrap();
    let data = vfs.read(&a[2]).expect("no such file");
    if let Ok(range) = std::env::var("LW_HEX") {
        // LW_HEX=offset,len dumps raw bytes, e.g. when a parser error names an offset.
        let (off, len) = range.split_once(',').unwrap();
        let (off, len): (usize, usize) = (off.parse().unwrap(), len.parse().unwrap());
        for (i, chunk) in data[off..off + len].chunks(16).enumerate() {
            let hex: Vec<String> = chunk.iter().map(|b| format!("{b:02x}")).collect();
            println!("{:08x}  {}", off + i * 16, hex.join(" "));
        }
        return;
    }
    if a[2].ends_with(".mdl") {
        let p = scene_renderer::puppet::Puppet::parse(&data).unwrap();
        for anim in &p.animations {
            println!(
                "anim {} {:?} flag {:?} fps {} frames {} tracks {}",
                anim.id, anim.name, anim.flag, anim.fps, anim.duration_frames, anim.tracks.len()
            );
            for t in &anim.tracks {
                let b = &p.bones[t.bone].local;
                let k0 = &t.keyframes[0];
                let kl = t.keyframes.last().unwrap();
                println!(
                    "  bone {} bind t {:?} | k0 t {:?} r {:?} | last r {:?}",
                    t.bone, &b[3][..3], k0.translation, k0.rotation, kl.rotation
                );
            }
        }
        return;
    }
    if !a[2].ends_with(".tex") {
        print!("{}", String::from_utf8_lossy(&data));
        return;
    }
    let t = scene_renderer::tex::decode(&data).unwrap();
    let m = &t.images[0][0];
    println!(
        "{:?} texture {}x{} image {}x{} mip0 {}x{} clamp {} frames {}",
        t.format, t.texture_width, t.texture_height, t.image_width, t.image_height, m.width, m.height, t.clamp, t.frames.len()
    );
    if let Some(out) = a.get(3) {
        let channels = m.data.len() / (m.width * m.height);
        let rgba: Vec<u8> = m
            .data
            .chunks(channels)
            .flat_map(|p| match channels {
                1 => [p[0], p[0], p[0], 255],
                2 => [p[0], p[0], p[0], p[1]],
                3 => [p[0], p[1], p[2], 255],
                _ => [p[0], p[1], p[2], p[3]],
            })
            .collect();
        image::save_buffer(out, &rgba, m.width as u32, m.height as u32, image::ColorType::Rgba8).unwrap();
    }
}
