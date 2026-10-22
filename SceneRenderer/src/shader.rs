//! Wallpaper Engine shader translation: HLSL-flavoured GLSL 1.20 -> GLSL 4.50 -> (naga) -> MSL.
//!
//! Steps: inline `#include`s, read `[COMBO]` and per-uniform JSON annotations, resolve `#if` blocks
//! with the final combo values (so only live uniforms reach the uniform block), rewrite
//! `attribute`/`varying`/`uniform`/`sampler2D` into explicit-binding 4.50 declarations, then let naga
//! emit MSL. Results are memoised by source hash on disk, so a scene compiles once per machine.

use std::collections::{BTreeMap, HashMap};
use std::fmt::Write as _;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

use naga::back::msl;
use naga::front::glsl;
use serde_json::Value;

use crate::vfs::Vfs;
use crate::Error;

const TRANSLATOR_REVISION: u32 = 4;

/// Vertex buffer slot; uniform blocks use slot 0 in both stages.
pub const VERTEX_BUFFER_SLOT: u8 = 16;

const PRELUDE: &str = "\
#define texSample2D(t, uv) texture(t, uv)
#define texSample2DLod(t, uv, l) textureLod(t, uv, l)
#define mul(x, y) ((y) * (x))
#define frac fract
#define saturate(x) clamp(x, 0.0, 1.0)
#define lerp mix
#define atan2 atan
#define ddx dFdx
#define ddy dFdy
#define CAST2(x) vec2(x)
#define CAST3(x) vec3(x)
#define CAST4(x) vec4(x)
#define CAST3X3(x) mat3(x)
#define CASTU(x) uint(x)
#define CASTF(x) float(x)
#define CASTI(x) int(x)
#define log10(x) (log2(x) * 0.30102999566)
#define fmod(x, y) ((x) - (y) * trunc((x) / (y)))
#define rsqrt inversesqrt
#define clip(x) if ((x) < 0.0) discard
mat2 lw_inverse(mat2 m) { return mat2(m[1][1], -m[0][1], -m[1][0], m[0][0]) / determinant(m); }
mat3 lw_inverse(mat3 m) {
    vec3 a = m[0], b = m[1], c = m[2];
    vec3 r0 = cross(b, c), r1 = cross(c, a), r2 = cross(a, b);
    return transpose(mat3(r0, r1, r2)) / dot(a, r0);
}
mat4 lw_inverse(mat4 m) {
    float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2], a03 = m[0][3];
    float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2], a13 = m[1][3];
    float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2], a23 = m[2][3];
    float a30 = m[3][0], a31 = m[3][1], a32 = m[3][2], a33 = m[3][3];
    float b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10, b02 = a00 * a13 - a03 * a10;
    float b03 = a01 * a12 - a02 * a11, b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12;
    float b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30, b08 = a20 * a33 - a23 * a30;
    float b09 = a21 * a32 - a22 * a31, b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32;
    float det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
    return mat4(
        a11 * b11 - a12 * b10 + a13 * b09, a02 * b10 - a01 * b11 - a03 * b09, a31 * b05 - a32 * b04 + a33 * b03, a22 * b04 - a21 * b05 - a23 * b03,
        a12 * b08 - a10 * b11 - a13 * b07, a00 * b11 - a02 * b08 + a03 * b07, a32 * b02 - a30 * b05 - a33 * b01, a20 * b05 - a22 * b02 + a23 * b01,
        a10 * b10 - a11 * b08 + a13 * b06, a01 * b08 - a00 * b10 - a03 * b06, a30 * b04 - a31 * b02 + a33 * b00, a21 * b02 - a20 * b04 - a23 * b00,
        a11 * b07 - a10 * b09 - a12 * b06, a00 * b09 - a01 * b07 + a02 * b06, a31 * b01 - a30 * b03 - a32 * b00, a20 * b03 - a21 * b01 + a22 * b00) / det;
}
vec2 pow(vec2 a, float b) { return pow(a, vec2(b)); }
vec3 pow(vec3 a, float b) { return pow(a, vec3(b)); }
vec4 pow(vec4 a, float b) { return pow(a, vec4(b)); }
";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Vertex,
    Fragment,
}

