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

const TRANSLATOR_REVISION: u32 = 12;

/// Vertex buffer slot; uniform blocks use slot 0 in both stages.
pub const VERTEX_BUFFER_SLOT: u8 = 16;

/// How often the source may be patched before a shader is given up on.
const FIX_ROUNDS: usize = 8;

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
// WE's compiler promotes mixed vector sizes in mix(); GLSL does not. Overloads for those pairs.
vec4 mix(vec3 a, vec4 b, float t) { return mix(vec4(a, 1.0), b, t); }
vec4 mix(vec4 a, vec3 b, float t) { return mix(a, vec4(b, 1.0), t); }
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

/// Our own version of the engine's `LightingV1` shader chunk.
///
/// A scene shader asks for the chunk with `#require LightingV1`; the engine has it as a binary
/// blob, we do not, so we write our own. The interface (the function name, its eight parameters
/// and the light uniforms) is the one the engine's own asset shaders use, so every shader that
/// asks for the chunk compiles.
///
/// The chunk only adds the direct light of the scene's point lights. The ambient term belongs to
/// the shader: it multiplies `v_LightAmbientColor` with the albedo itself and adds it with
/// `CombineLighting`, so a scene without lights is lit by the ambient alone.
const LIGHTING_V1: &str = "\
#if LIGHTS_POINT
uniform vec4 g_LPoint_Origin[LIGHTS_POINT];
uniform vec4 g_LPoint_Color[LIGHTS_POINT];
#endif
vec3 lw_point_light(vec3 normal, vec3 direction, vec3 viewDir, vec3 albedo, vec3 radiance, vec3 f0, vec3 specularTint, float roughness, float metallic) {
    vec3 halfDir = normalize(direction + viewDir);
    float ndl = max(dot(normal, direction), 0.0);
    float ndv = max(dot(normal, viewDir), 0.0);
    float ndh = max(dot(normal, halfDir), 0.0);
    float vdh = max(dot(viewDir, halfDir), 0.0);
    float alpha = roughness * roughness;
    float d = ndh * ndh * (alpha * alpha - 1.0) + 1.0;
    float distribution = alpha * alpha / max(3.14159265359 * d * d, 0.0001);
    float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    float geometry = (ndl / (ndl * (1.0 - k) + k)) * (ndv / (ndv * (1.0 - k) + k));
    vec3 fresnel = f0 + (vec3(1.0) - f0) * pow(1.0 - vdh, 5.0);
    vec3 specular = distribution * geometry * fresnel * specularTint / max(4.0 * ndl * ndv, 0.0001);
    vec3 diffuse = (vec3(1.0) - fresnel) * (1.0 - metallic) * albedo / 3.14159265359;
    return (diffuse + specular) * radiance * ndl;
}
vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 f0, float roughness, float metallic) {
    vec3 light = vec3(0.0);
#if LIGHTS_POINT
    for (int i = 0; i < LIGHTS_POINT; ++i) {
        vec3 delta = g_LPoint_Origin[i].xyz - worldPos;
        float distance = length(delta);
        vec3 direction = delta / max(distance, 0.0001);
        vec3 radiance = g_LPoint_Color[i].rgb / max(distance * distance, 0.0001);
        light += lw_point_light(normal, direction, viewVector, color, radiance, f0, specularTint, roughness, metallic);
    }
#endif
    return light;
}
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
            let text = vfs.read_string(&path).ok_or(Error::Missing(path))?;
            Ok(rewrite_spectrum_grid(&inline_includes(vfs, &text, 0)))
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
                        let _ = combo_defaults
                            .insert(c.to_string(), v["default"].as_i64().unwrap_or(0));
                    }
                }
                continue;
            }
            let Some((decl, json)) = line.split_once("//") else {
                continue;
            };
            let Some(decl) = decl.trim().strip_prefix("uniform ") else {
                continue;
            };
            let Ok(meta) = serde_json::from_str::<Value>(json.trim()) else {
                continue;
            };
            let Some(name) = decl.trim_end_matches(';').split_whitespace().last() else {
                continue;
            };
            let name = name.split('[').next().unwrap_or(name).to_string();
            if let Some(index) = texture_index(&name) {
                let _ = texture_meta.insert(index, meta);
            } else {
                let _ = uniform_meta.insert(name, meta);
            }
        }
        Ok(Self {
            vert,
            frag,
            combo_defaults,
            uniform_meta,
            texture_meta,
        })
    }

    /// Compiles with the given combo values (unset combos take their defaults).
    pub fn compile(&self, combos: &BTreeMap<String, i64>) -> Result<Program, Error> {
        let mut defines = self.combo_defaults.clone();
        defines.extend(combos.iter().map(|(k, v)| (k.clone(), *v)));
        // Metal shares Direct3D's texture and clip-space orientation, so take the HLSL branches.
        let _ = defines.entry("HLSL".into()).or_insert(1);
        // The engine counts the rows of a puppet's blend map per scene. We do not draw puppets
        // yet, so one row is enough to make the shader compile.
        let _ = defines.entry("BLENDROWCOUNT".into()).or_insert(1);

        let key = cache_key(&[&self.vert, &self.frag], &defines);
        // The combo values go into the text instead of staying macros: naga's preprocessor gives
        // an expanded token the span of its definition, which would move the spans of the
        // expressions that use a combo out of their own text.
        let vert = narrow_call_args(&expand_combos(&preprocess(&self.vert, &defines), &defines));
        let frag = narrow_call_args(&expand_combos(&preprocess(&self.frag, &defines), &defines));
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

/// HLSL narrows a vector passed to a smaller vector parameter; GLSL has no such conversion, and
/// naga's parser then reports the call as an unknown function. For calls of functions the shader
/// declares itself, a bare global vector argument wider than its parameter gets the swizzle
/// (`rotateVec2(v_TexCoord, a)` with `varying vec4 v_TexCoord` becomes `v_TexCoord.xy`).
fn narrow_call_args(text: &str) -> String {
    const QUALIFIERS: [&str; 9] =
        ["varying", "uniform", "attribute", "in", "out", "const", "highp", "mediump", "lowp"];
    let vec_size = |t: &str| match t {
        "vec2" => 2,
        "vec3" => 3,
        "vec4" => 4,
        _ => 0,
    };
    let mut globals: HashMap<&str, usize> = HashMap::new();
    let mut functions: HashMap<&str, Vec<usize>> = HashMap::new();
    let mut depth = 0i32;
    for line in text.lines() {
        let code = line.split("//").next().unwrap_or("");
        if depth == 0 {
            if let Some(open) = code.find('(') {
                // `type name(params) {`
                let head: Vec<&str> = code[..open].split_whitespace().collect();
                if let (Some(name), true) = (head.last(), head.len() >= 2) {
                    let params = code[open + 1..].split(')').next().unwrap_or("");
                    let sizes = params
                        .split(',')
                        .filter(|p| !p.trim().is_empty())
                        .map(|p| {
                            let toks: Vec<&str> = p
                                .split_whitespace()
                                .filter(|t| !QUALIFIERS.contains(t))
                                .collect();
                            toks.first().map_or(0, |t| vec_size(t))
                        })
                        .collect();
                    let _ = functions.insert(name, sizes);
                }
            } else {
                let toks: Vec<&str> =
                    code.split_whitespace().filter(|t| !QUALIFIERS.contains(t)).collect();
                if let [ty, name, ..] = toks[..] {
                    let name = name.split(['[', ';', '=']).next().unwrap_or(name);
                    if vec_size(ty) > 0 && !name.is_empty() {
                        let _ = globals.insert(name, vec_size(ty));
                    }
                }
            }
        }
        depth += code.matches('{').count() as i32 - code.matches('}').count() as i32;
    }
    if functions.is_empty() || globals.is_empty() {
        return text.to_string();
    }
    let ident = |c: char| c.is_ascii_alphanumeric() || c == '_';
    let mut edits: Vec<(usize, &str)> = Vec::new();
    for (name, sizes) in &functions {
        for (at, _) in text.match_indices(&format!("{name}(")) {
            let before = text[..at].trim_end();
            let prev_word = before
                .rsplit(|c: char| !ident(c))
                .next()
                .unwrap_or("");
            if text[..at].chars().next_back().is_some_and(ident)
                || matches!(prev_word, "void" | "float" | "int" | "vec2" | "vec3" | "vec4" | "mat3" | "mat4" | "bool")
            {
                continue; // part of a longer name, or the declaration itself
            }
            let (mut index, mut start, mut nest) = (0, at + name.len() + 1, 0);
            let from = start;
            for (i, c) in text[from..].char_indices().map(|(i, c)| (from + i, c)) {
                let end = match c {
                    '(' | '[' => {
                        nest += 1;
                        None
                    }
                    ')' | ']' if nest > 0 => {
                        nest -= 1;
                        None
                    }
                    ',' if nest == 0 => Some(i),
                    ')' => Some(i),
                    _ => None,
                };
                let Some(end) = end else { continue };
                let arg = text[start..end].trim();
                if let (Some(&have), Some(&want)) = (globals.get(arg), sizes.get(index)) {
                    if want >= 2 && have > want {
                        edits.push((start + text[start..end].trim_end().len(), &".xyzw"[..want + 1]));
                    }
                }
                if c == ')' {
                    break;
                }
                index += 1;
                start = end + 1;
            }
        }
    }
    edits.sort_by_key(|e| e.0);
    edits.dedup_by_key(|e| e.0);
    let mut out = String::with_capacity(text.len() + edits.len() * 4);
    let mut last = 0;
    for (at, swizzle) in edits {
        out.push_str(&text[last..at]);
        out.push_str(swizzle);
        last = at;
    }
    out.push_str(&text[last..]);
    out
}

pub fn texture_index(name: &str) -> Option<usize> {
    name.strip_prefix("g_Texture")?.parse().ok()
}

/// Puts the combo values into the text instead of leaving them as macros.
///
/// Comments and strings are left alone, and only whole names are replaced, so a name that
/// happens to start with a combo name keeps its own text.
fn expand_combos(text: &str, defines: &BTreeMap<String, i64>) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        let rest = &text[i..];
        if rest.starts_with("//") {
            let end = rest.find('\n').map_or(text.len(), |n| i + n);
            out.push_str(&text[i..end]);
            i = end;
            continue;
        }
        if rest.starts_with("/*") {
            let end = rest.find("*/").map_or(text.len(), |n| i + n + 2);
            out.push_str(&text[i..end]);
            i = end;
            continue;
        }
        if bytes[i] == b'"' {
            let end = rest.find('"').map_or(text.len(), |n| i + n + 1);
            out.push_str(&text[i..end]);
            i = end;
            continue;
        }
        if bytes[i].is_ascii_alphabetic() || bytes[i] == b'_' {
            let start = i;
            while i < text.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
                i += 1;
            }
            let word = &text[start..i];
            match defines.get(word) {
                Some(value) => {
                    let _ = write!(out, "{value}");
                }
                None => out.push_str(word),
            }
            continue;
        }
        let ch = rest.chars().next().unwrap_or('\u{fffd}');
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

