//! Wallpaper Engine puppet models (`.mdl`): a mesh, a skeleton and the animations that move it.
//!
//! # Layout
//!
//! All integers are little-endian and all offsets below are absolute in the file. The layout was
//! read from the four puppet models shipped with two local scenes: `angelcommison_puppet.mdl`
//! (13 bones), `angelhair_puppet.mdl` (5 bones), `Right Hand_puppet.mdl` (4 bones) and
//! `Finger Left_puppet.mdl` (3 bones). Nothing here comes from another renderer's source.
//!
//! ## Mesh (`MDLV0023`)
//!
//! ```text
//! 0x00  8   tag "MDLV0023" (no NUL)
//! 0x08  4   format word (0x8000_0900 observed)
//! 0x0c  4   format word (0x0000_0101 observed)
//! 0x10  4   format word (0x0000_0100 observed)
//! 0x14  1   0
//! 0x15  ..  NUL-terminated material path, e.g. "materials/angelcommison.json"
//!       ..  28 zero bytes
//!       ..  u32 vertex_flags (0x0180_000f observed), u32 vertex_bytes
//!       ..  vertex_bytes / 80 vertices, 80 bytes each:
//!             (the layout below is the 80-byte one; the flags word is an attribute mask, see `Attributes`)
//!             +0  position xyz (3 f32)
//!             +12 normal xyz (3 f32)
//!             +24 tangent xyzw (4 f32)
//!             +40 bone indices (4 u32)
//!             +56 bone weights (4 f32, normally summing to 1)
//!             +72 uv (2 f32)
//!       ..  u32 index_bytes, then index_bytes / 2 u16 triangle indices
//!       ..  optional block (not understood), then the per-bone index ranges
//!       ..  16-byte range records: first_index u32, index_count u32, bone u32, 0 u32
//! ```
//!
//! The block between the index buffer and the range table is not understood. In the 5-, 4- and
//! 3-bone files it is 14 bytes and starts `00 01` + a u16 equal to `16 * bone_count`; the 3-bone
//! file has another 16 bytes after that. The 13-bone file instead copies all vertex positions
//! (a 9-byte header, then 12 bytes per vertex) and has a 13-byte block before the table. Rather
//! than guess, the parser locates the table by scanning for a tiling of the index buffer and
//! picks the candidate with the most ranges.
//!
//! The last range record can be 12 bytes (without its padding word), and a zero-count record can
//! follow the ranges. Every range tiles the index buffer from 0 to `index_bytes / 2`.
//!
//! ## Skeleton (`MDLS0004`)
//!
//! ```text
//! 0x00  9   tag "MDLS0004\0"
//! 0x09  4   next chunk offset
//! 0x0d  4   bone count
//! 0x11  1   0
//!       ..  per bone:
//!             u32 flags, u32 parent (0xffff_ffff = root, otherwise an earlier bone),
//!             u32 matrix_bytes = 64, 64-byte 4x4 f32 matrix,
//!             optional NUL-terminated JSON object plus one NUL, or two NULs
//! ```
//!
//! The matrix is stored row-vector style: rows 0..2 are direction, row 3 is translation. It is
//! the bone's local bind transform (identity rotation in all four files) and its translation is
//! exactly the first keyframe translation. The JSON object is editor metadata (`tm`, `tp`, ...),
//! not a transform.
//!
//! A trailing block after the last bone (0x1b1 bytes in the 5-bone file, 0x451 in the 13-bone
//! file) holds more editor data; it is skipped via the next-chunk offset.
//!
//! ## Attachments (`MDAT0001`)
//!
//! ```text
//! 0x00  9   tag "MDAT0001\0"
//! 0x09  4   next chunk offset
//! 0x0d  2   attachment count
//!       ..  per attachment: u16 bone index, NUL-terminated name, 64-byte matrix (bone space)
//! ```
//!
//! The u16 was first read as a name length, but it never matched (`blindofld` gave 12 for a
//! 9-byte name). It is the bone the attachment rides on: 12 and 5 in the Angel model are the two
//! head bones, and placing the blindfold and hair through them lines up with the preview. The
//! name runs to its NUL. Attachment names match the scene's
//! `attachment` values (`blindofld`, `hair`), not skeleton bone names.
//!
//! ## Animations (`MDLA0006`)
//!
//! ```text
//! 0x00  9   tag "MDLA0006\0"
//! 0x09  4   next chunk offset
//! 0x0d  4   animation count
//! 0x11  4   first animation id
//! 0x15  4   0
//!       ..  animation 0 immediately:
//!             name cstring, flag cstring ("loop" or "mirror"),
//!             f32 fps (30), u32 duration_frames, u32 0,
//!             u32 bone_count, u32 0, u32 first_track_bytes,
//!             bone_count tracks: first track has first_track_bytes; the others have
//!             u32 bytes, the keyframes, then u32 0
//! ```
//!
//! A keyframe is 9 f32: translation xyz, rotation xyz in radians, scale xyz. Every observed file
//! has `duration_frames + 1` keyframes per track, and only the Z rotation was non-zero. The
//! rotation order is unconfirmed; the values are exposed as-is.
//!
//! Every animation record starts with its id (u32) and a zero word, then the name. The id is what
//! a scene's `animationlayers[].animation` refers to; it is stored, not computed (`61, 63, 65, 67`
//! in one file, `107, 122, 391, 704, 131` in another). What lies between two records differs
//! between files (39 bytes in some, extra curve data in others), so the parser finds the next
//! record by checking that a whole one parses there.
//!
//! After the last track there are 31 bytes before the next-chunk offset (32 bytes at the end of a
//! file without an `MDLE` chunk). `MDLE0002` is an end marker; files without it store `len - 1`
//! as the next offset. This parser ignores both.

use crate::vfs::Reader;
use crate::Error;

/// Chunks are matched by kind and version: `MDLV` mesh, `MDLS` skeleton, `MDAT` attachments and
/// `MDLA` animations. Every version seen in local scenes (`MDLV0017`/`0019`/`0021`/`0023`,
/// `MDLS0002`/`0004`, `MDLA0005`/`0006`) shares the field layout below, so a new version number
/// needs no code. The vertex layout comes from the attribute mask, see `Attributes`.
pub(crate) const MESH_KIND: &[u8; 4] = b"MDLV";
const SKELETON_KIND: &[u8; 4] = b"MDLS";
const ATTACHMENT_KIND: &[u8; 4] = b"MDAT";
const ANIMATION_KIND: &[u8; 4] = b"MDLA";