/// Where a uniform lives in a stage's uniform buffer.
#[derive(Debug, Clone)]
pub struct Uniform {
    pub name: String,
    pub offset: u32,
    /// Floats per element: 1..4 for scalars/vectors, cols*rows for matrices.
    pub rows: u32,
    pub cols: u32,
    pub col_stride: u32,
    pub count: u32,
    pub stride: u32,
    pub is_int: bool,
}

#[derive(Debug, Clone, Default)]
pub struct StageCode {
    pub msl: String,
    pub entry: String,
    pub ubo_size: u32,
    pub uniforms: Vec<Uniform>,
    /// `g_TextureN` index -> Metal texture/sampler slot.
    pub textures: Vec<(usize, u8)>,
}

#[derive(Debug, Clone, Default)]
pub struct Program {
    pub vertex: StageCode,
    pub fragment: StageCode,
    /// Vertex attribute name -> location.
    pub attributes: Vec<(String, u32)>,
    /// Uniform annotations (`material` key, `default`, ...) by uniform name.
    pub uniform_meta: HashMap<String, Value>,
    /// Texture annotations by texture index.
    pub texture_meta: HashMap<usize, Value>,
}

/// Raw shader text with includes inlined, plus what the annotations say.
#[derive(Debug, Clone)]
pub struct Source {
    pub vert: String,
    pub frag: String,
    pub combo_defaults: BTreeMap<String, i64>,
    pub uniform_meta: HashMap<String, Value>,
    pub texture_meta: HashMap<usize, Value>,
}

impl Source {
    pub fn load(vfs: &Vfs, name: &str) -> Result<Self, Error> {
        let read = |ext: &str| -> Result<String, Error> {
            let path = format!("shaders/{name}.{ext}");
            let text = vfs.read_string(&path).ok_or_else(|| Error::Missing(path))?;
            Ok(inline_includes(vfs, &text, 0))
        };
        let (vert, frag) = (read("vert")?, read("frag")?);
        let mut combo_defaults = BTreeMap::new();
        let mut uniform_meta = HashMap::new();
        let mut texture_meta = HashMap::new();
        for line in vert.lines().chain(frag.lines()) {
            let line = line.trim();
            if let Some(json) = line.strip_prefix("// [COMBO]") {
                if let Ok(v) = serde_json::from_str::<Value>(json.trim()) {
                    if let Some(c) = v["combo"].as_str() {
                        let _ = combo_defaults.insert(c.to_string(), v["default"].as_i64().unwrap_or(0));
                    }
                }
                continue;
            }
            let Some((decl, json)) = line.split_once("//") else { continue };
            let Some(decl) = decl.trim().strip_prefix("uniform ") else { continue };
            let Ok(meta) = serde_json::from_str::<Value>(json.trim()) else { continue };
            let Some(name) = decl.trim_end_matches(';').split_whitespace().last() else { continue };
            let name = name.split('[').next().unwrap_or(name).to_string();
            if let Some(index) = texture_index(&name) {
                let _ = texture_meta.insert(index, meta);
            } else {
                let _ = uniform_meta.insert(name, meta);
            }
        }
        Ok(Self { vert, frag, combo_defaults, uniform_meta, texture_meta })
    }

    /// Compiles with the given combo values (unset combos take their defaults).
    pub fn compile(&self, combos: &BTreeMap<String, i64>) -> Result<Program, Error> {
        let mut defines = self.combo_defaults.clone();
        defines.extend(combos.iter().map(|(k, v)| (k.clone(), *v)));
        // Metal shares Direct3D's texture and clip-space orientation, so take the HLSL branches.
        let _ = defines.entry("HLSL".into()).or_insert(1);

        let key = cache_key(&[&self.vert, &self.frag], &defines);
        // Combos are also referenced as values in code (`ApplyBlending(BLENDMODE, ...)`).
        let combo_defs: String = defines.iter().map(|(k, v)| format!("#define {k} {v}\n")).collect();
        let vert = combo_defs.clone() + &preprocess(&self.vert, &defines);
        let frag = combo_defs + &preprocess(&self.frag, &defines);
        let (vert_glsl, attributes, varyings) = rewrite(&vert, Stage::Vertex, &[]);
        let (frag_glsl, _, _) = rewrite(&frag, Stage::Fragment, &varyings);
        let vertex = cached(&key, "vs", || to_msl(&vert_glsl, Stage::Vertex))?;
        let fragment = cached(&key, "fs", || to_msl(&frag_glsl, Stage::Fragment))?;
        Ok(Program {
            vertex,
            fragment,
            attributes,
            uniform_meta: self.uniform_meta.clone(),
            texture_meta: self.texture_meta.clone(),
        })
    }
}