fn inline_includes(vfs: &Vfs, text: &str, depth: u32) -> String {
    let mut out = String::with_capacity(text.len());
    for line in text.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("#include") {
            let file = rest
                .trim()
                .trim_matches(|c| c == '"' || c == '<' || c == '>');
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

/// Audio spectrum arrays are flat `float[N]`, but scripts-era shaders index them as a 4-wide grid,
/// `g_AudioSpectrum64Left[i / 4][i % 4]`. GLSL rejects the two-index form, so rewrite it to
/// `[(i / 4) * 4 + (i % 4)]`, which is the same element.
fn rewrite_spectrum_grid(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find("g_AudioSpectrum") {
        let (head, tail) = rest.split_at(at);
        out.push_str(head);
        let name_len = tail.find('[').unwrap_or(tail.len());
        let (name, after) = tail.split_at(name_len);
        out.push_str(name);
        rest = after;
        let Some((row, after_row)) = bracket(rest) else { continue };
        let Some((col, after_col)) = bracket(after_row) else {
            out.push_str(&format!("[{row}]"));
            rest = after_row;
            continue;
        };
        out.push_str(&format!("[(({row}) / 4) * 4 + (({col}) % 4)]"));
        rest = after_col;
    }
    out.push_str(rest);
    out
}

/// Splits a leading `[...]` (brackets may nest) off `s`; returns the inside and what follows.
fn bracket(s: &str) -> Option<(&str, &str)> {
    let inner = s.strip_prefix('[')?;
    let mut depth = 1;
    for (i, c) in inner.char_indices() {
        match c {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    return Some((&inner[..i], &inner[i + 1..]));
                }
            }
            _ => {}
        }
    }
    None
}

// ---------------------------------------------------------------------------------------------
// Conditional compilation. Only `#if` family directives are resolved here; `#define`s stay in the
// text for naga's preprocessor but are tracked so later conditions see them.

fn preprocess(text: &str, combos: &BTreeMap<String, i64>) -> String {
    let mut defs: HashMap<String, String> = combos
        .iter()
        .map(|(k, v)| (k.clone(), v.to_string()))
        .collect();
    preprocess_defs(text, &mut defs)
}

/// Resolves the conditional blocks of `text`, remembering the macros it sees.
fn preprocess_defs(text: &str, defs: &mut HashMap<String, String>) -> String {
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
            let end = d
                .find(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                .unwrap_or(d.len());
            (&d[..end], strip_comment(d[end..].trim()))
        });
        match directive {
            Some(("if", expr)) => {
                let parent = active(&stack);
                let v = parent && eval(expr, defs) != 0;
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
                    let v = top.2 && !top.1 && eval(expr, defs) != 0;
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
                    let _ = defs.insert(
                        name.to_string(),
                        parts.next().unwrap_or("1").trim().to_string(),
                    );
                }
                out.push_str(&line);
                out.push('\n');
            }
            Some(("undef", name)) => {
                let _ = defs.remove(name.trim());
                out.push_str(&line);
                out.push('\n');
            }
            // A chunk the engine adds to the shader; ours replaces the one we know.
            Some(("require", name)) => {
                if name.trim() == "LightingV1" {
                    out.push_str(&preprocess_defs(LIGHTING_V1, defs));
                    out.push('\n');
                }
            }
            Some(("version", _)) | Some(("extension", _)) => {}
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
    let mut p = Expr {
        t: &tokens,
        i: 0,
        defs,
        depth: 0,
    };
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
                let mut sub = Expr {
                    t: &tokens,
                    i: 0,
                    defs: self.defs,
                    depth: self.depth + 1,
                };
                sub.or()
            }
            _ => 0,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Declaration rewrite to GLSL 4.50.

/// The 4.50 text plus the attribute locations (vertex) and the varying locations.
type RewriteOut = (String, Vec<(String, u32)>, Vec<(String, u32)>);