/// The vertex flags word of the mesh chunk is an attribute mask. A vertex stores the attributes
/// whose bit is set, in this order: position, normal, tangent, bone indices, bone weights, uv,
/// uv pair. Sizes in bytes: position 12 (bit 0) or 16 (bit 16, a fourth float we drop), normal 12
/// (bit 1), tangent 16 (bit 2), uv 8 (bit 3), uv pair 16 (bit 5: two texture coordinate sets, the
/// second for lightmaps), bone indices 16 (bit 23), bone weights 16 (bit 24).
/// Checked against all 30 local puppet meshes (flags `0xf` = 48 bytes, `0x0180000f` = 80,
/// `0x0181000e` = 84) and the static models of the default 3D scenes (`0x9` = 20, `0xb` = 32,
/// `0x27` = 56 in `arsenal`, whose model JSON asks for a second uv channel); the format is not
/// documented anywhere we could find.
pub(crate) const ATTR_POSITION: u32 = 1 << 0;
pub(crate) const ATTR_NORMAL: u32 = 1 << 1;
pub(crate) const ATTR_TANGENT: u32 = 1 << 2;
pub(crate) const ATTR_UV: u32 = 1 << 3;
pub(crate) const ATTR_UV_PAIR: u32 = 1 << 5;
pub(crate) const ATTR_POSITION4: u32 = 1 << 16;
const ATTR_BONES: u32 = 1 << 23;
const ATTR_WEIGHTS: u32 = 1 << 24;
const ATTR_KNOWN: u32 = ATTR_POSITION
    | ATTR_NORMAL
    | ATTR_TANGENT
    | ATTR_UV
    | ATTR_UV_PAIR
    | ATTR_POSITION4
    | ATTR_BONES
    | ATTR_WEIGHTS;

#[derive(Clone, Copy)]
pub(crate) struct Attributes(u32);

impl Attributes {
    pub(crate) fn from_flags(flags: u32) -> Result<Self, Error> {
        let skin = flags & (ATTR_BONES | ATTR_WEIGHTS);
        if flags & !ATTR_KNOWN != 0
            || flags & (ATTR_POSITION | ATTR_POSITION4) == 0
            || (skin != 0 && skin != ATTR_BONES | ATTR_WEIGHTS)
        {
            return Err(Error::Unsupported(format!(
                "model: vertex attribute flags 0x{flags:x} are not understood"
            )));
        }
        Ok(Self(flags))
    }

    pub(crate) fn has(self, bit: u32) -> bool {
        self.0 & bit != 0
    }

    pub(crate) fn skinned(self) -> bool {
        self.has(ATTR_BONES)
    }

    pub(crate) fn stride(self) -> usize {
        [
            (ATTR_POSITION, 12),
            (ATTR_POSITION4, 16),
            (ATTR_NORMAL, 12),
            (ATTR_TANGENT, 16),
            (ATTR_UV, 8),
            (ATTR_UV_PAIR, 16),
            (ATTR_BONES, 16),
            (ATTR_WEIGHTS, 16),
        ]
        .iter()
        .filter(|(bit, _)| self.has(*bit))
        .map(|(_, size)| size)
        .sum()
    }
}
const KEYFRAME_SIZE: usize = 9 * 4;

pub(crate) const MAX_STRING: usize = 4096;
pub(crate) const MAX_VERTICES: usize = 4_000_000;
pub(crate) const MAX_INDICES: usize = 16_000_000;
const MAX_BONES: usize = 4096;
const MAX_ATTACHMENTS: usize = 4096;
const MAX_ANIMATIONS: usize = 4096;
const MAX_FRAMES: usize = 1_000_000;

/// A parsed puppet model: one mesh, one skeleton, optional attachments and optional animations.
#[derive(Debug, Clone, PartialEq)]
pub struct Puppet {
    /// Material path from the mesh chunk, relative to the scene package.
    pub material: String,
    /// Vertices in the order used by the index buffer.
    pub vertices: Vec<Vertex>,
    /// Triangle-list indices.
    pub indices: Vec<u16>,
    /// Per-bone index ranges from the block after the index buffer.
    pub segments: Vec<Segment>,
    /// Bones in parent-before-child order.
    pub bones: Vec<Bone>,
    /// Named attachment matrices from `MDAT`.
    pub attachments: Vec<Attachment>,
    /// Animations in file order.
    pub animations: Vec<Animation>,
    /// Id of the first animation; later animations add 2 per index.
    pub first_animation_id: u32,
}

/// One mesh vertex. Bone indices refer to [`Puppet::bones`]; unused slots have weight 0.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Vertex {
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub tangent: [f32; 4],
    pub bone_indices: [u16; 4],
    pub bone_weights: [f32; 4],
    pub uv: [f32; 2],
}

/// One skeleton bone. `parent` indexes an earlier bone; roots have `None`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Bone {
    /// Editor flags; their meaning is not known.
    pub flags: u32,
    pub parent: Option<usize>,
    /// Local bind transform, row-vector style: row 3 is the translation.
    pub local: [[f32; 4]; 4],
    /// Optional JSON editor metadata, kept as text.
    pub metadata: Option<String>,
}

/// A named attachment matrix, referenced by a scene object's `attachment` field.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Attachment {
    /// The u16 before the name; read as the bone the attachment follows (see the module notes).
    pub bone: usize,
    pub name: String,
    /// Row-vector style: row 3 is the translation.
    pub matrix: [[f32; 4]; 4],
}

/// A contiguous run of indices drawn with one bone. `bone` indexes [`Puppet::bones`].
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Segment {
    pub first_index: u32,
    pub index_count: u32,
    pub bone: u32,
}

/// A per-bone keyframe: translation, Euler rotation in radians, and scale.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Transform {
    pub translation: [f32; 3],
    pub rotation: [f32; 3],
    pub scale: [f32; 3],
}

/// Keyframes for one bone, in frame order.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Track {
    /// Index into [`Puppet::bones`].
    pub bone: usize,
    pub keyframes: Vec<Transform>,
}

/// One animation. `flag` was `"loop"` or `"mirror"` in the observed files.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Animation {
    pub id: u32,
    pub name: String,
    pub flag: String,
    pub fps: f32,
    pub duration_frames: u32,
    pub tracks: Vec<Track>,
}

impl Animation {
    /// Number of keyframes in the first track, or 0 when there are no tracks.
    pub fn frame_count(&self) -> usize {
        self.tracks.first().map_or(0, |track| track.keyframes.len())
    }

    /// Duration in seconds, derived from `duration_frames` and `fps`.
    pub fn duration_seconds(&self) -> f32 {
        if self.fps > 0.0 {
            self.duration_frames as f32 / self.fps
        } else {
            0.0
        }
    }
}

impl Transform {
    /// Linear blend of two transforms. Rotations are blended as Euler angles; a caller that
    /// wants shortest-path rotation should replace this with quaternion interpolation.
    pub fn lerp(a: &Self, b: &Self, t: f32) -> Self {
        Self {
            translation: lerp3(a.translation, b.translation, t),
            rotation: lerp3(a.rotation, b.rotation, t),
            scale: lerp3(a.scale, b.scale, t),
        }
    }
}