pub fn texture_index(name: &str) -> Option<usize> {
    name.strip_prefix("g_Texture")?.parse().ok()
}

fn inline_includes(vfs: &Vfs, text: &str, depth: u32) -> String {
    let mut out = String::with_capacity(text.len());
    for line in text.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("#include") {
            let file = rest.trim().trim_matches(|c| c == '"' || c == '<' || c == '>');
            if depth < 8 {
                if let Some(inc) = vfs.read_string(&format!("shaders/{file}")) {
                    out.push_str(&inline_includes(vfs, &inc, depth + 1));
                    out.push('\n');
                }
            }
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

// ---------------------------------------------------------------------------------------------
// Conditional compilation. Only `#if` family directives are resolved here; `#define`s stay in the
// text for naga's preprocessor but are tracked so later conditions see them.

fn preprocess(text: &str, combos: &BTreeMap<String, i64>) -> String {
    let mut defs: HashMap<String, String> = combos.iter().map(|(k, v)| (k.clone(), v.to_string())).collect();
    // (this branch active, some earlier branch of this #if was taken, parent active)
    let mut stack: Vec<(bool, bool, bool)> = Vec::new();
    let mut out = String::with_capacity(text.len());
    let active = |s: &Vec<(bool, bool, bool)>| s.last().is_none_or(|t| t.0);
    let mut lines = text.lines();
    while let Some(raw) = lines.next() {
        // Join backslash continuations.
        let mut line = raw.to_string();
        while line.ends_with('\\') {
            let _ = line.pop();
            match lines.next() {
                Some(next) => line.push_str(next),
                None => break,
            }
        }
        let t = line.trim_start();
        let directive = t.strip_prefix('#').map(|d| {
            let d = d.trim_start();
            let end = d.find(|c: char| !c.is_ascii_alphanumeric() && c != '_').unwrap_or(d.len());
            (&d[..end], strip_comment(d[end..].trim()))
        });
        match directive {
            Some(("if", expr)) => {
                let parent = active(&stack);
                let v = parent && eval(expr, &defs) != 0;
                stack.push((v, v, parent));
            }
            Some(("ifdef", name)) | Some(("ifndef", name)) => {
                let parent = active(&stack);
                let has = defs.contains_key(name.trim());
                let v = parent && (has == t.contains("ifdef"));
                stack.push((v, v, parent));
            }
            Some(("elif", expr)) => {
                if let Some(top) = stack.last_mut() {
                    let v = top.2 && !top.1 && eval(expr, &defs) != 0;
                    top.0 = v;
                    top.1 |= v;
                }
            }
            Some(("else", _)) => {
                if let Some(top) = stack.last_mut() {
                    top.0 = top.2 && !top.1;
                    top.1 = true;
                }
            }
            Some(("endif", _)) => {
                let _ = stack.pop();
            }
            _ if !active(&stack) => {}
            Some(("define", rest)) => {
                let mut parts = rest.splitn(2, char::is_whitespace);
                let name = parts.next().unwrap_or("");
                if !name.contains('(') {
                    let _ = defs.insert(name.to_string(), parts.next().unwrap_or("1").trim().to_string());
                }
                out.push_str(&line);
                out.push('\n');
            }
            Some(("undef", name)) => {
                let _ = defs.remove(name.trim());
                out.push_str(&line);
                out.push('\n');
            }
            Some(("require", _)) | Some(("version", _)) | Some(("extension", _)) => {}
            _ => {
                out.push_str(&line);
                out.push('\n');
            }
        }
    }
    out
}

fn strip_comment(s: &str) -> &str {
    s.split("//").next().unwrap_or("").trim()
}

/// Integer `#if` expression evaluator. Unknown identifiers are 0, as in C.
fn eval(expr: &str, defs: &HashMap<String, String>) -> i64 {
    let tokens = tokenize(expr);
    let mut p = Expr { t: &tokens, i: 0, defs, depth: 0 };
    p.or()
}

fn tokenize(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let cs: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i];
        if c.is_whitespace() {
            i += 1;
        } else if c.is_ascii_alphanumeric() || c == '_' {
            let start = i;
            while i < cs.len() && (cs[i].is_ascii_alphanumeric() || cs[i] == '_' || cs[i] == '.') {
                i += 1;
            }
            out.push(cs[start..i].iter().collect());
        } else {
            let two: String = cs[i..(i + 2).min(cs.len())].iter().collect();
            if ["&&", "||", "==", "!=", "<=", ">="].contains(&two.as_str()) {
                out.push(two);
                i += 2;
            } else {
                out.push(c.to_string());
                i += 1;
            }
        }
    }
    out
}