/// Returns the 4.50 text, the attribute locations (vertex) and the varying locations.
fn rewrite(text: &str, stage: Stage, varyings_in: &[(String, u32)]) -> RewriteOut {
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
            let line = line
                .replace("texture2DLod(", "textureLod(")
                .replace("texture2D(", "texture(");
            // `inverse` is replaced by the prelude's version (naga's MSL output lacks it); a shader's
            // own definition is renamed out of the way.
            let own = line.trim_start().starts_with("mat") && line.contains(" inverse(");
            let line = if own {
                line.replace(" inverse(", " lw_own_inverse(")
            } else {
                line.replace("inverse(", "lw_inverse(")
            };
            body.push_str(&rename_reserved(&line));
            body.push('\n');
            continue;
        }
        let rest: Vec<&str> = words
            .filter(|w| !matches!(*w, "lowp" | "mediump" | "highp"))
            .collect();
        // `uniform float a, b;` is rare in this corpus; take the declared names one by one.
        let (ty, names) = match rest.split_first() {
            Some((ty, names)) => (*ty, names.join(" ")),
            None => continue,
        };
        for name in names.split(',').map(str::trim).filter(|n| !n.is_empty()) {
            let base = name
                .split('[')
                .next()
                .unwrap_or(name)
                .split('=')
                .next()
                .unwrap_or(name)
                .trim()
                .to_string();
            if !seen.insert(base.clone()) {
                continue;
            }
            match qualifier {
                "uniform" if ty.starts_with("sampler") => {
                    let index = texture_index(&base).unwrap_or_else(|| {
                        next_sampler += 1;
                        next_sampler
                    });
                    let shadow = ty.contains("Comparison") || ty.contains("Shadow");
                    let samp_ty = if shadow { "samplerShadow" } else { "sampler" };
                    let combined = if shadow {
                        "sampler2DShadow"
                    } else {
                        "sampler2D"
                    };
                    let _ = writeln!(
                        decls,
                        "layout(set = 0, binding = {}) uniform texture2D {base}_t;\nlayout(set = 0, binding = {}) uniform {samp_ty} {base}_s;\n#define {base} {combined}({base}_t, {base}_s)",
                        2 * index + 1,
                        2 * index + 2
                    );
                }
                // std140 gives float arrays a 16-byte stride that function parameters cannot take,
                // so the spectrum travels packed in vec4s and is unpacked into a float array.
                "uniform" if base.starts_with("g_AudioSpectrum") => {
                    let n = slots(name).max(4);
                    let _ = writeln!(block, "    vec4 {base}_v[{}];", n / 4);
                    let items: Vec<String> = (0..n)
                        .map(|i| format!("{base}_v[{}].{}", i / 4, ["x", "y", "z", "w"][i as usize % 4]))
                        .collect();
                    let _ = writeln!(decls, "#define {base} float[{n}]({})", items.join(", "));
                }
                "uniform" => {
                    let _ = writeln!(
                        block,
                        "    {ty} {};",
                        name.split('=').next().unwrap_or(name).trim()
                    );
                }
                "attribute" if stage == Stage::Vertex => {
                    let loc = attributes.len() as u32;
                    attributes.push((base.clone(), loc));
                    let _ = writeln!(decls, "layout(location = {loc}) in {ty} {name};");
                }
                _ if base.starts_with("gl_") => {}
                _ => {
                    // varying
                    let existing = varyings
                        .iter()
                        .find(|(n, _)| n.split('[').next() == Some(&base))
                        .map(|(_, l)| *l);
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
                            let flat = if ty.starts_with('u') || ty.starts_with('i') {
                                "flat "
                            } else {
                                ""
                            };
                            if stage == Stage::Vertex {
                                let _ = writeln!(
                                    decls,
                                    "layout(location = {loc}) {flat}out {ty} {name};"
                                );
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
        out.push_str(
            "layout(location = 0) out vec4 lw_FragColor;\n#define gl_FragColor lw_FragColor\n",
        );
    }
    // Macros the declarations depend on (e.g. array sizes) are defined in the body, so keep the
    // body's `#define`s first.
    for line in body
        .lines()
        .filter(|l| l.trim_start().starts_with("#define") || l.trim_start().starts_with("#undef"))
    {
        out.push_str(line);
        out.push('\n');
    }
    if !block.is_empty() {
        let _ = writeln!(
            out,
            "layout(std140, set = 0, binding = 0) uniform LwUniforms {{\n{block}}};"
        );
    }
    out.push_str(&decls);
    let mut code: String = body
        .lines()
        .filter(|l| {
            !(l.trim_start().starts_with("#define") || l.trim_start().starts_with("#undef"))
        })
        .flat_map(|l| [l, "\n"])
        .collect();
    if !copies.is_empty() {
        if let Some(open) = code
            .find("void main")
            .and_then(|m| code[m..].find('{').map(|b| m + b + 1))
        {
            let init: String = copies
                .iter()
                .map(|n| format!(" {n} = lw_in_{n};"))
                .collect();
            code.insert_str(open, &init);
        }
    }
    out.push_str(&code);
    (out, attributes, varyings)
}

fn slots(declared: &str) -> u32 {
    declared
        .split_once('[')
        .and_then(|(_, n)| n.trim_end_matches(']').trim().parse().ok())
        .unwrap_or(1)
}

/// Renames identifiers that are reserved words in GLSL 4.50 but legal names in 1.20/HLSL.
fn rename_reserved(line: &str) -> String {
    const RESERVED: [&str; 9] = [
        "sample",
        "input",
        "output",
        "filter",
        "common",
        "partition",
        "active",
        "smooth",
        "patch",
    ];
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
// HLSL implicit conversions.
//
// The scene shaders are written in an HLSL dialect: numeric types convert silently and vectors
// of different sizes may be multiplied. GLSL has neither, so naga rejects those lines. naga
// points at the offending expression, so the source is patched and compiled again, until it
// goes through or we run out of attempts.

/// A naga failure the implicit-conversion fixer can look at.
enum TranslateError {
    /// A type error; the module is kept so the fixer can find the expressions in it.
    Types {
        module: Box<naga::Module>,
        error: Box<naga::WithSpan<naga::valid::ValidationError>>,
    },
    /// Anything else: a parse error or a complaint from the MSL back end.
    Other(String),
}

/// Compiles the shader, patching the HLSL-only constructs naga rejects.
fn to_msl(glsl: &str, stage: Stage) -> Result<StageCode, Error> {
    let mut source = glsl.to_string();
    let mut message = String::new();
    for _ in 0..FIX_ROUNDS {
        match translate(&source, stage) {
            Ok(code) => return Ok(code),
            Err(TranslateError::Types { module, error }) => {
                message = error.emit_to_string(&source);
                let Some(fixed) = fix_implicit_conversion(&source, &module, &error) else {
                    return Err(Error::Shader(message));
                };
                source = fixed;
            }
            Err(TranslateError::Other(msg)) => return Err(Error::Shader(msg)),
        }
    }
    Err(Error::Shader(format!(
        "{message}\n(no fix found in {FIX_ROUNDS} attempts)"
    )))
}

/// One translation attempt, without any patching.
fn translate(glsl: &str, stage: Stage) -> Result<StageCode, TranslateError> {
    let naga_stage = match stage {
        Stage::Vertex => naga::ShaderStage::Vertex,
        Stage::Fragment => naga::ShaderStage::Fragment,
    };
    let module = glsl::Frontend::default()
        .parse(&glsl::Options::from(naga_stage), glsl)
        .map_err(|e| TranslateError::Other(e.emit_to_string(glsl)))?;
    let validation = naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    )
    .validate(&module);
    let info = match validation {
        Ok(info) => info,
        Err(error) => {
            return Err(TranslateError::Types {
                module: Box::new(module),
                error: Box::new(error),
            });
        }
    };

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
                code.uniforms = members
                    .iter()
                    .filter_map(|m| uniform_layout(&module, m))
                    .collect();
            }
        } else {
            let slot = ((binding.binding - 1) / 2) as usize;
            // Metal has 31 buffer/texture slots and 16 samplers per stage.
            let metal_slot = u8::try_from(slot.min(30)).unwrap_or(30);
            if binding.binding % 2 == 1 {
                target.texture = Some(metal_slot);
                let index = name
                    .strip_suffix("_t")
                    .and_then(texture_index)
                    .unwrap_or(slot);
                code.textures.push((index, metal_slot));
            } else {
                target.sampler = Some(msl::BindSamplerTarget::Resource(metal_slot.min(15)));
            }
        }
        let _ = resources.insert(binding, target);
    }

    let entry = module
        .entry_points
        .first()
        .map(|e| e.name.clone())
        .unwrap_or_else(|| "main".into());
    let mut options = msl::Options {
        lang_version: (2, 4),
        fake_missing_bindings: false,
        zero_initialize_workgroup_memory: false,
        force_loop_bounding: false,
        ..Default::default()
    };
    let _ = options.per_entry_point_map.insert(
        entry,
        msl::EntryPointResources {
            resources,
            immediates_buffer: None,
            sizes_buffer: None,
        },
    );
    let pipeline = msl::PipelineOptions {
        entry_point: None,
        allow_and_force_point_size: false,
        vertex_pulling_transform: false,
        vertex_buffer_mappings: Vec::new(),
    };
    let (msl_text, tinfo) = msl::write_string(&module, &info, &options, &pipeline)
        .map_err(|e| TranslateError::Other(format!("msl: {e}")))?;
    code.entry = match tinfo.entry_point_names.into_iter().next() {
        Some(Ok(name)) => name,
        Some(Err(e)) => return Err(TranslateError::Other(format!("msl entry point: {e}"))),
        None => return Err(TranslateError::Other("shader has no main()".into())),
    };
    code.msl = msl_text;
    Ok(code)
}