impl Track {
    /// Sample the track at a fractional frame, clamping to the first/last keyframe.
    pub fn sample(&self, frame: f32) -> Transform {
        let Some(first) = self.keyframes.first() else {
            return Transform::default();
        };
        if !frame.is_finite() || frame <= 0.0 {
            return first.clone();
        }
        let last = self.keyframes.len() - 1;
        let frame = frame.min(last as f32);
        let index = frame.floor() as usize;
        if index >= last {
            return self.keyframes[last].clone();
        }
        let t = frame - index as f32;
        Transform::lerp(&self.keyframes[index], &self.keyframes[index + 1], t)
    }
}

impl Puppet {
    /// Parse a complete `.mdl` file.
    ///
    /// The mesh must come first. The skeleton is located by its tag after the index buffer; the
    /// optional attachments and animations are followed through their next-chunk offsets.
    pub fn parse(data: &[u8]) -> Result<Self, Error> {
        let mesh = parse_mesh(data)?;
        if !mesh.skinned {
            return Ok(Self::unskinned(mesh));
        }
        let skeleton_off = find_chunk(data, mesh.end, SKELETON_KIND).ok_or_else(|| {
            bad(format!(
                "no skeleton chunk (MDLS) after the mesh at 0x{:x}",
                mesh.end
            ))
        })?;
        let (bones, mut next) = parse_skeleton(data, skeleton_off)?;

        for (vertex_index, vertex) in mesh.vertices.iter().enumerate() {
            for &bone in &vertex.bone_indices {
                if usize::from(bone) >= bones.len() {
                    return Err(bad(format!(
                        "vertex {vertex_index} references bone {bone}, but the skeleton has {} bones",
                        bones.len()
                    )));
                }
            }
        }

        let segments = find_segments(
            data,
            mesh.end,
            skeleton_off,
            bones.len(),
            mesh.indices.len(),
        );

        let mut attachments = Vec::new();
        if chunk_at(data, next, ATTACHMENT_KIND) {
            let (parsed, after) = parse_attachments(data, next)?;
            attachments = parsed;
            next = after;
        }

        let mut animations = Vec::new();
        let mut first_animation_id = 0;
        if chunk_at(data, next, ANIMATION_KIND) {
            let (parsed, first, _) = parse_animations(data, next, bones.len())?;
            animations = parsed;
            first_animation_id = first;
        }

        Ok(Self {
            material: mesh.material,
            vertices: mesh.vertices,
            indices: mesh.indices,
            segments,
            bones,
            attachments,
            animations,
            first_animation_id,
        })
    }
}

impl Puppet {
    /// A mesh without a skeleton: one identity bone that every vertex follows fully.
    fn unskinned(mesh: Mesh) -> Self {
        let identity = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 1.0],
        ];
        let segments = vec![Segment {
            first_index: 0,
            index_count: mesh.indices.len() as u32,
            bone: 0,
        }];
        Self {
            material: mesh.material,
            vertices: mesh.vertices,
            indices: mesh.indices,
            segments,
            bones: vec![Bone { local: identity, ..Bone::default() }],
            attachments: Vec::new(),
            animations: Vec::new(),
            first_animation_id: 0,
        }
    }
}

struct Mesh {
    material: String,
    vertices: Vec<Vertex>,
    indices: Vec<u16>,
    end: usize,
    skinned: bool,
}

fn parse_mesh(data: &[u8]) -> Result<Mesh, Error> {
    let mut r = Reader::new(data);
    // The mesh chunk has no NUL after its tag; the format word that follows starts with 0x00.
    read_chunk(&mut r, MESH_KIND, false)?;

    let _format = r.u32()?;
    let _format2 = r.u32()?;
    let _format3 = r.u32()?;
    let separator_at = r.pos;
    if r.bytes(1)?[0] != 0 {
        return Err(bad(format!(
            "mesh separator at 0x{separator_at:x} is not 0"
        )));
    }

    let material =
        String::from_utf8_lossy(cstring(&mut r, MAX_STRING, "material path")?).into_owned();
    // 28 bytes, zero in most files; one file family stores a value in them, which is not read.
    let _ = r.bytes(28)?;

    let attributes = Attributes::from_flags(r.u32()?)?;
    let stride = attributes.stride();
    let vertex_bytes = r.u32()? as usize;
    if !vertex_bytes.is_multiple_of(stride) {
        return Err(bad(format!(
            "vertex byte count {vertex_bytes} is not a multiple of {stride}"
        )));
    }
    let vertex_count = vertex_bytes / stride;
    if vertex_count > MAX_VERTICES {
        return Err(bad(format!("vertex count {vertex_count} is too large")));
    }

    let mut vertices = Vec::with_capacity(vertex_count);
    for _ in 0..vertex_count {
        let position = read_vec3(&mut r, "vertex position")?;
        if attributes.has(ATTR_POSITION4) {
            let _ = finite_f32(&mut r, "vertex position w")?;
        }
        let normal = if attributes.has(ATTR_NORMAL) {
            read_vec3(&mut r, "vertex normal")?
        } else {
            [0.0, 0.0, 1.0]
        };
        let tangent = if attributes.has(ATTR_TANGENT) {
            read_vec4(&mut r, "vertex tangent")?
        } else {
            [1.0, 0.0, 0.0, 1.0]
        };

        let mut bone_indices = [0u16; 4];
        let mut bone_weights = [1.0, 0.0, 0.0, 0.0];
        if attributes.skinned() {
            for bone in &mut bone_indices {
                let at = r.pos;
                let value = r.u32()?;
                *bone = u16::try_from(value).map_err(|_| {
                    bad(format!(
                        "bone index {value} at 0x{at:x} does not fit in u16"
                    ))
                })?;
            }
            for weight in &mut bone_weights {
                let at = r.pos;
                let value = finite_f32(&mut r, "bone weight")?;
                if value < 0.0 {
                    return Err(bad(format!("negative bone weight {value} at 0x{at:x}")));
                }
                *weight = value;
            }
        }

        let mut uv = if attributes.has(ATTR_UV) {
            read_vec2(&mut r, "vertex uv")?
        } else {
            [0.0, 0.0]
        };
        if attributes.has(ATTR_UV_PAIR) {
            let pair = read_vec4(&mut r, "vertex uv pair")?;
            if !attributes.has(ATTR_UV) {
                uv = [pair[0], pair[1]];
            }
        }
        vertices.push(Vertex {
            position,
            normal,
            tangent,
            bone_indices,
            bone_weights,
            uv,
        });
    }

    let index_bytes = r.u32()? as usize;
    if !index_bytes.is_multiple_of(2) {
        return Err(bad(format!(
            "index byte count {index_bytes} is not a multiple of 2"
        )));
    }
    let index_count = index_bytes / 2;
    if index_count > MAX_INDICES {
        return Err(bad(format!("index count {index_count} is too large")));
    }

    let raw = r.bytes(index_bytes)?;
    let mut indices = Vec::with_capacity(index_count);
    for (i, bytes) in raw.as_chunks::<2>().0.iter().enumerate() {
        let index = u16::from_le_bytes([bytes[0], bytes[1]]);
        if usize::from(index) >= vertex_count {
            return Err(bad(format!(
                "index {i} points at vertex {index}, but the mesh has {vertex_count} vertices"
            )));
        }
        indices.push(index);
    }

    Ok(Mesh {
        material,
        vertices,
        indices,
        end: r.pos,
        skinned: attributes.skinned(),
    })
}