struct Expr<'a> {
    t: &'a [String],
    i: usize,
    defs: &'a HashMap<String, String>,
    depth: u32,
}

impl Expr<'_> {
    fn peek(&self) -> &str {
        self.t.get(self.i).map_or("", String::as_str)
    }
    fn eat(&mut self, s: &str) -> bool {
        let hit = self.peek() == s;
        self.i += usize::from(hit);
        hit
    }
    fn or(&mut self) -> i64 {
        let mut v = self.and();
        while self.eat("||") {
            let r = self.and();
            v = i64::from(v != 0 || r != 0);
        }
        v
    }
    fn and(&mut self) -> i64 {
        let mut v = self.cmp();
        while self.eat("&&") {
            let r = self.cmp();
            v = i64::from(v != 0 && r != 0);
        }
        v
    }
    fn cmp(&mut self) -> i64 {
        let mut v = self.add();
        loop {
            let op = self.peek().to_string();
            if !["==", "!=", "<", ">", "<=", ">="].contains(&op.as_str()) {
                return v;
            }
            self.i += 1;
            let r = self.add();
            v = i64::from(match op.as_str() {
                "==" => v == r,
                "!=" => v != r,
                "<" => v < r,
                ">" => v > r,
                "<=" => v <= r,
                _ => v >= r,
            });
        }
    }
    fn add(&mut self) -> i64 {
        let mut v = self.unary();
        loop {
            if self.eat("+") {
                v = v.wrapping_add(self.unary());
            } else if self.eat("-") {
                v = v.wrapping_sub(self.unary());
            } else if self.eat("*") {
                v = v.wrapping_mul(self.unary());
            } else if self.eat("/") {
                let r = self.unary();
                v = if r == 0 { 0 } else { v / r };
            } else {
                return v;
            }
        }
    }
    fn unary(&mut self) -> i64 {
        if self.eat("!") {
            return i64::from(self.unary() == 0);
        }
        if self.eat("-") {
            return -self.unary();
        }
        if self.eat("(") {
            let v = self.or();
            let _ = self.eat(")");
            return v;
        }
        let tok = self.peek().to_string();
        self.i += 1;
        if tok == "defined" {
            let paren = self.eat("(");
            let name = self.peek().to_string();
            self.i += 1;
            if paren {
                let _ = self.eat(")");
            }
            return i64::from(self.defs.contains_key(&name));
        }
        if let Ok(n) = tok.trim_end_matches(['u', 'U']).parse::<f64>() {
            return n as i64;
        }
        match self.defs.get(&tok) {
            Some(value) if self.depth < 16 => {
                let tokens = tokenize(value);
                let mut sub = Expr { t: &tokens, i: 0, defs: self.defs, depth: self.depth + 1 };
                sub.or()
            }
            _ => 0,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Declaration rewrite to GLSL 4.50.

/// Returns the 4.50 text, the attribute locations (vertex) and the varying locations.
fn rewrite(text: &str, stage: Stage, varyings_in: &[(String, u32)]) -> (String, Vec<(String, u32)>, Vec<(String, u32)>) {
    let mut decls = String::new();
    let mut body = String::new();
    let mut block = String::new();
    let mut seen = std::collections::HashSet::new();
    let mut attributes = Vec::new();
    let mut varyings: Vec<(String, u32)> = varyings_in.to_vec();
    let mut next_sampler = 32usize;
    let mut copies: Vec<String> = Vec::new();

    for line in text.lines() {
        let code = strip_comment(line);
        let mut words = code.trim_end_matches(';').split_whitespace();
        let qualifier = words.next().unwrap_or("");
        // HLSL branches declare system values (`in uint gl_VertexID;`); GLSL has them built in.
        if qualifier == "in" && code.contains(" gl_") {
            continue;
        }
        if !matches!(qualifier, "uniform" | "attribute" | "varying") || !code.ends_with(';') {
            // `texture2D` is a type name in 4.50, so the 1.20 sampling calls are renamed in place.
            let line = line.replace("texture2DLod(", "textureLod(").replace("texture2D(", "texture(");
            // `inverse` is replaced by the prelude's version (naga's MSL output lacks it); a shader's
            // own definition is renamed out of the way.
            let own = line.trim_start().starts_with("mat") && line.contains(" inverse(");
            let line = if own { line.replace(" inverse(", " lw_own_inverse(") } else { line.replace("inverse(", "lw_inverse(") };
            body.push_str(&rename_reserved(&line));
            body.push('\n');
            continue;
        }
        let rest: Vec<&str> = words.filter(|w| !matches!(*w, "lowp" | "mediump" | "highp")).collect();
        // `uniform float a, b;` is rare in this corpus; take the declared names one by one.
        let (ty, names) = match rest.split_first() {
            Some((ty, names)) => (*ty, names.join(" ")),
            None => continue,
        };
        for name in names.split(',').map(str::trim).filter(|n| !n.is_empty()) {
            let base = name.split('[').next().unwrap_or(name).split('=').next().unwrap_or(name).trim().to_string();
            if !seen.insert(base.clone()) {
                continue;
            }
            match qualifier {
                "uniform" if ty.starts_with("sampler") => {
                    let index = texture_index(&base).unwrap_or_else(|| {
                        next_sampler += 1;
                        next_sampler
                    });
                    let tex_ty = if ty.contains("Comparison") || ty.contains("Shadow") { "texture2D" } else { "texture2D" };
                    let samp_ty = if ty.contains("Comparison") || ty.contains("Shadow") { "samplerShadow" } else { "sampler" };
                    let combined = if samp_ty == "sampler" { "sampler2D" } else { "sampler2DShadow" };
                    let _ = writeln!(
                        decls,
                        "layout(set = 0, binding = {}) uniform {tex_ty} {base}_t;\nlayout(set = 0, binding = {}) uniform {samp_ty} {base}_s;\n#define {base} {combined}({base}_t, {base}_s)",
                        2 * index + 1,
                        2 * index + 2
                    );
                }
                // shortcut: no audio capture yet, so spectra are silent constants (std140 would
                // also give these float arrays a stride that function parameters cannot take).
                "uniform" if base.starts_with("g_AudioSpectrum") => {
                    let n = slots(name);
                    let _ = writeln!(decls, "const float {base}[{n}] = float[{n}]({});", vec!["0.0"; n as usize].join(", "));
                }
                "uniform" => {
                    let _ = writeln!(block, "    {ty} {};", name.split('=').next().unwrap_or(name).trim());
                }
                "attribute" if stage == Stage::Vertex => {
                    let loc = attributes.len() as u32;
                    attributes.push((base.clone(), loc));
                    let _ = writeln!(decls, "layout(location = {loc}) in {ty} {name};");
                }
                _ if base.starts_with("gl_") => {}
                _ => {
                    // varying
                    let existing = varyings.iter().find(|(n, _)| n.split('[').next() == Some(&base)).map(|(_, l)| *l);
                    match (stage, existing) {
                        (Stage::Fragment, None) => {
                            // Not written by the vertex stage: a zero constant keeps the pipeline valid.
                            let _ = writeln!(decls, "{ty} {name} = {ty}(0);");
                        }
                        _ => {
                            let loc = existing.unwrap_or_else(|| {
                                // Arrays take one location per element.
                                let l = varyings.last().map_or(0, |(n, l)| l + slots(n));
                                varyings.push((name.to_string(), l));
                                l
                            });
                            let flat = if ty.starts_with('u') || ty.starts_with('i') { "flat " } else { "" };
                            if stage == Stage::Vertex {
                                let _ = writeln!(decls, "layout(location = {loc}) {flat}out {ty} {name};");
                            } else {
                                // 1.20 shaders may write to their inputs, so read them into globals.
                                let suffix = name.strip_prefix(base.as_str()).unwrap_or("");
                                let _ = writeln!(decls, "layout(location = {loc}) {flat}in {ty} lw_in_{base}{suffix};\n{ty} {name};");
                                copies.push(base.clone());
                            }
                        }
                    }
                }
            }
        }
    }

    let mut out = String::from("#version 450\n");
    out.push_str(PRELUDE);
    if stage == Stage::Fragment {
        out.push_str("layout(location = 0) out vec4 lw_FragColor;\n#define gl_FragColor lw_FragColor\n");
    }
    // Macros the declarations depend on (e.g. array sizes) are defined in the body, so keep the
    // body's `#define`s first.
    for line in body.lines().filter(|l| l.trim_start().starts_with("#define") || l.trim_start().starts_with("#undef")) {
        out.push_str(line);
        out.push('\n');
    }
    if !block.is_empty() {
        let _ = writeln!(out, "layout(std140, set = 0, binding = 0) uniform LwUniforms {{\n{block}}};");
    }
    out.push_str(&decls);
    let mut code: String = body
        .lines()
        .filter(|l| !(l.trim_start().starts_with("#define") || l.trim_start().starts_with("#undef")))
        .flat_map(|l| [l, "\n"])
        .collect();
    if !copies.is_empty() {
        if let Some(open) = code.find("void main").and_then(|m| code[m..].find('{').map(|b| m + b + 1)) {
            let init: String = copies.iter().map(|n| format!(" {n} = lw_in_{n};")).collect();
            code.insert_str(open, &init);
        }
    }
    out.push_str(&code);
    (out, attributes, varyings)
}

fn slots(declared: &str) -> u32 {
    declared.split_once('[').and_then(|(_, n)| n.trim_end_matches(']').trim().parse().ok()).unwrap_or(1)
}

/// Renames identifiers that are reserved words in GLSL 4.50 but legal names in 1.20/HLSL.
fn rename_reserved(line: &str) -> String {
    const RESERVED: [&str; 9] = ["sample", "input", "output", "filter", "common", "partition", "active", "smooth", "patch"];
    if !RESERVED.iter().any(|w| line.contains(w)) {
        return line.to_string();
    }
    let mut out = String::with_capacity(line.len() + 8);
    let mut word = String::new();
    let flush = |word: &mut String, out: &mut String| {
        if RESERVED.contains(&word.as_str()) {
            out.push_str("lw_");
        }
        out.push_str(word);
        word.clear();
    };
    for c in line.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            word.push(c);
        } else {
            flush(&mut word, &mut out);
            out.push(c);
        }
    }
    flush(&mut word, &mut out);
    out
}