/// Patches the source so that the construct naga complained about becomes valid GLSL.
///
/// Returns `None` when the error is not an implicit conversion we know how to fix.
fn fix_implicit_conversion(
    src: &str,
    module: &naga::Module,
    error: &naga::WithSpan<naga::valid::ValidationError>,
) -> Option<String> {
    let naga::valid::ValidationError::Function { handle, source, .. } = error.as_inner() else {
        return None;
    };
    let function = module.functions.try_get(*handle).ok()?;
    match source {
        naga::valid::FunctionError::Expression { source, .. } => match source {
            naga::valid::ExpressionError::InvalidBinaryOperandTypes {
                op,
                lhs_expr,
                lhs_type,
                rhs_expr,
                rhs_type,
            } => fix_operands(src, function, *op, *lhs_expr, lhs_type, *rhs_expr, rhs_type),
            naga::valid::ExpressionError::InvalidIndexType(index) => {
                fix_index(src, function, *index)
            }
            _ => None,
        },
        naga::valid::FunctionError::InvalidStoreTypes { pointer, value } => {
            fix_store(src, module, function, *pointer, *value)
        }
        // `return v4;` from a function declared `vec3`: WE's compiler narrows it, GLSL does not.
        naga::valid::FunctionError::InvalidReturnType {
            expression: Some(value),
            expected_ty: Some(want),
        } => fix_return(src, module, function, *value, *want),
        // A local variable whose initializer does not have its type.
        naga::valid::FunctionError::LocalVariable {
            handle,
            source: naga::valid::LocalVariableError::InitializerType,
            ..
        } => {
            let local = function.local_variables.try_get(*handle).ok()?;
            let init = local.init?;
            let pointer = local_variable_expression(function, *handle)?;
            fix_store(src, module, function, pointer, init)
        }
        _ => None,
    }
}

/// Wraps a returned value in a constructor of the declared return type (`vec4` -> `vec3(v)`).
fn fix_return(
    src: &str,
    module: &naga::Module,
    function: &naga::Function,
    value: naga::Handle<naga::Expression>,
    want: naga::Handle<naga::Type>,
) -> Option<String> {
    let name = glsl_type_name(&module.types[want].inner)?;
    let span = function.expressions.get_span(value).to_range()?;
    let text = src.get(span.clone())?.to_string();
    patch(src, span, &format!("{name}({text})"))
}

/// The GLSL spelling of a scalar or vector type.
fn glsl_type_name(inner: &naga::TypeInner) -> Option<String> {
    match *inner {
        naga::TypeInner::Scalar(scalar) => Some(glsl_type(scalar.kind).to_string()),
        naga::TypeInner::Vector { size, scalar } => {
            let prefix = match scalar.kind {
                naga::ScalarKind::Sint => "i",
                naga::ScalarKind::Uint => "u",
                naga::ScalarKind::Bool => "b",
                _ => "",
            };
            Some(format!("{prefix}vec{}", size as u8))
        }
        _ => None,
    }
}

/// The expression that stands for a local variable.
fn local_variable_expression(
    function: &naga::Function,
    local: naga::Handle<naga::LocalVariable>,
) -> Option<naga::Handle<naga::Expression>> {
    function
        .expressions
        .iter()
        .find(|(_, e)| matches!(e, naga::Expression::LocalVariable(l) if *l == local))
        .map(|(handle, _)| handle)
}

/// Fixes a binary operation whose two operands do not have the same type.
fn fix_operands(
    src: &str,
    function: &naga::Function,
    op: naga::BinaryOperator,
    lhs_expr: naga::Handle<naga::Expression>,
    lhs_type: &naga::TypeInner,
    rhs_expr: naga::Handle<naga::Expression>,
    rhs_type: &naga::TypeInner,
) -> Option<String> {
    if op == naga::BinaryOperator::Modulo {
        // HLSL's `%` also takes a float and then truncates it; GLSL's float modulo is `mod`.
        let lhs_span = function.expressions.get_span(lhs_expr).to_range()?;
        let rhs_span = function.expressions.get_span(rhs_expr).to_range()?;
        let start = lhs_span.start.min(rhs_span.start);
        let end = lhs_span.end.max(rhs_span.end);
        let whole = src.get(start..end)?;
        if !is_whole_expression(whole) {
            return None;
        }
        let text = format!(
            "mod({}, {})",
            as_float(src.get(lhs_span)?, lhs_type),
            as_float(src.get(rhs_span)?, rhs_type),
        );
        return patch(src, start..end, &text);
    }
    let lhs_len = vector_len(lhs_type)?;
    let rhs_len = vector_len(rhs_type)?;
    if lhs_len != rhs_len && lhs_len != 1 && rhs_len != 1 {
        // HLSL multiplies the shorter vector and drops the extra components of the longer one.
        let target = lhs_len.min(rhs_len) as usize;
        let wider = if lhs_len > rhs_len {
            lhs_expr
        } else {
            rhs_expr
        };
        let span = function.expressions.get_span(wider).to_range()?;
        let text = src.get(span.clone())?;
        if !is_whole_expression(text) {
            return None;
        }
        return patch(src, span, &swizzle(text, target));
    }
    // The same shape, or a scalar: GLSL and HLSL agree on those.
    // HLSL turns a bool into a number (0 or 1) where a number is expected.
    let lhs_kind = scalar_kind(lhs_type)?;
    let rhs_kind = scalar_kind(rhs_type)?;
    if lhs_kind != rhs_kind {
        let (expr, to) = if lhs_kind == naga::ScalarKind::Bool {
            (lhs_expr, rhs_type)
        } else if rhs_kind == naga::ScalarKind::Bool {
            (rhs_expr, lhs_type)
        } else {
            // An integer next to a float: the GLSL front end promotes that on its own.
            return None;
        };
        let span = function.expressions.get_span(expr).to_range()?;
        let text = src.get(span.clone())?;
        let name = glsl_type(scalar_kind(to)?);
        return patch(src, span, &format!("{name}({text})"));
    }
    None
}