fn parse_skeleton(data: &[u8], off: usize) -> Result<(Vec<Bone>, usize), Error> {
    let mut r = Reader::new(data);
    r.pos = off;
    read_chunk(&mut r, SKELETON_KIND, true)?;

    let next = r.u32()? as usize;
    if next <= off || next > data.len() {
        return Err(bad(format!(
            "skeleton at 0x{off:x} has an out-of-range next offset 0x{next:x}"
        )));
    }

    let bone_count = r.u32()? as usize;
    if bone_count > MAX_BONES {
        return Err(bad(format!("bone count {bone_count} is too large")));
    }

    let pad_at = r.pos;
    if r.bytes(1)?[0] != 0 {
        return Err(bad(format!("skeleton padding at 0x{pad_at:x} is not 0")));
    }

    let mut bones = Vec::with_capacity(bone_count);
    for index in 0..bone_count {
        let bone_at = r.pos;
        let flags = r.u32()?;
        let parent_raw = r.u32()?;
        let parent = if parent_raw == u32::MAX {
            None
        } else {
            let parent = parent_raw as usize;
            if parent >= index {
                return Err(bad(format!(
                    "bone {index} at 0x{bone_at:x} has parent {parent}, which is not earlier"
                )));
            }
            Some(parent)
        };

        let matrix_bytes = r.u32()? as usize;
        if matrix_bytes != 64 {
            return Err(bad(format!(
                "bone {index} at 0x{bone_at:x} has matrix size {matrix_bytes}, expected 64"
            )));
        }
        let local = read_matrix(&mut r)?;

        let metadata = if r.data.get(r.pos) == Some(&b'{') {
            let bytes = cstring(&mut r, MAX_STRING, "bone metadata")?;
            let text = String::from_utf8_lossy(bytes).into_owned();
            read_zeros(&mut r, 1, "after bone metadata")?;
            Some(text)
        } else {
            read_zeros(&mut r, 2, "after a bone without metadata")?;
            None
        };

        if r.pos > next {
            return Err(bad(format!(
                "bone {index} at 0x{bone_at:x} runs past the skeleton end at 0x{next:x}"
            )));
        }
        bones.push(Bone {
            flags,
            parent,
            local,
            metadata,
        });
    }

    Ok((bones, next))
}

fn parse_attachments(data: &[u8], off: usize) -> Result<(Vec<Attachment>, usize), Error> {
    let mut r = Reader::new(data);
    r.pos = off;
    read_chunk(&mut r, ATTACHMENT_KIND, true)?;

    let next = r.u32()? as usize;
    if next <= off || next > data.len() {
        return Err(bad(format!(
            "attachments at 0x{off:x} have an out-of-range next offset 0x{next:x}"
        )));
    }

    let count = usize::from(read_u16(&mut r)?);
    if count > MAX_ATTACHMENTS {
        return Err(bad(format!("attachment count {count} is too large")));
    }

    let mut attachments = Vec::with_capacity(count);
    for index in 0..count {
        let declared = usize::from(read_u16(&mut r)?);

        let name_at = r.pos;
        let rest = data
            .get(name_at..)
            .ok_or_else(|| bad(format!("truncated attachment {index} name")))?;
        let limit = MAX_STRING;
        let length = rest
            .iter()
            .take(limit)
            .position(|&b| b == 0)
            .ok_or_else(|| {
                bad(format!(
                    "unterminated attachment {index} name at 0x{name_at:x}"
                ))
            })?;
        let name = String::from_utf8_lossy(&rest[..length]).into_owned();
        r.pos = name_at + length + 1;

        let matrix = read_matrix(&mut r)?;
        if r.pos > next {
            return Err(bad(format!(
                "attachment {index} at 0x{name_at:x} runs past the attachment end at 0x{next:x}"
            )));
        }
        attachments.push(Attachment { bone: declared, name, matrix });
    }

    Ok((attachments, next))
}

fn parse_animations(
    data: &[u8],
    off: usize,
    bone_count: usize,
) -> Result<(Vec<Animation>, u32, usize), Error> {
    let mut r = Reader::new(data);
    r.pos = off;
    read_chunk(&mut r, ANIMATION_KIND, true)?;

    let next = r.u32()? as usize;
    if next <= off || next > data.len() {
        return Err(bad(format!(
            "animations at 0x{off:x} have an out-of-range next offset 0x{next:x}"
        )));
    }

    let count = r.u32()? as usize;
    if count > MAX_ANIMATIONS {
        return Err(bad(format!("animation count {count} is too large")));
    }
    let first_id = r.u32()?;
    let reserved_at = r.pos;
    if r.u32()? != 0 {
        return Err(bad(format!(
            "animation header padding at 0x{reserved_at:x} is not 0"
        )));
    }

    let mut animations = Vec::with_capacity(count);
    let mut cursor = r.pos;
    for index in 0..count {
        // What lies between two animation records differs between files (a fixed 39-byte block in
        // some, extra curve data in others), so the next record is the first position after the
        // previous one at which a whole animation parses.
        let raw = if index == 0 {
            parse_animation_at(data, cursor, bone_count)?
        } else {
            let stop = next.min(data.len());
            (cursor..stop)
                .find_map(|at| parse_animation_at(data, at, bone_count).ok())
                .ok_or_else(|| {
                    bad(format!(
                        "no animation {index} record after 0x{cursor:x} in the chunk ending at 0x{next:x}"
                    ))
                })?
        };

        let id = raw.id;
        cursor = raw.end;
        if cursor > next {
            return Err(bad(format!(
                "animation {index} ends at 0x{cursor:x}, past the animation chunk end at 0x{next:x}"
            )));
        }
        animations.push(Animation {
            id,
            name: raw.name,
            flag: raw.flag,
            fps: raw.fps,
            duration_frames: raw.duration_frames,
            tracks: raw.tracks,
        });
    }

    Ok((animations, first_id, next))
}