// ---------------------------------------------------------------------------------------------
// naga.

fn to_msl(glsl: &str, stage: Stage) -> Result<StageCode, Error> {
    let naga_stage = match stage {
        Stage::Vertex => naga::ShaderStage::Vertex,
        Stage::Fragment => naga::ShaderStage::Fragment,
    };
    let module = glsl::Frontend::default()
        .parse(&glsl::Options::from(naga_stage), glsl)
        .map_err(|e| Error::Shader(e.emit_to_string(glsl)))?;
    let info = naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::all())
        .validate(&module)
        .map_err(|e| Error::Shader(e.emit_to_string(glsl)))?;

    let mut code = StageCode::default();
    let mut resources = msl::BindingMap::new();
    for (_, var) in module.global_variables.iter() {
        let Some(binding) = var.binding else { continue };
        let name = var.name.clone().unwrap_or_default();
        let mut target = msl::BindTarget::default();
        if binding.binding == 0 {
            target.buffer = Some(0);
            code.ubo_size = module.types[var.ty].inner.size(module.to_ctx());
            if let naga::TypeInner::Struct { members, .. } = &module.types[var.ty].inner {
                code.uniforms = members.iter().filter_map(|m| uniform_layout(&module, m)).collect();
            }
        } else {
            let slot = ((binding.binding - 1) / 2) as usize;
            // Metal has 31 buffer/texture slots and 16 samplers per stage.
            let metal_slot = u8::try_from(slot.min(30)).unwrap_or(30);
            if binding.binding % 2 == 1 {
                target.texture = Some(metal_slot);
                let index = name.strip_suffix("_t").and_then(texture_index).unwrap_or(slot);
                code.textures.push((index, metal_slot));
            } else {
                target.sampler = Some(msl::BindSamplerTarget::Resource(metal_slot.min(15)));
            }
        }
        let _ = resources.insert(binding, target);
    }

    let entry = module.entry_points.first().map(|e| e.name.clone()).unwrap_or_else(|| "main".into());
    let mut options = msl::Options {
        lang_version: (2, 4),
        fake_missing_bindings: false,
        zero_initialize_workgroup_memory: false,
        force_loop_bounding: false,
        ..Default::default()
    };
    let _ = options
        .per_entry_point_map
        .insert(entry, msl::EntryPointResources { resources, immediates_buffer: None, sizes_buffer: None });
    let pipeline = msl::PipelineOptions {
        entry_point: None,
        allow_and_force_point_size: false,
        vertex_pulling_transform: false,
        vertex_buffer_mappings: Vec::new(),
    };
    let (msl_text, tinfo) =
        msl::write_string(&module, &info, &options, &pipeline).map_err(|e| Error::Shader(format!("msl: {e}")))?;
    code.entry = match tinfo.entry_point_names.into_iter().next() {
        Some(Ok(name)) => name,
        Some(Err(e)) => return Err(Error::Shader(format!("msl entry point: {e}"))),
        None => return Err(Error::Shader("shader has no main()".into())),
    };
    code.msl = msl_text;
    Ok(code)
}