/// Fixes an index that is not an integer: HLSL truncates a float index, GLSL wants an integer.
fn fix_index(
    src: &str,
    function: &naga::Function,
    index: naga::Handle<naga::Expression>,
) -> Option<String> {
    // The span of the index is not always the whole expression (a member access is only its
    // field), so the text is taken from the access that uses the index.
    let access = function
        .expressions
        .iter()
        .find(|(_, e)| matches!(e, naga::Expression::Access { index: i, .. } if *i == index))
        .map(|(handle, _)| handle)?;
    let span = function.expressions.get_span(access).to_range()?;
    let text = src.get(span.clone())?;
    let inner = text.trim().strip_prefix('[')?.strip_suffix(']')?;
    if !is_whole_expression(inner) {
        return None;
    }
    patch(src, span, &format!("[int({inner})]"))
}

/// Fixes a store whose value does not have the type of the variable it is written to.
fn fix_store(
    src: &str,
    module: &naga::Module,
    function: &naga::Function,
    pointer: naga::Handle<naga::Expression>,
    value: naga::Handle<naga::Expression>,
) -> Option<String> {
    // The variable that is written to says which type is wanted.
    let target = match *function.expressions.try_get(pointer).ok()? {
        naga::Expression::LocalVariable(local) => module.types[function.local_variables[local].ty]
            .inner
            .clone(),
        _ => return None,
    };
    let value_type = expr_type(module, function, value)?;
    // A compound assignment (`bar *= x`) stores into the variable. Its own span is the whole
    // statement, so the text is taken from there.
    if let Some(span) = function.expressions.get_span(value).to_range() {
        let text = src.get(span.clone())?.to_string();
        // A span that reaches back into a macro definition is not one statement.
        let compound = if text.contains('#') { None } else { compound_assignment(&text) };
        if let Some((left, op, right)) = compound {
            let naga::TypeInner::Scalar(want) = &target else {
                return None;
            };
            let new_text = format!("{left} = {}({left} {op} {right})", glsl_type(want.kind));
            return patch(src, span, &new_text);
        }
    }
    // Otherwise the value is written into a variable. The span of the value itself is not
    // always the whole expression (a member access is only its field), so the text comes from
    // the statement the variable is declared in.
    let statement = function.expressions.get_span(pointer).to_range()?;
    let text = src.get(statement.clone())?;
    // With a macro in the initializer naga's span for the variable is its name alone; the
    // initializer is then read from the source that follows the name.
    // The span can also stretch back over unrelated lines (macro definition to variable); such
    // text is no statement either.
    let clean = !text.contains(['\n', ';']);
    let range = match value_range(text).filter(|_| clean) {
        Some(range) => range,
        None => {
            let range = initializer_after(src, statement.end)?;
            range.start - statement.start..range.end - statement.start
        }
    };
    let value_text = src.get(statement.start + range.start..statement.start + range.end)?.to_string();
    let new_text = match (&target, &value_type) {
        // HLSL converts between the numeric types on the fly, GLSL wants the cast spelled out.
        (naga::TypeInner::Scalar(want), naga::TypeInner::Scalar(got)) if want.kind != got.kind => {
            let inner = float_modulo_text(src, module, function, value)
                .unwrap_or_else(|| value_text.clone());
            format!("{}({inner})", glsl_type(want.kind))
        }
        // A scalar written into a vector is a splat in HLSL.
        (naga::TypeInner::Vector { size, .. }, naga::TypeInner::Scalar(_)) => {
            format!("vec{}({value_text})", *size as u8)
        }
        // A wider vector written into a narrower one keeps its leading components.
        (
            naga::TypeInner::Vector { size: want, scalar: want_scalar },
            naga::TypeInner::Vector { size: got, scalar: got_scalar },
        ) if (*got as u8) > (*want as u8) && want_scalar == got_scalar => {
            format!("({value_text}).{}", &"xyzw"[..*want as usize])
        }
        _ => return None,
    };
    let start = statement.start + range.start;
    let end = statement.start + range.end;
    patch(src, start..end, &new_text)
}

/// The range of `= <expr>` after a variable name at `from`: the expression up to the `;` that ends
/// the statement. `None` when no plain assignment follows.
fn initializer_after(src: &str, from: usize) -> Option<std::ops::Range<usize>> {
    let rest = src.get(from..)?;
    let trimmed = rest.trim_start();
    let eq = from + (rest.len() - trimmed.len());
    let after = trimmed.strip_prefix('=')?;
    if after.starts_with('=') {
        return None;
    }
    let start = eq + 1;
    let mut depth = 0i32;
    for (i, c) in after.char_indices() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ';' if depth == 0 => {
                let text = &after[..i];
                let lead = text.len() - text.trim_start().len();
                return Some(start + lead..start + text.trim_end().len());
            }
            _ => {}
        }
    }
    None
}

/// True for text that is an expression on its own.
///
/// naga gives the span of a member access to the field alone (`.x`), so such a text cannot be
/// used on its own.
fn is_whole_expression(text: &str) -> bool {
    let text = text.trim();
    let starts = text.chars().next().is_some_and(|c| {
        c.is_ascii_alphabetic() || c == '_' || c == '(' || c == '[' || c.is_ascii_digit()
    });
    let ends = text.chars().last().is_some_and(|c| {
        c.is_ascii_alphabetic() || c == '_' || c == ')' || c == ']' || c.is_ascii_digit()
    });
    starts && ends
}

/// The three parts of a compound assignment such as `bar *= x`.
fn compound_assignment(text: &str) -> Option<(String, char, String)> {
    let mut depth = 0i32;
    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            '=' if depth == 0 => {
                if chars.peek().is_some_and(|(_, c)| *c == '=') {
                    // A comparison, not an assignment.
                    let _ = chars.next();
                    continue;
                }
                let left = text[..i].trim_end();
                let op = left.chars().last()?;
                if !matches!(op, '+' | '-' | '*' | '/' | '%') {
                    return None;
                }
                let left = left[..left.len() - 1].trim_end().to_string();
                let right = text[i + 1..].trim().to_string();
                return Some((left, op, right));
            }
            _ => {}
        }
    }
    None
}

/// The range of the value in a statement like `name = value`.
fn value_range(text: &str) -> Option<std::ops::Range<usize>> {
    let mut depth = 0i32;
    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            '=' if depth == 0 => {
                if chars.peek().is_some_and(|(_, c)| *c == '=') {
                    // A comparison, not an assignment.
                    let _ = chars.next();
                    continue;
                }
                let after = &text[i + 1..];
                let start = i + 1 + (after.len() - after.trim_start().len());
                return Some(start..text.trim_end().len());
            }
            _ => {}
        }
    }
    None
}