struct RawAnimation {
    /// The id the scene's animation layers refer to, stored just before the name.
    id: u32,
    name: String,
    flag: String,
    fps: f32,
    duration_frames: u32,
    tracks: Vec<Track>,
    end: usize,
}

/// Parses one animation record starting at `at`: name, play mode, fps, frame count and one track
/// per bone. The header is checked tightly (a readable name, a known play mode, a sane fps and one
/// track per bone) so a wrong position is rejected at once.
fn parse_animation_at(data: &[u8], at: usize, bone_count: usize) -> Result<RawAnimation, Error> {
    // Each record starts with its id and a zero word, then the name. The ids are not a simple
    // sequence (`122, 391, 704` in one file), so the stored one is what the scene refers to.
    let id = at
        .checked_sub(8)
        .and_then(|p| u32_at(data, p))
        .filter(|_| at.checked_sub(4).and_then(|p| u32_at(data, p)) == Some(0))
        .ok_or_else(|| bad(format!("no animation id before 0x{at:x}")))?;
    let mut r = Reader::new(data);
    r.pos = at;
    let name_bytes = cstring(&mut r, 256, "animation name")?;
    let flag_bytes = cstring(&mut r, 16, "animation flag")?;
    if name_bytes.is_empty()
        || name_bytes.iter().any(|b| b.is_ascii_control())
        || !matches!(flag_bytes, b"loop" | b"mirror" | b"single")
    {
        return Err(bad(format!("no animation header at 0x{at:x}")));
    }
    let name = String::from_utf8_lossy(name_bytes).into_owned();
    let flag = String::from_utf8_lossy(flag_bytes).into_owned();

    let fps = finite_f32(&mut r, "animation fps")?;
    if !(0.0..=1000.0).contains(&fps) || fps == 0.0 {
        return Err(bad(format!("animation at 0x{at:x} has invalid fps {fps}")));
    }

    let duration_frames = r.u32()?;
    if r.u32()? != 0 {
        return Err(bad(format!("animation at 0x{at:x}: padding is not 0")));
    }
    let track_count = r.u32()? as usize;
    if track_count != bone_count {
        return Err(bad(format!(
            "animation at 0x{at:x} has {track_count} tracks, but the skeleton has {bone_count} bones"
        )));
    }
    if r.u32()? != 0 {
        return Err(bad(format!("animation at 0x{at:x}: padding is not 0")));
    }

    let first_track_bytes = r.u32()? as usize;
    let mut tracks = Vec::with_capacity(track_count);
    for track_index in 0..track_count {
        let size = if track_index == 0 {
            first_track_bytes
        } else {
            let at = r.pos;
            let size = r.u32()? as usize;
            if size == 0 {
                return Err(bad(format!(
                    "animation track {track_index} at 0x{at:x} has size 0"
                )));
            }
            size
        };
        let frame_count = keyframe_count(size, "track")?;

        let mut keyframes = Vec::with_capacity(frame_count);
        for _ in 0..frame_count {
            keyframes.push(read_transform(&mut r)?);
        }

        let pad_at = r.pos;
        if r.u32()? != 0 {
            return Err(bad(format!(
                "animation track {track_index} padding at 0x{pad_at:x} is not 0"
            )));
        }
        tracks.push(Track {
            bone: track_index,
            keyframes,
        });
    }

    Ok(RawAnimation {
        id,
        name,
        flag,
        fps,
        duration_frames,
        tracks,
        end: r.pos,
    })
}

fn find_segments(
    data: &[u8],
    from: usize,
    to: usize,
    bone_count: usize,
    index_count: usize,
) -> Vec<Segment> {
    if index_count == 0 || bone_count == 0 {
        return Vec::new();
    }

    let mut best: Option<Vec<Segment>> = None;
    let Some(last_start) = to.checked_sub(12) else {
        return Vec::new();
    };
    for start in from..=last_start {
        if let Some(segments) = try_segments(data, start, to, bone_count, index_count) {
            if best
                .as_ref()
                .is_none_or(|current| segments.len() > current.len())
            {
                best = Some(segments);
            }
        }
    }
    best.unwrap_or_default()
}

fn try_segments(
    data: &[u8],
    start: usize,
    end: usize,
    bone_count: usize,
    index_count: usize,
) -> Option<Vec<Segment>> {
    let mut pos = start;
    let mut expected = 0usize;
    let mut segments = Vec::new();

    loop {
        if expected == index_count && pos == end {
            return Some(segments);
        }

        let remaining = end.checked_sub(pos)?;
        if remaining < 12 {
            return None;
        }

        let first = u32_at(data, pos)? as usize;
        let count = u32_at(data, pos + 4)? as usize;
        let bone = u32_at(data, pos + 8)? as usize;

        if first != expected || bone >= bone_count || expected > index_count {
            return None;
        }
        if count > index_count - expected {
            return None;
        }

        if remaining >= 16 {
            if u32_at(data, pos + 12)? != 0 {
                return None;
            }
            pos += 16;
        } else if remaining == 12 {
            pos += 12;
        } else {
            return None;
        }

        if count == 0 {
            return (first == index_count && pos == end).then_some(segments);
        }

        expected += count;
        segments.push(Segment {
            first_index: first as u32,
            index_count: count as u32,
            bone: bone as u32,
        });
        if segments.len() > bone_count + 1 {
            return None;
        }
    }
}

fn keyframe_count(bytes: usize, what: &str) -> Result<usize, Error> {
    if bytes == 0 || !bytes.is_multiple_of(KEYFRAME_SIZE) {
        return Err(bad(format!(
            "{what} byte count {bytes} is not a positive multiple of {KEYFRAME_SIZE}"
        )));
    }
    let count = bytes / KEYFRAME_SIZE;
    if count > MAX_FRAMES {
        return Err(bad(format!("{what} has too many keyframes ({count})")));
    }
    Ok(count)
}

fn read_transform(r: &mut Reader<'_>) -> Result<Transform, Error> {
    let mut values = [0.0f32; 9];
    for value in &mut values {
        *value = finite_f32(r, "keyframe value")?;
    }
    Ok(Transform {
        translation: [values[0], values[1], values[2]],
        rotation: [values[3], values[4], values[5]],
        scale: [values[6], values[7], values[8]],
    })
}

fn read_matrix(r: &mut Reader<'_>) -> Result<[[f32; 4]; 4], Error> {
    let mut matrix = [[0.0f32; 4]; 4];
    for row in &mut matrix {
        for value in row {
            *value = finite_f32(r, "matrix value")?;
        }
    }
    Ok(matrix)
}