fn uniform_layout(module: &naga::Module, m: &naga::StructMember) -> Option<Uniform> {
    let mut u = Uniform {
        name: m.name.clone()?,
        offset: m.offset,
        rows: 1,
        cols: 1,
        col_stride: 0,
        count: 1,
        stride: 0,
        is_int: false,
    };
    let mut inner = &module.types[m.ty].inner;
    if let naga::TypeInner::Array { base, size, stride } = inner {
        u.count = match size {
            naga::ArraySize::Constant(n) => n.get(),
            _ => 1,
        };
        u.stride = *stride;
        inner = &module.types[*base].inner;
    }
    match inner {
        naga::TypeInner::Scalar(s) => u.is_int = s.kind != naga::ScalarKind::Float,
        naga::TypeInner::Vector { size, scalar } => {
            u.rows = *size as u32;
            u.is_int = scalar.kind != naga::ScalarKind::Float;
        }
        naga::TypeInner::Matrix { columns, rows, .. } => {
            u.cols = *columns as u32;
            u.rows = *rows as u32;
            // std140: every column is padded to a vec4.
            u.col_stride = 16;
        }
        _ => return None,
    }
    Some(u)
}

// ---------------------------------------------------------------------------------------------
// Disk cache.

fn cache_key(texts: &[&str], defines: &BTreeMap<String, i64>) -> String {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    // Bump when the translation itself changes so stale cached MSL is not reused.
    (env!("CARGO_PKG_VERSION"), TRANSLATOR_REVISION).hash(&mut h);
    PRELUDE.hash(&mut h);
    texts.hash(&mut h);
    defines.hash(&mut h);
    format!("{:016x}", h.finish())
}