/// The text of `a % b` as GLSL's `mod(a, b)`, when one of the two operands is an integer.
///
/// HLSL's `%` takes a float and truncates it, GLSL's `%` is for integers only and its float
/// counterpart is `mod`.
fn float_modulo_text(
    src: &str,
    module: &naga::Module,
    function: &naga::Function,
    value: naga::Handle<naga::Expression>,
) -> Option<String> {
    let naga::Expression::Binary {
        op: naga::BinaryOperator::Modulo,
        left,
        right,
    } = *function.expressions.try_get(value).ok()?
    else {
        return None;
    };
    let left_type = expr_type(module, function, left)?;
    let right_type = expr_type(module, function, right)?;
    let left_is_int = was_integer(function, left, &left_type, src);
    let right_is_int = was_integer(function, right, &right_type, src);
    if left_is_int == right_is_int {
        // Both integers or both floats: the modulo means the same in HLSL and GLSL.
        return None;
    }
    let span = function.expressions.get_span(value).to_range()?;
    let left_span = function.expressions.get_span(left).to_range()?;
    let right_span = function.expressions.get_span(right).to_range()?;
    let text = src.get(span.clone())?;
    let left_text = src.get(left_span)?;
    let right_text = src.get(right_span)?;
    // The expression has to hold the two operands, or the spans are not where they seem.
    let text = text.trim();
    if !is_whole_expression(text)
        || !text.starts_with(left_text.trim())
        || !text.ends_with(right_text.trim())
    {
        return None;
    }
    Some(format!(
        "mod({}, {})",
        if left_is_int {
            format!("float({left_text})")
        } else {
            left_text.to_string()
        },
        if right_is_int {
            format!("float({right_text})")
        } else {
            right_text.to_string()
        },
    ))
}

/// True when the operand was written as an integer.
///
/// The GLSL front end promotes an integer operand to float when the other one is a float, so
/// the type in the module no longer says what the source said.
fn was_integer(
    function: &naga::Function,
    expr: naga::Handle<naga::Expression>,
    ty: &naga::TypeInner,
    src: &str,
) -> bool {
    if scalar_kind(ty) != Some(naga::ScalarKind::Float) {
        return true;
    }
    // A converted value keeps its `As` wrapper; a literal is folded in place and keeps its text.
    if let Ok(naga::Expression::As {
        kind: naga::ScalarKind::Float,
        ..
    }) = function.expressions.try_get(expr)
    {
        return true;
    }
    let Some(span) = function.expressions.get_span(expr).to_range() else {
        return false;
    };
    src.get(span).is_some_and(is_integer_literal)
}

/// True for the text of an integer literal, with or without the `u` suffix.
fn is_integer_literal(text: &str) -> bool {
    let text = text.trim();
    let text = text.strip_suffix(['u', 'U']).unwrap_or(text);
    !text.is_empty() && text.chars().all(|c| c.is_ascii_digit())
}

/// The operand as a float, so that it can be used with GLSL's `mod`.
fn as_float(text: &str, ty: &naga::TypeInner) -> String {
    if scalar_kind(ty) == Some(naga::ScalarKind::Float) {
        text.to_string()
    } else {
        format!("float({text})")
    }
}

/// The scalar kind of a scalar or vector type.
fn scalar_kind(ty: &naga::TypeInner) -> Option<naga::ScalarKind> {
    match ty {
        naga::TypeInner::Scalar(scalar) => Some(scalar.kind),
        naga::TypeInner::Vector { scalar, .. } => Some(scalar.kind),
        _ => None,
    }
}

/// The number of components of a type; a scalar counts as one.
fn vector_len(ty: &naga::TypeInner) -> Option<u8> {
    match ty {
        naga::TypeInner::Scalar(_) => Some(1),
        naga::TypeInner::Vector { size, .. } => Some(*size as u8),
        _ => None,
    }
}

/// The name of a scalar type in GLSL.
fn glsl_type(kind: naga::ScalarKind) -> &'static str {
    match kind {
        naga::ScalarKind::Float => "float",
        naga::ScalarKind::Sint => "int",
        naga::ScalarKind::Uint => "uint",
        naga::ScalarKind::Bool => "bool",
        _ => "float",
    }
}

/// Shortens a vector to `len` components with a swizzle.
fn swizzle(text: &str, len: usize) -> String {
    let components = &"xyzw"[..len];
    if let Some(dot) = text.rfind('.') {
        let tail = &text[dot + 1..];
        if (2..=4).contains(&tail.len()) && tail.chars().all(|c| "xyzw".contains(c)) {
            return format!("{}.{components}", &text[..dot]);
        }
    }
    if is_path(text) {
        format!("{text}.{components}")
    } else {
        format!("({text}).{components}")
    }
}

/// True for a plain name or a chain of them, which can take a swizzle as it is.
fn is_path(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }
    text.split('.').all(|part| {
        let mut chars = part.chars();
        matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
            && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
    })
}

/// Replaces the text in `span` with `text`.
///
/// A span that reaches over a statement or a directive is refused: naga's spans are off when a
/// macro is involved, and a wrong span would cut the shader in half.
fn patch(src: &str, span: std::ops::Range<usize>, text: &str) -> Option<String> {
    let old = src.get(span.clone())?;
    if old.contains(';') || old.contains('#') {
        return None;
    }
    let mut out = String::with_capacity(src.len() + text.len());
    out.push_str(src.get(..span.start)?);
    out.push_str(text);
    out.push_str(src.get(span.end..)?);
    Some(out)
}

/// The type of an expression, as far as the fixer needs to know it.
fn expr_type(
    module: &naga::Module,
    function: &naga::Function,
    handle: naga::Handle<naga::Expression>,
) -> Option<naga::TypeInner> {
    use naga::Expression as E;
    use naga::TypeInner as T;
    let expression = function.expressions.try_get(handle).ok()?;
    Some(match *expression {
        E::Literal(literal) => T::Scalar(match literal {
            naga::Literal::F32(_) => scalar(naga::ScalarKind::Float),
            naga::Literal::F64(_) => scalar(naga::ScalarKind::Float),
            naga::Literal::I32(_) => scalar(naga::ScalarKind::Sint),
            naga::Literal::U32(_) => scalar(naga::ScalarKind::Uint),
            naga::Literal::Bool(_) => scalar(naga::ScalarKind::Bool),
            _ => return None,
        }),
        E::Constant(c) => module.types[module.constants[c].ty].inner.clone(),
        E::Override(o) => module.types[module.overrides[o].ty].inner.clone(),
        E::GlobalVariable(g) => module.types[module.global_variables[g].ty].inner.clone(),
        E::LocalVariable(l) => module.types[function.local_variables[l].ty].inner.clone(),
        E::Load { pointer } => expr_type(module, function, pointer)?,
        E::AccessIndex { base, index } => {
            let base_type = expr_type(module, function, base)?;
            element_type(module, &base_type, index as usize)?
        }
        E::Access { base, .. } => {
            let base_type = expr_type(module, function, base)?;
            element_type(module, &base_type, 0)?
        }
        E::Splat { size, value } => T::Vector {
            size,
            scalar: scalar(scalar_kind(&expr_type(module, function, value)?)?),
        },
        E::As {
            expr,
            kind,
            convert,
        } => match convert {
            Some(width) => T::Scalar(naga::Scalar { kind, width }),
            None => {
                // A bitcast keeps the shape and changes the kind.
                let source = expr_type(module, function, expr)?;
                match source {
                    T::Vector { size, .. } => T::Vector {
                        size,
                        scalar: scalar(kind),
                    },
                    _ => T::Scalar(scalar(kind)),
                }
            }
        },
        E::Compose { ty, .. } => module.types[ty].inner.clone(),
        E::Swizzle { size, vector, .. } => T::Vector {
            size,
            scalar: scalar(scalar_kind(&expr_type(module, function, vector)?)?),
        },
        E::Unary { op, expr } => match op {
            naga::UnaryOperator::LogicalNot => T::Scalar(scalar(naga::ScalarKind::Bool)),
            _ => expr_type(module, function, expr)?,
        },
        E::Binary { op, left, right } => {
            let left_type = expr_type(module, function, left)?;
            let right_type = expr_type(module, function, right)?;
            match op {
                naga::BinaryOperator::LogicalAnd
                | naga::BinaryOperator::LogicalOr
                | naga::BinaryOperator::Equal
                | naga::BinaryOperator::NotEqual
                | naga::BinaryOperator::Less
                | naga::BinaryOperator::LessEqual
                | naga::BinaryOperator::Greater
                | naga::BinaryOperator::GreaterEqual
                | naga::BinaryOperator::And
                | naga::BinaryOperator::InclusiveOr => T::Scalar(scalar(naga::ScalarKind::Bool)),
                _ => arithmetic_type(&left_type, &right_type)?,
            }
        }
        E::Math { fun, arg, .. } => math_type(fun, &expr_type(module, function, arg)?)?,
        E::Relational { .. } => T::Scalar(scalar(naga::ScalarKind::Bool)),
        E::CallResult(callee) => {
            let result = module.functions[callee].result.as_ref()?;
            module.types[result.ty].inner.clone()
        }
        E::ArrayLength(_) => T::Scalar(scalar(naga::ScalarKind::Sint)),
        // Colour textures only: scene shaders sample RGBA images, never depth ones.
        E::ImageSample { .. } | E::ImageLoad { .. } => T::Vector {
            size: naga::VectorSize::Quad,
            scalar: scalar(naga::ScalarKind::Float),
        },
        _ => return None,
    })
}