pub(crate) fn read_vec2(r: &mut Reader<'_>, what: &str) -> Result<[f32; 2], Error> {
    let mut values = [0.0f32; 2];
    for value in &mut values {
        *value = finite_f32(r, what)?;
    }
    Ok(values)
}

pub(crate) fn read_vec3(r: &mut Reader<'_>, what: &str) -> Result<[f32; 3], Error> {
    let mut values = [0.0f32; 3];
    for value in &mut values {
        *value = finite_f32(r, what)?;
    }
    Ok(values)
}

pub(crate) fn read_vec4(r: &mut Reader<'_>, what: &str) -> Result<[f32; 4], Error> {
    let mut values = [0.0f32; 4];
    for value in &mut values {
        *value = finite_f32(r, what)?;
    }
    Ok(values)
}

fn lerp3(a: [f32; 3], b: [f32; 3], t: f32) -> [f32; 3] {
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    ]
}

pub(crate) fn finite_f32(r: &mut Reader<'_>, what: &str) -> Result<f32, Error> {
    let at = r.pos;
    let value = r.f32()?;
    if !value.is_finite() {
        return Err(bad(format!("non-finite {what} at 0x{at:x}")));
    }
    Ok(value)
}

fn read_u16(r: &mut Reader<'_>) -> Result<u16, Error> {
    let bytes = r.bytes(2)?;
    Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
}

pub(crate) fn cstring<'a>(r: &mut Reader<'a>, max: usize, what: &str) -> Result<&'a [u8], Error> {
    let start = r.pos;
    let rest = r
        .data
        .get(start..)
        .ok_or_else(|| bad(format!("truncated {what} at 0x{start:x}")))?;
    let length = rest
        .iter()
        .take(max)
        .position(|&b| b == 0)
        .ok_or_else(|| bad(format!("unterminated {what} at 0x{start:x}")))?;
    r.pos = start + length + 1;
    Ok(&rest[..length])
}

fn read_zeros(r: &mut Reader<'_>, count: usize, what: &str) -> Result<(), Error> {
    let at = r.pos;
    let bytes = r.bytes(count)?;
    if bytes.iter().any(|&b| b != 0) {
        return Err(bad(format!(
            "expected {count} zero bytes {what} at 0x{at:x}"
        )));
    }
    Ok(())
}

/// Whether `data[off..]` starts a chunk of this kind: four letters and a four-digit version.
fn chunk_at(data: &[u8], off: usize, kind: &[u8; 4]) -> bool {
    data.get(off..off + 8).is_some_and(|tag| {
        tag.starts_with(kind) && tag[4..].iter().all(u8::is_ascii_digit)
    })
}

/// Reads a chunk tag of any version of `kind`. `nul` says the tag is followed by a 0 byte.
pub(crate) fn read_chunk(r: &mut Reader<'_>, kind: &[u8; 4], nul: bool) -> Result<(), Error> {
    let at = r.pos;
    let tag = r.bytes(8)?;
    if !(tag.starts_with(kind) && tag[4..].iter().all(u8::is_ascii_digit)) {
        return Err(Error::Unsupported(format!(
            "model: expected a {} chunk at 0x{at:x}, found {}",
            String::from_utf8_lossy(kind),
            String::from_utf8_lossy(tag)
        )));
    }
    if nul && r.bytes(1)?[0] != 0 {
        return Err(bad(format!("chunk tag at 0x{at:x} is not followed by NUL")));
    }
    Ok(())
}

fn find_chunk(data: &[u8], from: usize, kind: &[u8; 4]) -> Option<usize> {
    (from..data.len()).find(|&off| chunk_at(data, off, kind))
}