fn cache_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Library/Caches/LiveWallpaper/shaders"))
}

/// Cache format: line 1 `entry ubo_size`, line 2 uniforms, line 3 textures, then MSL.
fn cached(key: &str, stage: &str, compile: impl FnOnce() -> Result<StageCode, Error>) -> Result<StageCode, Error> {
    let path = cache_dir().map(|d| d.join(format!("{key}.{stage}.metal")));
    if let Some(code) = path.as_ref().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|t| parse_cached(&t)) {
        return Ok(code);
    }
    let code = compile()?;
    if let Some(path) = path {
        let mut text = format!("// {} {}\n// ", code.entry, code.ubo_size);
        for u in &code.uniforms {
            let _ = write!(
                text,
                "{},{},{},{},{},{},{},{} ",
                u.name, u.offset, u.rows, u.cols, u.col_stride, u.count, u.stride, u8::from(u.is_int)
            );
        }
        text.push_str("\n// ");
        for (i, s) in &code.textures {
            let _ = write!(text, "{i},{s} ");
        }
        text.push('\n');
        text.push_str(&code.msl);
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = path.with_extension("tmp");
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
    Ok(code)
}

fn parse_cached(text: &str) -> Option<StageCode> {
    let mut lines = text.splitn(4, '\n');
    let mut head = lines.next()?.strip_prefix("// ")?.split(' ');
    let entry = head.next()?.to_string();
    let ubo_size = head.next()?.parse().ok()?;
    let uniforms = lines
        .next()?
        .strip_prefix("// ")?
        .split_whitespace()
        .map(|u| {
            let f: Vec<&str> = u.split(',').collect();
            let n = |i: usize| f.get(i).and_then(|s| s.parse::<u32>().ok());
            Some(Uniform {
                name: f.first()?.to_string(),
                offset: n(1)?,
                rows: n(2)?,
                cols: n(3)?,
                col_stride: n(4)?,
                count: n(5)?,
                stride: n(6)?,
                is_int: n(7)? == 1,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    let textures = lines
        .next()?
        .strip_prefix("// ")?
        .split_whitespace()
        .map(|t| {
            let (i, s) = t.split_once(',')?;
            Some((i.parse().ok()?, s.parse().ok()?))
        })
        .collect::<Option<Vec<_>>>()?;
    Some(StageCode { msl: lines.next()?.to_string(), entry, ubo_size, uniforms, textures })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn defs(pairs: &[(&str, i64)]) -> BTreeMap<String, i64> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    #[test]
    fn conditionals_follow_combos_and_defines() {
        let src = "#if A && !B\nx\n#elif B == 2\ny\n#else\nz\n#endif\n#define C 1\n#ifdef C\nw\n#endif\n";
        assert_eq!(preprocess(src, &defs(&[("A", 1)])).trim(), "x\n#define C 1\nw");
        assert_eq!(preprocess(src, &defs(&[("B", 2)])).trim(), "y\n#define C 1\nw");
        assert_eq!(preprocess(src, &defs(&[])).trim(), "z\n#define C 1\nw");
    }

    #[test]
    fn nested_inactive_blocks_stay_inactive() {
        let src = "#if 0\n#if 1\na\n#else\nb\n#endif\n#endif\nc\n";
        assert_eq!(preprocess(src, &defs(&[])).trim(), "c");
    }

    #[test]
    fn effect_shader_translates_to_msl() {
        let vert = "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\nvoid main() {\n gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);\n v_TexCoord = a_TexCoord;\n}\n";
        let frag = "uniform sampler2D g_Texture0;\nuniform float g_Time; // {\"material\":\"t\"}\nvarying vec2 v_TexCoord;\nvoid main() {\n gl_FragColor = texSample2D(g_Texture0, v_TexCoord + frac(g_Time));\n}\n";
        let src = Source {
            vert: vert.into(),
            frag: frag.into(),
            combo_defaults: BTreeMap::new(),
            uniform_meta: HashMap::new(),
            texture_meta: HashMap::new(),
        };
        let p = src.compile(&BTreeMap::new()).unwrap();
        assert!(p.fragment.msl.contains("fract"));
        assert_eq!(p.fragment.textures, vec![(0, 0)]);
        assert_eq!(p.fragment.uniforms[0].name, "g_Time");
        assert_eq!(p.attributes, vec![("a_Position".into(), 0), ("a_TexCoord".into(), 1)]);
    }
}