/// A scalar of the given kind.
fn scalar(kind: naga::ScalarKind) -> naga::Scalar {
    naga::Scalar { kind, width: 4 }
}

/// The type of the element a vector, an array or a struct is indexed into.
fn element_type(
    module: &naga::Module,
    base: &naga::TypeInner,
    index: usize,
) -> Option<naga::TypeInner> {
    match base {
        naga::TypeInner::Vector { scalar, .. } => Some(naga::TypeInner::Scalar(*scalar)),
        naga::TypeInner::Array { base, .. } => Some(module.types[*base].inner.clone()),
        naga::TypeInner::Struct { members, .. } => {
            Some(module.types[members.get(index)?.ty].inner.clone())
        }
        _ => None,
    }
}

/// The type of an arithmetic operation on two operands.
fn arithmetic_type(left: &naga::TypeInner, right: &naga::TypeInner) -> Option<naga::TypeInner> {
    use naga::TypeInner as T;
    let left_kind = scalar_kind(left)?;
    let right_kind = scalar_kind(right)?;
    // The wider kind wins, as in HLSL: an integer next to a float becomes a float.
    let kind = if kind_rank(right_kind) >= kind_rank(left_kind) {
        right_kind
    } else {
        left_kind
    };
    Some(match (left, right) {
        (T::Scalar(_), T::Scalar(_)) => T::Scalar(scalar(kind)),
        (T::Vector { size, .. }, T::Vector { .. }) => T::Vector {
            size: *size,
            scalar: scalar(kind),
        },
        (T::Vector { size, .. }, T::Scalar(_)) => T::Vector {
            size: *size,
            scalar: scalar(kind),
        },
        (T::Scalar(_), T::Vector { size, .. }) => T::Vector {
            size: *size,
            scalar: scalar(kind),
        },
        _ => return None,
    })
}

/// The rank of a numeric type; the wider one wins a mixed-type operation.
fn kind_rank(kind: naga::ScalarKind) -> u32 {
    match kind {
        naga::ScalarKind::Sint => 0,
        naga::ScalarKind::Uint => 1,
        naga::ScalarKind::Float => 2,
        naga::ScalarKind::Bool => 3,
        _ => 2,
    }
}

