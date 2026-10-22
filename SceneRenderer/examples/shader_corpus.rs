//! Translates every shader under `<root>/shaders` with default combos and reports failures.
//! Usage: shader_corpus <scene-or-assets-dir> [assets-dir]
use std::collections::BTreeMap;
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let root = Path::new(&args[1]);
    let vfs = scene_renderer::vfs::Vfs::open(root, args.get(2).map(Path::new)).expect("open");
    let (mut ok, mut failed) = (0, 0);
    let mut stack = vec![root.join("shaders")];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            if path.extension().and_then(|e| e.to_str()) != Some("frag") {
                continue;
            }
            let rel = path
                .strip_prefix(root.join("shaders"))
                .unwrap()
                .with_extension("");
            let name = rel.to_string_lossy().to_string();
            let result = scene_renderer::shader::Source::load(&vfs, &name)
                .and_then(|s| s.compile(&BTreeMap::new()));
            match result {
                Ok(_) => ok += 1,
                Err(e) => {
                    failed += 1;
                    let msg = e.to_string();
                    println!(
                        "FAIL {name}: {}",
                        msg.lines().take(40).collect::<Vec<_>>().join(" | ")
                    );
                }
            }
        }
    }
    println!("ok {ok} failed {failed}");
}