fn u32_at(data: &[u8], pos: usize) -> Option<u32> {
    let bytes = data.get(pos..pos.checked_add(4)?)?;
    Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

pub(crate) fn bad(message: impl Into<String>) -> Error {
    Error::Format(format!("model: {}", message.into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn push_u16(buf: &mut Vec<u8>, value: u16) {
        buf.extend_from_slice(&value.to_le_bytes());
    }

    fn push_u32(buf: &mut Vec<u8>, value: u32) {
        buf.extend_from_slice(&value.to_le_bytes());
    }

    fn push_f32(buf: &mut Vec<u8>, value: f32) {
        buf.extend_from_slice(&value.to_le_bytes());
    }

    fn push_matrix(buf: &mut Vec<u8>, translation: [f32; 2]) {
        for value in [
            1.0,
            0.0,
            0.0,
            0.0, //
            0.0,
            1.0,
            0.0,
            0.0, //
            0.0,
            0.0,
            1.0,
            0.0, //
            translation[0],
            translation[1],
            0.0,
            1.0,
        ] {
            push_f32(buf, value);
        }
    }

    /// One vertex, one triangle, one bone and one two-frame animation. `third_index` lets a test
    /// put an out-of-range value in the index buffer.
    fn build_minimal(third_index: u16) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(b"MDLV0023");
        push_u32(&mut buf, 0x8000_0900);
        push_u32(&mut buf, 0x0000_0101);
        push_u32(&mut buf, 0x0000_0100);
        buf.push(0);
        buf.extend_from_slice(b"materials/test.json\0");
        buf.extend_from_slice(&[0u8; 28]);
        push_u32(&mut buf, 0x0180_000f);
        push_u32(&mut buf, (3 * 80) as u32);

        for _ in 0..3 {
            for value in [0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0] {
                push_f32(&mut buf, value);
            }
            for _ in 0..4 {
                push_u32(&mut buf, 0);
            }
            for value in [1.0, 0.0, 0.0, 0.0, 0.0, 0.0] {
                push_f32(&mut buf, value);
            }
        }

        push_u32(&mut buf, 6);
        push_u16(&mut buf, 0);
        push_u16(&mut buf, 1);
        push_u16(&mut buf, third_index);

        push_u32(&mut buf, 0);
        push_u32(&mut buf, 3);
        push_u32(&mut buf, 0);
        push_u32(&mut buf, 0);

        let skeleton_at = buf.len();
        buf.extend_from_slice(b"MDLS0004\0");
        push_u32(&mut buf, 0);
        push_u32(&mut buf, 1);
        buf.push(0);
        push_u32(&mut buf, 1);
        push_u32(&mut buf, u32::MAX);
        push_u32(&mut buf, 64);
        push_matrix(&mut buf, [0.0, 0.0]);
        buf.extend_from_slice(&[0u8; 2]);

        let animation_at = buf.len();
        buf.extend_from_slice(b"MDLA0006\0");
        push_u32(&mut buf, 0);
        push_u32(&mut buf, 1);
        push_u32(&mut buf, 100);
        push_u32(&mut buf, 0);
        buf.extend_from_slice(b"Animation 1\0");
        buf.extend_from_slice(b"loop\0");
        push_f32(&mut buf, 30.0);
        push_u32(&mut buf, 1);
        push_u32(&mut buf, 0);
        push_u32(&mut buf, 1);
        push_u32(&mut buf, 0);
        push_u32(&mut buf, (2 * KEYFRAME_SIZE) as u32);
        for frame in 0..2 {
            for value in [0.0, 0.0, 0.0, 0.0, 0.0, frame as f32 * 0.1, 1.0, 1.0, 1.0] {
                push_f32(&mut buf, value);
            }
        }
        push_u32(&mut buf, 0);

        let cursor_after = buf.len();
        buf.extend_from_slice(&[0u8; 32]);

        buf[skeleton_at + 9..skeleton_at + 13]
            .copy_from_slice(&(animation_at as u32).to_le_bytes());
        buf[animation_at + 9..animation_at + 13]
            .copy_from_slice(&((cursor_after + 31) as u32).to_le_bytes());
        buf
    }

    #[test]
    fn parses_a_minimal_model() {
        let model = Puppet::parse(&build_minimal(2)).expect("minimal model should parse");
        assert_eq!(model.material, "materials/test.json");
        assert_eq!(model.vertices.len(), 3);
        assert_eq!(model.indices, vec![0, 1, 2]);
        assert_eq!(model.segments.len(), 1);
        assert_eq!(
            model.segments[0],
            Segment {
                first_index: 0,
                index_count: 3,
                bone: 0
            }
        );
        assert_eq!(model.bones.len(), 1);
        assert_eq!(model.bones[0].parent, None);
        assert_eq!(model.attachments.len(), 0);
        assert_eq!(model.animations.len(), 1);
        assert_eq!(model.first_animation_id, 100);
        assert_eq!(model.animations[0].id, 100);
        assert_eq!(model.animations[0].tracks.len(), 1);
        assert_eq!(model.animations[0].tracks[0].keyframes.len(), 2);
    }

    #[test]
    fn rejects_an_out_of_range_index() {
        let error = Puppet::parse(&build_minimal(5)).expect_err("index 5 is out of range");
        assert!(matches!(error, Error::Format(_)));
    }

    #[test]
    fn rejects_a_bad_mesh_tag() {
        let mut data = build_minimal(2);
        data[0] = b'X';
        let error = Puppet::parse(&data).expect_err("bad tag should fail");
        assert!(matches!(error, Error::Unsupported(_)));
    }

    #[test]
    fn rejects_truncated_input() {
        let data = build_minimal(2);
        for length in [0, 8, 20, data.len() / 2, data.len() - 40] {
            assert!(
                Puppet::parse(&data[..length]).is_err(),
                "truncating to {length} bytes should fail"
            );
        }
    }

    #[test]
    fn finds_segments_after_unknown_bytes_and_a_sentinel() {
        let mut data = vec![0xaa; 14];
        push_u32(&mut data, 0);
        push_u32(&mut data, 1);
        push_u32(&mut data, 0);
        push_u32(&mut data, 0);
        push_u32(&mut data, 1);
        push_u32(&mut data, 0);
        push_u32(&mut data, 0);
        push_u32(&mut data, 0);

        let segments = find_segments(&data, 0, data.len(), 1, 1);
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].first_index, 0);
        assert_eq!(segments[0].index_count, 1);
    }

    #[test]
    fn samples_a_track() {
        let track = Track {
            bone: 0,
            keyframes: vec![
                Transform {
                    translation: [0.0, 0.0, 0.0],
                    rotation: [0.0, 0.0, 0.0],
                    scale: [1.0, 1.0, 1.0],
                },
                Transform {
                    translation: [10.0, 0.0, 0.0],
                    rotation: [0.0, 0.0, 1.0],
                    scale: [1.0, 1.0, 1.0],
                },
            ],
        };

        let middle = track.sample(0.5);
        assert!((middle.translation[0] - 5.0).abs() < 1e-6);
        assert!((middle.rotation[2] - 0.5).abs() < 1e-6);
        assert!((track.sample(99.0).translation[0] - 10.0).abs() < 1e-6);
    }

    fn library() -> Option<std::path::PathBuf> {
        let home = std::env::var("HOME").ok()?;
        Some(std::path::Path::new(&home).join("Library/Application Support/LiveWallpaper/Library"))
    }

    #[test]
    #[ignore = "needs the local scene library"]
    fn parses_the_local_angel_puppets() {
        let Some(library) = library() else {
            return;
        };
        let package = library.join("3695791724/scene.pkg");
        if !package.exists() {
            eprintln!("skipping: {} does not exist", package.display());
            return;
        }
        let package = crate::vfs::Pkg::open(&package).expect("open angel package");

        let data = package
            .get("models/angelcommison_puppet.mdl")
            .expect("commison model");
        let model = Puppet::parse(&data).expect("parse commison model");
        assert_eq!(model.material, "materials/angelcommison.json");
        assert_eq!(model.vertices.len(), 834);
        assert_eq!(model.indices.len(), 4002);
        assert_eq!(model.bones.len(), 13);
        assert_eq!(model.attachments.len(), 2);
        assert_eq!(model.segments.len(), 12);
        assert_eq!(model.first_animation_id, 61);
        assert_eq!(
            model
                .animations
                .iter()
                .map(|animation| animation.id)
                .collect::<Vec<_>>(),
            vec![61, 63, 65, 67]
        );
        assert_eq!(model.animations[0].duration_frames, 180);
        assert_eq!(model.animations[0].frame_count(), 181);
        assert_eq!(model.animations[0].tracks.len(), 13);
        assert!((model.animations[0].fps - 30.0).abs() < f32::EPSILON);

        let first = model.vertices[0].position;
        assert!((first[0] - 590.1467).abs() < 0.01);
        assert!((first[1] + 287.8162).abs() < 0.01);
        assert!(first[2].abs() < 0.01);

        let root = model.bones[0].local[3];
        assert!((root[0] - 176.7316).abs() < 0.01);
        assert!((root[1] + 1307.0382).abs() < 0.01);

        let blind = model
            .attachments
            .iter()
            .find(|attachment| attachment.name == "blindofld")
            .expect("blindofld attachment");
        assert!((blind.matrix[3][0] - 18.3333).abs() < 0.01);
        assert!((blind.matrix[3][1] + 61.1111).abs() < 0.01);
        let hair = model
            .attachments
            .iter()
            .find(|attachment| attachment.name == "hair")
            .expect("hair attachment");
        assert!((hair.matrix[3][0] + 33.5532).abs() < 0.01);
        assert!((hair.matrix[3][1] + 110.206).abs() < 0.01);

        let data = package
            .get("models/angelhair_puppet.mdl")
            .expect("hair model");
        let model = Puppet::parse(&data).expect("parse hair model");
        assert_eq!(model.vertices.len(), 223);
        assert_eq!(model.indices.len(), 1185);
        assert_eq!(model.bones.len(), 5);
        assert_eq!(model.attachments.len(), 0);
        assert_eq!(model.animations.len(), 1);
        assert_eq!(model.animations[0].id, 87);
        assert_eq!(model.animations[0].duration_frames, 150);
        assert_eq!(model.animations[0].frame_count(), 151);
        assert_eq!(model.animations[0].tracks.len(), 5);
    }

    #[test]
    #[ignore = "needs the local scene library"]
    fn parses_the_local_hand_and_finger_puppets() {
        let Some(library) = library() else {
            return;
        };
        let package = library.join("3612198967/scene.pkg");
        if !package.exists() {
            eprintln!("skipping: {} does not exist", package.display());
            return;
        }
        let package = crate::vfs::Pkg::open(&package).expect("open hand package");

        let data = package
            .get("models/Right Hand_puppet.mdl")
            .expect("right hand model");
        let model = Puppet::parse(&data).expect("parse right hand model");
        assert_eq!(model.bones.len(), 4);
        assert_eq!(
            model
                .animations
                .iter()
                .map(|animation| animation.id)
                .collect::<Vec<_>>(),
            vec![189, 191]
        );
        assert_eq!(model.animations[0].frame_count(), 61);
        assert_eq!(model.animations[1].frame_count(), 121);

        let data = package
            .get("models/Finger Left_puppet.mdl")
            .expect("finger model");
        let model = Puppet::parse(&data).expect("parse finger model");
        assert_eq!(model.bones.len(), 3);
        assert_eq!(model.animations.len(), 1);
        assert_eq!(model.animations[0].id, 346);
        assert_eq!(model.animations[0].frame_count(), 61);
    }

    #[test]
    #[ignore = "needs the local scene library"]
    fn parses_the_local_v19_puppets() {
        let Some(library) = library() else {
            return;
        };
        let package = library.join("3233141951/scene.pkg");
        if !package.exists() {
            eprintln!("skipping: {} does not exist", package.display());
            return;
        }
        let package = crate::vfs::Pkg::open(&package).expect("open Red Warbler package");
        let data = package.get("models/刀_puppet.mdl").expect("katana model");
        let model = Puppet::parse(&data).expect("parse MDLV0019 katana");
        assert_eq!(model.bones.len(), 1);
        assert_eq!(model.animations[0].id, 673);
        assert_eq!(model.animations[0].frame_count(), 901);
        let data = package.get("models/朱鹤_puppet.mdl").expect("crane model");
        assert_eq!(Puppet::parse(&data).expect("parse MDLV0019 crane").bones.len(), 9);
    }

    #[test]
    fn an_unskinned_mesh_gets_one_identity_bone() {
        let mut data = Vec::new();
        data.extend_from_slice(b"MDLV0021");
        for word in [0x900u32, 0x100, 0x100] {
            push_u32(&mut data, word);
        }
        data.push(0);
        data.extend_from_slice(b"materials/m.json\0");
        data.extend_from_slice(&[0; 28]);
        push_u32(&mut data, 0xf);
        push_u32(&mut data, (3 * 48) as u32);
        for i in 0..3 {
            for value in [i as f32, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.5, 0.5] {
                push_f32(&mut data, value);
            }
        }
        push_u32(&mut data, 6);
        for index in [0u16, 1, 2] {
            push_u16(&mut data, index);
        }
        let model = Puppet::parse(&data).expect("parse static mesh");
        assert_eq!(model.vertices.len(), 3);
        assert_eq!(model.bones.len(), 1);
        assert_eq!(model.vertices[2].bone_weights, [1.0, 0.0, 0.0, 0.0]);
        assert!(model.animations.is_empty());
    }

    #[test]
    fn an_unseen_mesh_version_uses_the_matching_layout() {
        let mut data = Vec::new();
        data.extend_from_slice(b"MDLV0099");
        for word in [0x900u32, 0x100, 0x100] {
            push_u32(&mut data, word);
        }
        data.push(0);
        data.extend_from_slice(b"materials/m.json\0");
        data.extend_from_slice(&[0; 28]);
        push_u32(&mut data, 0xf);
        push_u32(&mut data, (3 * 48) as u32);
        for i in 0..3 {
            for value in [i as f32, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.5, 0.5] {
                push_f32(&mut data, value);
            }
        }
        push_u32(&mut data, 6);
        for index in [0u16, 1, 2] {
            push_u16(&mut data, index);
        }
        let model = Puppet::parse(&data).expect("parse static mesh");
        assert_eq!(model.vertices.len(), 3);
        assert_eq!(model.bones.len(), 1);
        assert_eq!(model.vertices[2].bone_weights, [1.0, 0.0, 0.0, 0.0]);
        assert!(model.animations.is_empty());
    }

    fn mesh_with_flags(flags: u32, stride: usize, vertices: usize) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(b"MDLV0023");
        for word in [0x900u32, 0x100, 0x100] {
            push_u32(&mut data, word);
        }
        data.push(0);
        data.extend_from_slice(b"materials/m.json\0");
        data.extend_from_slice(&[0; 28]);
        push_u32(&mut data, flags);
        push_u32(&mut data, (vertices * stride) as u32);
        data.extend(std::iter::repeat_n(0u8, vertices * stride));
        push_u32(&mut data, 6);
        for index in [0u16, 1, 2] {
            push_u16(&mut data, index);
        }
        data
    }

    #[test]
    fn the_attribute_mask_decides_the_vertex_stride() {
        // Unskinned, 4-float position (84 - 32 skin bytes = 52 here: no bones or weights).
        let data = mesh_with_flags(ATTR_POSITION4 | ATTR_NORMAL | ATTR_TANGENT | ATTR_UV, 52, 3);
        let model = Puppet::parse(&data).expect("parse mask-described mesh");
        assert_eq!(model.vertices.len(), 3);
        assert!(model.animations.is_empty());
    }

    #[test]
    fn unknown_attribute_bits_are_reported() {
        let data = mesh_with_flags(0x0000_000f | 1 << 6, 48, 3);
        let err = Puppet::parse(&data).expect_err("unknown flags");
        assert!(matches!(err, Error::Unsupported(_)), "{err}");
    }

    #[test]
    fn the_uv_pair_gives_the_first_uv() {
        // Position, normal, tangent and two uv sets: 56 bytes, the static `arsenal` layout.
        let data = mesh_with_flags(ATTR_POSITION | ATTR_NORMAL | ATTR_TANGENT | ATTR_UV_PAIR, 56, 3);
        let model = Puppet::parse(&data).expect("parse a mesh with a uv pair");
        assert_eq!(model.vertices.len(), 3);
    }
}