/// The type of a built-in maths function.
fn math_type(fun: naga::MathFunction, arg: &naga::TypeInner) -> Option<naga::TypeInner> {
    use naga::MathFunction as M;
    use naga::TypeInner as T;
    Some(match fun {
        M::Length | M::Distance | M::Dot | M::Determinant => {
            T::Scalar(scalar(naga::ScalarKind::Float))
        }
        M::Cross => T::Vector {
            size: naga::VectorSize::Tri,
            scalar: scalar(naga::ScalarKind::Float),
        },
        M::Unpack2x16snorm | M::Unpack2x16unorm | M::Unpack2x16float => T::Vector {
            size: naga::VectorSize::Bi,
            scalar: scalar(naga::ScalarKind::Float),
        },
        M::Unpack4x8snorm | M::Unpack4x8unorm | M::Unpack4xI8 | M::Unpack4xU8 => T::Vector {
            size: naga::VectorSize::Quad,
            scalar: scalar(naga::ScalarKind::Float),
        },
        _ => arg.clone(),
    })
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
fn cached(
    key: &str,
    stage: &str,
    compile: impl FnOnce() -> Result<StageCode, Error>,
) -> Result<StageCode, Error> {
    let path = cache_dir().map(|d| d.join(format!("{key}.{stage}.metal")));
    if let Some(code) = path
        .as_ref()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| parse_cached(&t))
    {
        return Ok(code);
    }
    let code = compile()?;
    if let Some(path) = path {
        let mut text = format!("// {} {}\n// ", code.entry, code.ubo_size);
        for u in &code.uniforms {
            let _ = write!(
                text,
                "{},{},{},{},{},{},{},{} ",
                u.name,
                u.offset,
                u.rows,
                u.cols,
                u.col_stride,
                u.count,
                u.stride,
                u8::from(u.is_int)
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
    Some(StageCode {
        msl: lines.next()?.to_string(),
        entry,
        ubo_size,
        uniforms,
        textures,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_vec4_sample_is_narrowed_into_a_vec3() {
        let src = "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\nvoid main() {\n vec3 c = texSample2D(g_Texture0, v_TexCoord);\n gl_FragColor = vec4(c, 1.0);\n}\n";
        let (frag, _, _) = rewrite(src, Stage::Fragment, &[]);
        to_msl(&frag, Stage::Fragment).expect("translates");
    }

    #[test]
    fn wide_global_arguments_are_narrowed_for_shader_functions() {
        let src = "varying vec4 v_TexCoord;\nvec2 rot(vec2 v, float r) {\n return v;\n}\nvoid main() {\n vec2 a = rot(v_TexCoord, 1.0) * 2.0;\n}\n";
        let out = narrow_call_args(src);
        assert!(out.contains("rot(v_TexCoord.xy, 1.0)"), "{out}");
        assert!(out.contains("vec2 rot(vec2 v, float r)"), "{out}");
    }

    use super::*;

    fn defs(pairs: &[(&str, i64)]) -> BTreeMap<String, i64> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    /// Parses a fragment shader and returns the module with its `main` function.
    fn parse_frag(src: &str) -> (naga::Module, naga::Function) {
        let module = naga::front::glsl::Frontend::default()
            .parse(
                &naga::front::glsl::Options::from(naga::ShaderStage::Fragment),
                src,
            )
            .expect("the shader parses");
        let function = module
            .functions
            .iter()
            .find(|(_, f)| f.name.as_deref() == Some("main"))
            .map(|(_, f)| f.clone())
            .expect("the shader has a main function");
        (module, function)
    }

    /// Parses and validates a fragment shader and returns the error naga found.
    fn validate_frag(src: &str) -> (naga::Module, naga::WithSpan<naga::valid::ValidationError>) {
        let module = naga::front::glsl::Frontend::default()
            .parse(
                &naga::front::glsl::Options::from(naga::ShaderStage::Fragment),
                src,
            )
            .expect("the shader parses");
        let error = naga::valid::Validator::new(
            naga::valid::ValidationFlags::all(),
            naga::valid::Capabilities::all(),
        )
        .validate(&module)
        .expect_err("the shader does not validate");
        (module, error)
    }

    /// The source after the fixer had a look at it.
    fn fixed(src: &str) -> String {
        let (module, error) = validate_frag(src);
        fix_implicit_conversion(src, &module, &error).expect("the error can be fixed")
    }

    #[test]
    fn conditionals_follow_combos_and_defines() {
        let src =
            "#if A && !B\nx\n#elif B == 2\ny\n#else\nz\n#endif\n#define C 1\n#ifdef C\nw\n#endif\n";
        assert_eq!(
            preprocess(src, &defs(&[("A", 1)])).trim(),
            "x\n#define C 1\nw"
        );
        assert_eq!(
            preprocess(src, &defs(&[("B", 2)])).trim(),
            "y\n#define C 1\nw"
        );
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
        assert_eq!(
            p.attributes,
            vec![("a_Position".into(), 0), ("a_TexCoord".into(), 1)]
        );
    }

    #[test]
    fn combo_values_go_into_the_text() {
        let text = "int a = RESOLUTION;\n// RESOLUTION in a comment\nfloat b = 1.0;";
        assert_eq!(
            expand_combos(text, &defs(&[("RESOLUTION", 32)])),
            "int a = 32;\n// RESOLUTION in a comment\nfloat b = 1.0;"
        );
    }

    #[test]
    fn a_longer_vector_is_shortened_for_a_product() {
        let src =
            "#version 450\nvoid main() { vec4 v = vec4(1.0); vec2 s = vec2(2.0); vec2 r = v * s; }";
        assert!(fixed(src).contains("v.xy * s"));
    }

    #[test]
    fn a_vector_is_never_shortened_in_the_wrong_place() {
        // The shorter vector stays as it is, the longer one loses its extra components.
        assert_eq!(swizzle("value", 2), "value.xy");
        assert_eq!(swizzle("value.xyz", 2), "value.xy");
        assert_eq!(swizzle("a + b", 3), "(a + b).xyz");
        assert_eq!(swizzle("value", 4), "value.xyzw");
    }

    #[test]
    fn a_number_is_converted_where_a_variable_is_written() {
        let src = "#version 450\nvoid main() { uint i = 1.5; }";
        assert!(fixed(src).contains("uint i = uint(1.5)"));
    }

    #[test]
    fn a_bool_operand_becomes_a_number() {
        let src = "#version 450\nvoid main() { bool b = true; float f = 2.0; float r = f * b; }";
        assert!(fixed(src).contains("f * float(b)"));
    }

    #[test]
    fn a_float_index_becomes_an_integer() {
        let src = "#version 450\nvoid main() { float a[4]; float r = a[1.5]; }";
        assert!(fixed(src).contains("a[int(1.5)]"));
    }

    #[test]
    fn a_modulo_with_an_integer_operand_becomes_a_mod() {
        let src = "#version 450\nvoid main() { float f = 1.0; float r = f % 32; }";
        let (module, function) = parse_frag(src);
        let value = function
            .expressions
            .iter()
            .find(|(_, e)| {
                matches!(
                    e,
                    naga::Expression::Binary {
                        op: naga::BinaryOperator::Modulo,
                        ..
                    }
                )
            })
            .map(|(handle, _)| handle)
            .expect("the modulo is there");
        assert_eq!(
            float_modulo_text(src, &module, &function, value).as_deref(),
            Some("mod(f, float(32))")
        );
    }

    #[test]
    fn a_modulo_of_two_integers_is_left_alone() {
        let src = "#version 450\nvoid main() { uint a = 3u; uint r = a % 4u; }";
        let (module, function) = parse_frag(src);
        let value = function
            .expressions
            .iter()
            .find(|(_, e)| {
                matches!(
                    e,
                    naga::Expression::Binary {
                        op: naga::BinaryOperator::Modulo,
                        ..
                    }
                )
            })
            .map(|(handle, _)| handle)
            .expect("the modulo is there");
        assert_eq!(float_modulo_text(src, &module, &function, value), None);
    }

    #[test]
    fn the_value_of_a_statement_is_found() {
        assert_eq!(value_range("bar = step(1.0, a)"), Some(6..18));
        assert_eq!(value_range("bar == step(1.0, a)"), None);
        assert_eq!(value_range("bar += step(1.0, a)"), Some(7..19));
    }

    #[test]
    fn a_compound_assignment_is_split_into_its_parts() {
        assert_eq!(
            compound_assignment("bar *= step(1.0, a)"),
            Some(("bar".into(), '*', "step(1.0, a)".into()))
        );
        assert_eq!(compound_assignment("bar = step(1.0, a)"), None);
    }

    #[test]
    fn the_lighting_requirement_brings_our_own_chunk() {
        let src = "#require LightingV1\nvoid main() { }";
        let out = preprocess(src, &defs(&[]));
        assert!(out.contains("PerformLighting_V1"));
        // The chunk does not use lights the scene does not have.
        assert!(!out.contains("g_LPoint_Origin"));
    }

    #[test]
    fn a_shader_that_asks_for_lighting_compiles() {
        let frag = "#require LightingV1\nuniform vec3 g_Color;\nvarying vec3 v_Normal;\nvoid main() {\n vec3 light = PerformLighting_V1(vec3(0.0), g_Color, normalize(v_Normal), vec3(0.0, 0.0, 1.0), CAST3(1.0), vec3(0.04), 0.5, 0.0);\n gl_FragColor = vec4(light, 1.0);\n}\n";
        let src = Source {
            vert: "attribute vec3 a_Position;\nvarying vec3 v_Normal;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_Normal = a_Position; }\n"
                .into(),
            frag: frag.into(),
            combo_defaults: BTreeMap::new(),
            uniform_meta: HashMap::new(),
            texture_meta: HashMap::new(),
        };
        let program = src.compile(&BTreeMap::new()).unwrap();
        assert!(program.fragment.msl.contains("PerformLighting_V1"));
    }

    #[test]
    fn a_shader_with_hlsl_conversions_compiles() {
        // The lines of the audio bar shader of the Nier scene: a float modulo and a float
        // written into an unsigned, plus a product with a bool.
        let frag = "uniform float u_BarCount;\nvoid main() {\n float frequency = 3.5;\n uint barFreq1 = frequency % 32;\n uint barFreq2 = (barFreq1 + 1) % 32;\n float bar = step(1.0, frequency);\n bar *= (frequency > 1.0);\n gl_FragColor = vec4(float(barFreq1 + barFreq2 + bar), 0.0, 0.0, 1.0);\n}\n";
        let src = Source {
            vert:
                "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }\n"
                    .into(),
            frag: frag.into(),
            combo_defaults: BTreeMap::new(),
            uniform_meta: HashMap::new(),
            texture_meta: HashMap::new(),
        };
        src.compile(&BTreeMap::new()).unwrap();
    }
}
