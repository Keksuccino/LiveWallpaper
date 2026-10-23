//! File lookup across a scene package, its unpacked folder and the shared Wallpaper Engine assets.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::Error;

/// `.pkg` archive: `str ver, u32 count, count * (str name, u32 offset, u32 size)`, then the data.
/// Strings are a u32 length followed by bytes. Only the entry table stays in memory; entries are
/// read from the file on demand so the package never sits in RAM.
#[derive(Debug)]
pub struct Pkg {
    file: std::fs::File,
    entries: HashMap<String, (u64, usize)>,
}

impl Pkg {
    pub fn open(path: &Path) -> Result<Self, Error> {
        use std::io::Read;
        let io = |e: std::io::Error| Error::Io(format!("{}: {e}", path.display()));
        let mut file = std::fs::File::open(path).map_err(io)?;
        let len = file.metadata().map_err(io)?.len();
        // The header holds names only; 4 MB covers tens of thousands of entries.
        let mut data = Vec::new();
        let _ = (&mut file)
            .take(4 << 20)
            .read_to_end(&mut data)
            .map_err(io)?;
        let mut r = Reader::new(&data);
        let version = r.string()?;
        if !version.starts_with("PKGV") {
            return Err(Error::Format(format!("not a scene package ({version})")));
        }
        let count = r.u32()? as usize;
        if count > 100_000 {
            return Err(Error::Format("package entry count is out of range".into()));
        }
        let mut raw = Vec::with_capacity(count);
        for _ in 0..count {
            let name = r.string()?;
            raw.push((name, r.u32()? as usize, r.u32()? as usize));
        }
        let base = r.pos as u64;
        let mut entries = HashMap::with_capacity(count);
        for (name, offset, size) in raw {
            let start = base + offset as u64;
            if start + size as u64 > len {
                return Err(Error::Format(format!(
                    "package entry {name} is out of bounds"
                )));
            }
            // Later duplicates win, like the editor's own loader.
            let _ = entries.insert(name.to_ascii_lowercase(), (start, size));
        }
        Ok(Self { file, entries })
    }

    pub fn get(&self, name: &str) -> Option<Vec<u8>> {
        use std::os::unix::fs::FileExt;
        let &(start, size) = self.entries.get(&name.to_ascii_lowercase())?;
        let mut out = vec![0; size];
        self.file.read_exact_at(&mut out, start).ok()?;
        Some(out)
    }
}

pub struct Reader<'a> {
    pub data: &'a [u8],
    pub pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }
    pub fn bytes(&mut self, n: usize) -> Result<&'a [u8], Error> {
        let end = self.pos.checked_add(n).filter(|&e| e <= self.data.len());
        let end = end.ok_or_else(|| Error::Format("file is truncated".into()))?;
        let out = &self.data[self.pos..end];
        self.pos = end;
        Ok(out)
    }
    pub fn u32(&mut self) -> Result<u32, Error> {
        let b = self.bytes(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
    pub fn i32(&mut self) -> Result<i32, Error> {
        Ok(self.u32()? as i32)
    }
    pub fn f32(&mut self) -> Result<f32, Error> {
        Ok(f32::from_bits(self.u32()?))
    }
    pub fn string(&mut self) -> Result<String, Error> {
        let n = self.u32()? as usize;
        Ok(String::from_utf8_lossy(self.bytes(n)?).into_owned())
    }
    pub fn cstring(&mut self) -> Result<String, Error> {
        let rest = &self.data[self.pos..];
        let n = rest.iter().take(64).position(|&b| b == 0);
        let n = n.ok_or_else(|| Error::Format("unterminated string".into()))?;
        self.pos += n + 1;
        Ok(String::from_utf8_lossy(&rest[..n]).into_owned())
    }
}

/// Lookup order: the package, the scene folder, then the shared assets folder.
#[derive(Debug)]
pub struct Vfs {
    pkg: Option<Pkg>,
    roots: Vec<PathBuf>,
}

impl Vfs {
    /// `scene_path` is a `scene.pkg` file or an unpacked scene folder.
    pub fn open(scene_path: &Path, assets: Option<&Path>) -> Result<Self, Error> {
        let mut roots = Vec::new();
        let pkg = if scene_path.is_dir() {
            roots.push(scene_path.to_path_buf());
            None
        } else {
            roots.extend(scene_path.parent().map(Path::to_path_buf));
            Some(Pkg::open(scene_path)?)
        };
        roots.extend(assets.map(Path::to_path_buf));
        Ok(Self { pkg, roots })
    }

    pub fn read(&self, name: &str) -> Option<Vec<u8>> {
        let name = name.trim_start_matches('/');
        if let Some(bytes) = self.pkg.as_ref().and_then(|p| p.get(name)) {
            return Some(bytes);
        }
        self.roots
            .iter()
            .find_map(|root| std::fs::read(root.join(name)).ok())
    }

    pub fn read_string(&self, name: &str) -> Option<String> {
        self.read(name)
            .map(|b| String::from_utf8_lossy(&b).into_owned())
    }

    pub fn json(&self, name: &str) -> Result<serde_json::Value, Error> {
        let text = self
            .read_string(name)
            .ok_or_else(|| Error::Missing(name.to_string()))?;
        serde_json::from_str(&text).map_err(|e| Error::Format(format!("{name}: {e}")))
    }
}

impl std::fmt::Debug for Reader<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Reader").field("pos", &self.pos).finish()
    }
}
