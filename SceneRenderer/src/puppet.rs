//! Wallpaper Engine puppet models (`.mdl`): a mesh, a skeleton and the animations that move it.
//!
//! # Layout
//!
//! All integers are little-endian and offsets are absolute in the file. This is the layout
//! Wallpaper Engine's model reader walks (`FUN_140261880`, see `NOTES.md`). A chunk tag is four
//! letters, a four-digit version and a NUL; the version gates optional fields.
//!
//! ## Mesh (`MDLV`, version `v`)
//!
//! ```text
//! tag, u32 flags, u32 strings per mesh (1), u32 mesh count
//! per mesh:
//!   the strings; the first is the material path
//!   v >= 4: u32 mesh flags (see below); flag 2 adds a u32, the rows of the blend map
//!   v >= 17: six f32 bounds
//!   v > 14: u32 vertex attribute mask (see `Attributes`; older meshes use the header flags)
//!   u32 bytes + vertices, u32 bytes + u16 triangle indices
//!   v > 20: u8 flag [+ u32, u32 bytes, one vec3 per vertex: a second position set that only a
//!           lighting pass reads], u8 flag [+ u32 bytes of 16-byte index ranges:
//!           u32 bone, i32 draw-order offset, u32 first index, u32 index count]
//!   v > 22: u32 clipping groups: u64 id, mask texture path, u32 flags, u32 n + n target ranges,
//!           u32 m + m mask ranges
//! v > 12: chunks follow, each a tag and a u32 end offset: MDLS, MDAT, MDLA, MDMP, MDLE
//! ```
//!
//! Mesh flags: 2 a blend map, 4 bone alpha, 8 an animated draw order; 0x400, 0x800, 0x1000 and
//! 0x2000 say which data the morph targets carry. With a four-float position (attribute bit 16)
//! the fourth float is the vertex's morph index plus one, 0 for none.
//!
//! The ranges tile the index buffer, which is stored sorted by draw order (each range's bone's
//! rest order plus the range's offset), so drawing it as stored is in order until an animation
//! moves a bone in the draw order.
//!
//! ## Skeleton (`MDLS`, version `s`)
//!
//! ```text
//! u32 bone count; per bone: name, u32 flags (2: moved by inverse kinematics), u32 parent
//!   (0xffff_ffff = root), u32 64 + the local bind matrix, metadata (JSON physics settings)
//! s >= 2:
//!   u16 IK handles: name, u32 bone, u32 kind (0 target, 1 pole), 64-byte model-space matrix
//!   u8 flag [+ a rest matrix per bone, then per handle]
//!   u32 constraints: u32 owner bone, u32 weight curve, u32 target bone, s > 3: u32 flags,
//!     flags & 2: f32, f32
//!   u16 n: n × f32 (each bone's distance from its parent), then n × (u16 k, k × (u32 child,
//!     vec3 rest direction towards it))
//!   u16 chain groups: u32 root bone, u32 n + n handle indices, u16 m × (u32 bone, u16 k ×
//!     (u32 end bone, u32 flags, f32 max length, f32 min length, u16 c + c bones))
//!   u8 flag [+ per bone a vec3 and a matrix (editor picking)]
//!   u8 flag [+ per bone a u32 (the bones sorted by draw order)]
//!   s > 2: u8 flag [+ per bone the i32 rest draw order]
//! ```
//!
//! A bone matrix is row-vector style: rows 0..2 are direction, row 3 is translation.
//!
//! ## Attachments (`MDAT`)
//!
//! `u16 count`, then per attachment `u16 bone`, name, 64-byte matrix in the bone's space.
//!
//! ## Animations (`MDLA`, version `a`)
//!
//! ```text
//! u32 count; per animation:
//!   u64 id (what a scene's animation layers refer to), name, mode ("loop", "mirror", "single"),
//!   f32 fps, u32 frames, u32 flags, u32 tracks (one per bone)
//!   per bone: u32 flags (bit 0: excluded), u32 bytes, frames + 1 keyframes of 9 f32
//!     (translation, Euler rotation in radians, scale)
//!   a > 1: the same track per IK handle; a curve per constraint (its weight)
//!   a > 2: u32 n + n curves (blend map rows); u8 flag [+ a curve per bone: alpha]
//!   a >= 4: u8 flag [+ per mesh: u32 flags; flags & 1: u32, u16 k + k × (u16 target, curve)]
//!   a >= 5: six f32 bounds
//!   a >= 6: u8 flag [+ a curve per bone: draw order]
//!   flags & 1: u16 animation, 4 × u32
//!   u32 events: u32 frame, name
//! curve: u32 flags (bit 0: excluded), u32 bytes, frames + 1 f32
//! ```
//!
//! ## Morph targets (`MDMP`)
//!
//! Per mesh: `u16` target count; if any, `f32` delta scale and `u32` vertex count `V`, then per
//! target a `u64` id, name and `u32` bytes + `V` × 3 SNORM16 position deltas; mesh flag 0x400 and
//! 0x800 add two more such blobs (normal and tangent deltas), 0x1000 a blob of `V` SNORM16 alphas,
//! 0x2000 `u32 bone, u32 flags, f32 edge0, f32 edge1` (a bone that scales the target).
//!
//! `MDLE` holds one matrix per bone, which nothing at run time reads.

use crate::mat::M4;
use crate::vfs::Reader;
use crate::Error;

/// The vertex flags word of a mesh is an attribute mask. A vertex stores the attributes whose bit
/// is set, in this order: position, normal, tangent, bone indices, bone weights, uv, uv pair.
/// Sizes in bytes: position 12 (bit 0) or 16 (bit 16, the fourth float a morph index), normal 12
/// (bit 1), tangent 16 (bit 2), uv 8 (bit 3), uv pair 16 (bit 5: two texture coordinate sets, the
/// second for lightmaps), bone indices 16 (bit 23), bone weights 16 (bit 24).
/// Checked against all local puppet meshes (flags `0xf` = 48 bytes, `0x0180000f` = 80,
/// `0x0181000e` = 84) and the static models of the default 3D scenes (`0x9` = 20, `0xb` = 32,
/// `0x27` = 56 in `arsenal`, whose model JSON asks for a second uv channel).
pub(crate) const MESH_KIND: &[u8; 4] = b"MDLV";
const SKELETON_KIND: &[u8; 4] = b"MDLS";
const ATTACHMENT_KIND: &[u8; 4] = b"MDAT";
const ANIMATION_KIND: &[u8; 4] = b"MDLA";
const MORPH_KIND: &[u8; 4] = b"MDMP";

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

/// Mesh flag: the mesh has a blend map (a u32 row count follows the flags).
const MESH_BLEND_MAP: u32 = 2;
/// Mesh flag: animations fade bones (`Animation::alpha`).
pub const MESH_BONE_ALPHA: u32 = 4;
/// Mesh flag: animations move bones in the draw order (`Animation::orders`).
pub const MESH_DRAW_ORDER: u32 = 8;
/// Mesh flags for the extra blobs of each morph target: normal deltas, a second delta set, alphas
/// and a bone that scales the target.
const MORPH_NORMALS: u32 = 0x400;
const MORPH_SECOND: u32 = 0x800;
pub const MORPH_ALPHA: u32 = 0x1000;
const MORPH_BONE: u32 = 0x2000;

#[derive(Clone, Copy)]
pub(crate) struct Attributes(u32);

impl Attributes {
    pub(crate) fn from_flags(flags: u32) -> Result<Self, Error> {
        // Weights need indices; a blend map's mesh has indices alone (one per vertex, into the
        // blend values).
        if flags & !ATTR_KNOWN != 0
            || flags & (ATTR_POSITION | ATTR_POSITION4) == 0
            || flags & (ATTR_BONES | ATTR_WEIGHTS) == ATTR_WEIGHTS
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
        self.has(ATTR_BONES) && self.has(ATTR_WEIGHTS)
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
/// Wallpaper Engine refuses skeletons of more bones.
const MAX_BONES: usize = 128;
const MAX_ATTACHMENTS: usize = 4096;
const MAX_ANIMATIONS: usize = 4096;
const MAX_FRAMES: usize = 1_000_000;
const MAX_MESHES: usize = 256;

/// A parsed puppet model: its first mesh, the skeleton and its rig, attachments and animations.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Puppet {
    /// Material path from the mesh chunk, relative to the scene package.
    pub material: String,
    /// The mesh flags word (`MESH_*`, `MORPH_*`).
    pub mesh_flags: u32,
    /// Vertices in the order used by the index buffer.
    pub vertices: Vec<Vertex>,
    /// Triangle-list indices.
    pub indices: Vec<u16>,
    /// Per-bone index ranges from the block after the index buffer.
    pub segments: Vec<Segment>,
    /// Groups of ranges clipped by other ranges.
    pub clip_groups: Vec<ClipGroup>,
    /// Bones in parent-before-child order.
    pub bones: Vec<Bone>,
    /// Inverse kinematics handles, in file order.
    pub handles: Vec<Handle>,
    /// Rest matrices replacing the bones' and handles' own as the pose animations start from.
    pub rest: Option<(Vec<M4>, Vec<M4>)>,
    /// Constraints, in file order (bone constraints and the handles' own).
    pub constraints: Vec<Constraint>,
    /// Each bone's distance from its parent, and its rest directions towards its children.
    pub lengths: Vec<f32>,
    pub rest_directions: Vec<Vec<(usize, [f32; 3])>>,
    /// Inverse kinematics chain groups.
    pub chains: Vec<ChainGroup>,
    /// Each bone's draw order at rest; parts sort by it plus their offset.
    pub rest_orders: Vec<i32>,
    /// Morph targets of the mesh.
    pub morphs: Option<Morphs>,
    /// The mesh that composes the texture from channels, if any.
    pub blend_map: Option<BlendMap>,
    /// Named attachment matrices from `MDAT`.
    pub attachments: Vec<Attachment>,
    /// Animations in file order.
    pub animations: Vec<Animation>,
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
    /// The second texture coordinates of a vertex with a uv pair.
    pub uv2: [f32; 2],
    /// The fourth position float: where the vertex's morph deltas start, plus one (0: none).
    pub morph: u32,
}

/// One skeleton bone. `parent` indexes an earlier bone; roots have `None`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Bone {
    /// Name given in the editor; most bones have none.
    pub name: String,
    /// Bit 1 (2): inverse kinematics moves the bone.
    pub flags: u32,
    pub parent: Option<usize>,
    /// Local bind transform, row-vector style: row 3 is the translation.
    pub local: M4,
    /// Optional JSON editor metadata (physics settings), kept as text.
    pub metadata: Option<String>,
}

/// Bone flag: inverse kinematics moves the bone.
pub const BONE_IK: u32 = 2;

/// An inverse kinematics handle: the target (kind 0) or pole (kind 1) of the chain that ends at
/// `bone`, placed in model space.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Handle {
    pub name: String,
    pub bone: usize,
    pub kind: u32,
    pub matrix: M4,
}

/// A constraint: `owner` (a bone, or the target handle of the chain ending at it when the bone is
/// moved by inverse kinematics) follows `target` by the weight curve `weight`. A handle's flags
/// pick the kind: 1 copy position, 2 limit to a line, 0x10000 a rail; `values` feed the rail.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Constraint {
    pub owner: usize,
    pub weight: usize,
    pub target: usize,
    pub flags: u32,
    pub values: [f32; 2],
}

/// Chains solved together, run when the per-bone walk reaches `root`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChainGroup {
    pub root: usize,
    /// Handles whose constraints this group evaluates.
    pub handles: Vec<usize>,
    pub entries: Vec<ChainEntry>,
}

/// The chains that start at one bone.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChainEntry {
    pub bone: usize,
    pub chains: Vec<Chain>,
}

/// One chain, root first: `bones[0]` is the entry's bone, the last is `end`. Flag 1: a handle is
/// the target; 2: bend towards the pole even out of reach; 4: a rope.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Chain {
    pub end: usize,
    pub flags: u32,
    pub max_length: f32,
    pub min_length: f32,
    pub bones: Vec<usize>,
}

/// A blend map: a mesh drawn over the flat texture before the layer's effects, each vertex
/// taking a picture from a channel atlas by one of the animated blend values. Positions are flat
/// image pixels (top-left origin); `uv` addresses the atlas and `uv2` the plain image;
/// `bone_indices[0]` is the vertex's blend value.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct BlendMap {
    pub material: String,
    /// Rows of four blend values.
    pub rows: u32,
    pub vertices: Vec<Vertex>,
    pub indices: Vec<u16>,
}

/// Index ranges `targets` drawn only where the ranges `masks` cover.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ClipGroup {
    pub id: u64,
    /// A texture the masks are drawn through, if any.
    pub texture: String,
    /// 1: targets additive; 2: inverted mask; 4: masks hidden; 8: clip at the targets' position.
    pub flags: u32,
    pub targets: Vec<usize>,
    pub masks: Vec<usize>,
}

/// The morph targets of a mesh.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Morphs {
    /// Scale of the position deltas.
    pub scale: f32,
    /// Vertices per target.
    pub vertices: usize,
    pub targets: Vec<MorphTarget>,
}

/// One morph target: SNORM16 position deltas (3 per vertex) and alphas (1 per vertex, empty
/// without mesh flag `MORPH_ALPHA`), optionally scaled by a bone.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MorphTarget {
    pub id: u64,
    pub name: String,
    pub deltas: Vec<i16>,
    pub alphas: Vec<i16>,
    pub bone: Option<MorphBone>,
}

/// A bone that fades a morph target in by distance: `flags & 2` measures along its x axis,
/// otherwise in its xy plane, from `edges[0]` to `edges[1]`.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct MorphBone {
    pub bone: usize,
    pub flags: u32,
    pub edges: [f32; 2],
}

/// A named attachment matrix, referenced by a scene object's `attachment` field.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Attachment {
    /// The bone the attachment follows.
    pub bone: usize,
    pub name: String,
    /// Row-vector style: row 3 is the translation.
    pub matrix: M4,
}

/// A contiguous run of indices that belongs to one bone. `bone` indexes [`Puppet::bones`];
/// `order` is added to the bone's draw order to sort the run.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Segment {
    pub first_index: u32,
    pub index_count: u32,
    pub bone: u32,
    pub order: i32,
}

/// A keyframe: translation, Euler rotation in radians, and scale.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Transform {
    pub translation: [f32; 3],
    pub rotation: [f32; 3],
    pub scale: [f32; 3],
}

/// Keyframes for one bone or handle, in frame order.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Track {
    /// Index into [`Puppet::bones`] (or [`Puppet::handles`]).
    pub bone: usize,
    pub keyframes: Vec<Transform>,
    /// The animation leaves this bone to the layers below it (and leaves its alpha and draw order
    /// curves out too).
    pub excluded: bool,
}

/// One value per frame. An excluded curve leaves the value to the layers below.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Curve {
    pub values: Vec<f32>,
    pub excluded: bool,
}

/// One animation. `flag` is the play mode: `"loop"`, `"mirror"` or `"single"`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Animation {
    pub id: u32,
    pub name: String,
    pub flag: String,
    pub fps: f32,
    pub duration_frames: u32,
    pub tracks: Vec<Track>,
    /// One track per IK handle (empty when the skeleton has none).
    pub handle_tracks: Vec<Track>,
    /// One weight curve per constraint.
    pub constraint_curves: Vec<Curve>,
    /// One curve per blend map value.
    pub blend_map: Vec<Curve>,
    /// Per bone: its alpha (empty when the animation has none).
    pub alpha: Vec<Curve>,
    /// Morph target weights: target index and curve.
    pub morphs: Vec<(usize, Curve)>,
    /// Per bone: its draw order (empty when the animation has none).
    pub orders: Vec<Curve>,
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

impl Puppet {
    /// Parse a complete `.mdl` file: the mesh, then its chunks in whatever order they come.
    pub fn parse(data: &[u8]) -> Result<Self, Error> {
        let mut r = Reader::new(data);
        let (version, mesh, blend_map) = parse_mesh(&mut r)?;
        let meshes = mesh.count;
        if !mesh.attributes.skinned() {
            return Ok(Self::unskinned(mesh));
        }
        let mut puppet = Self {
            material: mesh.material,
            mesh_flags: mesh.flags,
            vertices: mesh.vertices,
            indices: mesh.indices,
            segments: mesh.segments,
            clip_groups: mesh.clip_groups,
            blend_map: blend_map.map(|m| BlendMap {
                material: m.material,
                rows: m.rows,
                vertices: m.vertices,
                indices: m.indices,
            }),
            ..Self::default()
        };
        let mut skeleton = false;
        while version > 12 && r.pos + 9 <= data.len() {
            let at = r.pos;
            let tag = r.bytes(9)?;
            if tag[8] != 0 || !tag[4..8].iter().all(u8::is_ascii_digit) {
                break;
            }
            let kind: [u8; 4] = [tag[0], tag[1], tag[2], tag[3]];
            let chunk_version = digits(&tag[4..8]);
            let end = r.u32()? as usize;
            if end <= at || end > data.len() {
                return Err(bad(format!("chunk at 0x{at:x} ends at 0x{end:x}, outside the file")));
            }
            let mut c = Reader::new(&data[..end]);
            c.pos = r.pos;
            match &kind {
                k if k == SKELETON_KIND => {
                    parse_skeleton(&mut c, chunk_version, &mut puppet)?;
                    skeleton = true;
                }
                k if k == ATTACHMENT_KIND => puppet.attachments = parse_attachments(&mut c, puppet.bones.len())?,
                k if k == ANIMATION_KIND => {
                    if !skeleton {
                        return Err(bad("animations come before the skeleton"));
                    }
                    puppet.animations = parse_animations(&mut c, chunk_version, &puppet, meshes)?;
                }
                k if k == MORPH_KIND => puppet.morphs = parse_morphs(&mut c, &puppet, meshes)?,
                _ => {}
            }
            r.pos = end;
        }
        if !skeleton {
            return Err(bad("no skeleton chunk (MDLS) after the mesh"));
        }
        puppet.check()?;
        Ok(puppet)
    }

    /// Every index the mesh, rig and animations hold points at something that exists.
    fn check(&mut self) -> Result<(), Error> {
        let bones = self.bones.len();
        for (vertex_index, vertex) in self.vertices.iter().enumerate() {
            if let Some(bone) = vertex.bone_indices.iter().find(|&&b| usize::from(b) >= bones) {
                return Err(bad(format!(
                    "vertex {vertex_index} references bone {bone}, but the skeleton has {bones} bones"
                )));
            }
        }
        // The ranges only order and clip the drawing: a table naming missing bones is left out.
        if self.segments.iter().any(|s| s.bone as usize >= bones) {
            self.segments.clear();
            self.clip_groups.clear();
        }
        let ranges = self.segments.len();
        self.clip_groups
            .retain(|g| g.targets.iter().chain(&g.masks).all(|&i| i < ranges));
        Ok(())
    }

    /// A mesh without a skeleton: one identity bone that every vertex follows fully.
    fn unskinned(mesh: Mesh) -> Self {
        let segments = vec![Segment {
            first_index: 0,
            index_count: mesh.indices.len() as u32,
            bone: 0,
            order: 0,
        }];
        Self {
            material: mesh.material,
            vertices: mesh.vertices,
            indices: mesh.indices,
            segments,
            bones: vec![Bone { local: crate::mat::IDENTITY, ..Bone::default() }],
            rest_orders: vec![0],
            ..Self::default()
        }
    }

    /// Bones that inverse kinematics moves without being the root of a chain group: animations
    /// leave them out and the walk leaves them to the solver.
    pub fn solver_driven(&self) -> Vec<bool> {
        let mut rooted = vec![false; self.bones.len()];
        for g in &self.chains {
            if let Some(r) = rooted.get_mut(g.root) {
                *r = true;
            }
        }
        self.bones
            .iter()
            .zip(&rooted)
            .map(|(b, &rooted)| b.flags & BONE_IK != 0 && !rooted)
            .collect()
    }
}

#[derive(Clone)]
struct Mesh {
    material: String,
    flags: u32,
    /// Rows of blend values (flag 2).
    rows: u32,
    attributes: Attributes,
    vertices: Vec<Vertex>,
    indices: Vec<u16>,
    segments: Vec<Segment>,
    clip_groups: Vec<ClipGroup>,
    count: usize,
}

/// Reads the mesh chunk and leaves `r` after it. Returns the chunk version, the first mesh
/// (Wallpaper Engine draws a puppet's first mesh) and the first mesh flagged as a blend map.
fn parse_mesh(r: &mut Reader<'_>) -> Result<(u32, Mesh, Option<Mesh>), Error> {
    let tag = r.bytes(9)?;
    if !(tag.starts_with(MESH_KIND) && tag[4..8].iter().all(u8::is_ascii_digit)) {
        return Err(Error::Unsupported(format!(
            "model: expected a MDLV chunk, found {}",
            String::from_utf8_lossy(&tag[..8])
        )));
    }
    if tag[8] != 0 {
        return Err(bad("mesh tag is not followed by NUL"));
    }
    let version = digits(&tag[4..8]);
    let header_flags = r.u32()?;
    let strings = r.u32()? as usize;
    let count = r.u32()? as usize;
    if strings == 0 || strings > 16 || count == 0 || count > MAX_MESHES {
        return Err(bad(format!("mesh header: {strings} strings, {count} meshes")));
    }
    let mut first: Option<Mesh> = None;
    let mut blend_map = None;
    for _ in 0..count {
        let mesh = parse_one_mesh(r, version, header_flags, strings)?;
        let map = blend_map.is_none() && mesh.flags & MESH_BLEND_MAP != 0;
        if first.is_none() {
            if map {
                blend_map = Some(mesh.clone());
            }
            first = Some(Mesh { count, ..mesh });
        } else if map {
            blend_map = Some(mesh);
        }
    }
    Ok((version, first.ok_or_else(|| bad("no mesh"))?, blend_map))
}

fn parse_one_mesh(r: &mut Reader<'_>, version: u32, header_flags: u32, strings: usize) -> Result<Mesh, Error> {
    let material = String::from_utf8_lossy(cstring(r, MAX_STRING, "material path")?).into_owned();
    for _ in 1..strings {
        cstring(r, MAX_STRING, "mesh string")?;
    }
    let flags = if version >= 4 { r.u32()? } else { 0 };
    let rows = if flags & MESH_BLEND_MAP != 0 { r.u32()? } else { 0 };
    if version >= 17 {
        let _bounds = r.bytes(24)?;
    }
    let attributes = Attributes::from_flags(if version > 14 { r.u32()? } else { header_flags })?;
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
        let position = read_vec3(r, "vertex position")?;
        let morph = if attributes.has(ATTR_POSITION4) {
            finite_f32(r, "vertex position w")?.max(0.0) as u32
        } else {
            0
        };
        let normal = if attributes.has(ATTR_NORMAL) {
            read_vec3(r, "vertex normal")?
        } else {
            [0.0, 0.0, 1.0]
        };
        let tangent = if attributes.has(ATTR_TANGENT) {
            read_vec4(r, "vertex tangent")?
        } else {
            [1.0, 0.0, 0.0, 1.0]
        };

        let mut bone_indices = [0u16; 4];
        let mut bone_weights = [1.0, 0.0, 0.0, 0.0];
        if attributes.has(ATTR_BONES) {
            for bone in &mut bone_indices {
                let at = r.pos;
                let value = r.u32()?;
                *bone = u16::try_from(value).map_err(|_| {
                    bad(format!(
                        "bone index {value} at 0x{at:x} does not fit in u16"
                    ))
                })?;
            }
        }
        if attributes.skinned() {
            for weight in &mut bone_weights {
                let at = r.pos;
                let value = finite_f32(r, "bone weight")?;
                if value < 0.0 {
                    return Err(bad(format!("negative bone weight {value} at 0x{at:x}")));
                }
                *weight = value;
            }
        }

        let mut uv = if attributes.has(ATTR_UV) {
            read_vec2(r, "vertex uv")?
        } else {
            [0.0, 0.0]
        };
        let mut uv2 = [0.0; 2];
        if attributes.has(ATTR_UV_PAIR) {
            let pair = read_vec4(r, "vertex uv pair")?;
            uv2 = [pair[2], pair[3]];
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
            uv2,
            morph,
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

    // Wallpaper Engine reads past the end of the file as zeros, and an unskinned mesh may end
    // right after its indices: the optional tail then counts as absent.
    let mut segments = Vec::new();
    if version > 20 {
        if soft(r, 1) && u8(r)? != 0 {
            let _ = r.u32()?;
            blob(r)?;
        }
        if soft(r, 1) && u8(r)? != 0 {
            segments = read_ranges(blob(r)?, index_count)?;
        }
    }
    let mut clip_groups = Vec::new();
    if version > 22 && soft(r, 4) {
        let groups = r.u32()? as usize;
        if groups > 4096 {
            return Err(bad(format!("{groups} clipping groups")));
        }
        for _ in 0..groups {
            let id = u64(r)?;
            let texture = String::from_utf8_lossy(cstring(r, MAX_STRING, "clip mask")?).into_owned();
            let flags = r.u32()?;
            let targets = index_list(r)?;
            let masks = index_list(r)?;
            clip_groups.push(ClipGroup { id, texture, flags, targets, masks });
        }
    }

    Ok(Mesh {
        material,
        flags,
        rows,
        attributes,
        vertices,
        indices,
        segments,
        clip_groups,
        count: 1,
    })
}

/// The index range table: 16-byte records of bone, draw-order offset, first index and count.
fn read_ranges(table: &[u8], index_count: usize) -> Result<Vec<Segment>, Error> {
    if !table.len().is_multiple_of(16) {
        return Err(bad(format!("index range table of {} bytes", table.len())));
    }
    let mut r = Reader::new(table);
    let mut segments = Vec::with_capacity(table.len() / 16);
    for _ in 0..table.len() / 16 {
        let bone = r.u32()?;
        let order = r.i32()?;
        let first_index = r.u32()?;
        let index_count_here = r.u32()?;
        if first_index as usize + index_count_here as usize > index_count {
            return Err(bad(format!("index range {first_index}+{index_count_here} is past the indices")));
        }
        segments.push(Segment { first_index, index_count: index_count_here, bone, order });
    }
    Ok(segments)
}

fn parse_skeleton(r: &mut Reader<'_>, version: u32, puppet: &mut Puppet) -> Result<(), Error> {
    let bone_count = r.u32()? as usize;
    if bone_count > MAX_BONES {
        return Err(bad(format!("bone count {bone_count} is too large")));
    }

    let mut bones = Vec::with_capacity(bone_count);
    for index in 0..bone_count {
        let bone_at = r.pos;
        let name = String::from_utf8_lossy(cstring(r, MAX_STRING, "bone name")?).into_owned();
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
        let local = read_matrix(r)?;

        let metadata = cstring(r, MAX_STRING, "bone metadata")?;
        let metadata =
            (!metadata.is_empty()).then(|| String::from_utf8_lossy(metadata).into_owned());
        bones.push(Bone { name, flags, parent, local, metadata });
    }
    puppet.rest_orders = vec![0; bone_count];
    puppet.bones = bones;
    if version < 2 {
        return Ok(());
    }

    let handle_count = usize::from(u16(r)?);
    for _ in 0..handle_count {
        let name = String::from_utf8_lossy(cstring(r, MAX_STRING, "handle name")?).into_owned();
        let bone = bone_index(r, bone_count)?;
        let kind = r.u32()?;
        let matrix = read_matrix(r)?;
        puppet.handles.push(Handle { name, bone, kind, matrix });
    }
    if u8(r)? != 0 {
        let bones = (0..bone_count).map(|_| read_matrix(r)).collect::<Result<_, _>>()?;
        let handles = (0..handle_count).map(|_| read_matrix(r)).collect::<Result<_, _>>()?;
        puppet.rest = Some((bones, handles));
    }

    let constraint_count = r.u32()? as usize;
    if constraint_count > 65_536 {
        return Err(bad(format!("{constraint_count} constraints")));
    }
    for _ in 0..constraint_count {
        let owner = bone_index(r, bone_count)?;
        let weight = r.u32()? as usize;
        let target = bone_index(r, bone_count)?;
        let flags = if version > 3 { r.u32()? } else { 0 };
        let values = if flags & 2 != 0 {
            let c = r.f32()?;
            [c, r.f32()?.max(f32::EPSILON)]
        } else {
            [0.0; 2]
        };
        puppet.constraints.push(Constraint { owner, weight, target, flags, values });
    }

    let n = usize::from(u16(r)?);
    if n > 0 {
        puppet.lengths = (0..n).map(|_| r.f32()).collect::<Result<_, _>>()?;
        for _ in 0..n {
            let k = usize::from(u16(r)?);
            let mut directions = Vec::with_capacity(k);
            for _ in 0..k {
                let child = r.u32()? as usize;
                directions.push((child, read_vec3(r, "rest direction")?));
            }
            puppet.rest_directions.push(directions);
        }
    }

    let groups = usize::from(u16(r)?);
    for _ in 0..groups {
        let root = bone_index(r, bone_count)?;
        let handles = index_list(r)?;
        if handles.iter().any(|&h| h >= handle_count) {
            return Err(bad("a chain group names a missing handle"));
        }
        let mut entries = Vec::new();
        for _ in 0..u16(r)? {
            let bone = bone_index(r, bone_count)?;
            let mut chains = Vec::new();
            for _ in 0..u16(r)? {
                let end = bone_index(r, bone_count)?;
                let flags = r.u32()?;
                let max_length = r.f32()?;
                let min_length = r.f32()?;
                let mut bones = Vec::new();
                for _ in 0..u16(r)? {
                    bones.push(bone_index(r, bone_count)?);
                }
                chains.push(Chain { end, flags, max_length, min_length, bones });
            }
            entries.push(ChainEntry { bone, chains });
        }
        puppet.chains.push(ChainGroup { root, handles, entries });
    }

    if u8(r)? != 0 {
        let _picking = r.bytes(0x4c * bone_count)?;
    }
    if u8(r)? != 0 {
        let _sorted = r.bytes(4 * bone_count)?;
    }
    if version > 2 && u8(r)? != 0 {
        puppet.rest_orders = (0..bone_count).map(|_| r.i32()).collect::<Result<_, _>>()?;
    }
    Ok(())
}

fn parse_attachments(r: &mut Reader<'_>, bone_count: usize) -> Result<Vec<Attachment>, Error> {
    let count = usize::from(u16(r)?);
    if count > MAX_ATTACHMENTS {
        return Err(bad(format!("attachment count {count} is too large")));
    }
    let mut attachments = Vec::with_capacity(count);
    for _ in 0..count {
        let bone = usize::from(u16(r)?);
        let name = String::from_utf8_lossy(cstring(r, MAX_STRING, "attachment name")?).into_owned();
        let matrix = read_matrix(r)?;
        if bone < bone_count {
            attachments.push(Attachment { bone, name, matrix });
        }
    }
    Ok(attachments)
}

fn parse_animations(
    r: &mut Reader<'_>,
    version: u32,
    puppet: &Puppet,
    meshes: usize,
) -> Result<Vec<Animation>, Error> {
    let count = r.u32()? as usize;
    if count > MAX_ANIMATIONS {
        return Err(bad(format!("animation count {count} is too large")));
    }
    let bones = puppet.bones.len();
    let mut animations = Vec::with_capacity(count);
    for index in 0..count {
        let at = r.pos;
        let id = u64(r)?;
        let name = String::from_utf8_lossy(cstring(r, 256, "animation name")?).into_owned();
        let flag = String::from_utf8_lossy(cstring(r, 16, "animation mode")?).into_owned();
        let fps = finite_f32(r, "animation fps")?;
        let duration_frames = r.u32()?;
        let flags = r.u32()?;
        let track_count = r.u32()? as usize;
        if !(fps > 0.0 && fps <= 1000.0) || duration_frames as usize >= MAX_FRAMES || track_count != bones {
            return Err(bad(format!(
                "animation {index} at 0x{at:x}: fps {fps}, {duration_frames} frames, {track_count} tracks for {bones} bones"
            )));
        }
        let frames = duration_frames as usize + 1;
        let mut tracks = Vec::with_capacity(bones);
        for bone in 0..bones {
            tracks.push(read_track(r, bone, frames)?);
        }
        let mut animation = Animation {
            id: u32::try_from(id).map_err(|_| bad(format!("animation id {id}")))?,
            name,
            flag,
            fps,
            duration_frames,
            tracks,
            ..Animation::default()
        };
        if version > 1 {
            for h in 0..puppet.handles.len() {
                animation.handle_tracks.push(read_track(r, h, frames)?);
            }
            for _ in 0..puppet.constraints.len() {
                animation.constraint_curves.push(read_curve(r, frames)?);
            }
        }
        if version > 2 {
            let n = r.u32()? as usize;
            if n > 4096 {
                return Err(bad(format!("{n} blend map curves")));
            }
            animation.blend_map = (0..n).map(|_| read_curve(r, frames)).collect::<Result<_, _>>()?;
            if u8(r)? != 0 {
                animation.alpha = (0..bones).map(|_| read_curve(r, frames)).collect::<Result<_, _>>()?;
            }
        }
        if version >= 4 && u8(r)? != 0 {
            for mesh in 0..meshes {
                if r.u32()? & 1 == 0 {
                    continue;
                }
                let _ = r.u32()?;
                for _ in 0..u16(r)? {
                    let target = usize::from(u16(r)?);
                    let values = curve_values(blob(r)?, frames)?;
                    if mesh == 0 {
                        animation.morphs.push((target, Curve { values, excluded: false }));
                    }
                }
            }
        }
        if version >= 5 {
            let _bounds = r.bytes(24)?;
        }
        if version >= 6 && u8(r)? != 0 {
            animation.orders = (0..bones).map(|_| read_curve(r, frames)).collect::<Result<_, _>>()?;
        }
        if flags & 1 != 0 {
            let _reference = r.bytes(18)?;
        }
        for _ in 0..r.u32()? {
            let _frame = r.u32()?;
            cstring(r, MAX_STRING, "animation event")?;
        }
        animations.push(animation);
    }
    Ok(animations)
}

fn parse_morphs(r: &mut Reader<'_>, puppet: &Puppet, meshes: usize) -> Result<Option<Morphs>, Error> {
    let mut first = None;
    for mesh in 0..meshes {
        let targets = usize::from(u16(r)?);
        if targets == 0 {
            continue;
        }
        let scale = r.f32()?;
        let vertices = r.u32()? as usize;
        if vertices > MAX_VERTICES {
            return Err(bad(format!("{vertices} morph vertices")));
        }
        let mut morphs = Morphs { scale, vertices, targets: Vec::with_capacity(targets) };
        for _ in 0..targets {
            let id = u64(r)?;
            let name = String::from_utf8_lossy(cstring(r, MAX_STRING, "morph name")?).into_owned();
            let deltas = snorm_blob(r, 3 * vertices)?;
            for flag in [MORPH_NORMALS, MORPH_SECOND] {
                if puppet.mesh_flags & flag != 0 {
                    snorm_blob(r, 3 * vertices)?;
                }
            }
            let alphas = if puppet.mesh_flags & MORPH_ALPHA != 0 {
                snorm_blob(r, vertices)?
            } else {
                Vec::new()
            };
            let bone = if puppet.mesh_flags & MORPH_BONE != 0 {
                let bone = bone_index(r, puppet.bones.len())?;
                let flags = r.u32()?;
                Some(MorphBone { bone, flags, edges: [r.f32()?, r.f32()?] })
            } else {
                None
            };
            morphs.targets.push(MorphTarget { id, name, deltas, alphas, bone });
        }
        if mesh == 0 {
            first = Some(morphs);
        }
    }
    Ok(first)
}

/// A blob of exactly `count` SNORM16 values.
fn snorm_blob(r: &mut Reader<'_>, count: usize) -> Result<Vec<i16>, Error> {
    let bytes = blob(r)?;
    if bytes.len() != 2 * count {
        return Err(bad(format!("morph blob of {} bytes, expected {}", bytes.len(), 2 * count)));
    }
    Ok(bytes.as_chunks::<2>().0.iter().map(|b| i16::from_le_bytes(*b)).collect())
}

fn read_track(r: &mut Reader<'_>, bone: usize, frames: usize) -> Result<Track, Error> {
    let at = r.pos;
    let flags = r.u32()?;
    let size = r.u32()? as usize;
    if size != frames * KEYFRAME_SIZE {
        return Err(bad(format!(
            "track at 0x{at:x} holds {size} bytes, not {frames} keyframes"
        )));
    }
    let mut keyframes = Vec::with_capacity(frames);
    for _ in 0..frames {
        keyframes.push(read_transform(r)?);
    }
    Ok(Track { bone, keyframes, excluded: flags & 1 != 0 })
}

fn read_curve(r: &mut Reader<'_>, frames: usize) -> Result<Curve, Error> {
    let flags = r.u32()?;
    Ok(Curve { values: curve_values(blob(r)?, frames)?, excluded: flags & 1 != 0 })
}

fn curve_values(bytes: &[u8], frames: usize) -> Result<Vec<f32>, Error> {
    if bytes.len() != 4 * frames {
        return Err(bad(format!("curve of {} bytes for {frames} frames", bytes.len())));
    }
    Ok(bytes.as_chunks::<4>().0.iter().map(|b| f32::from_le_bytes(*b)).collect())
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

fn read_matrix(r: &mut Reader<'_>) -> Result<M4, Error> {
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

pub(crate) fn finite_f32(r: &mut Reader<'_>, what: &str) -> Result<f32, Error> {
    let at = r.pos;
    let value = r.f32()?;
    if !value.is_finite() {
        return Err(bad(format!("non-finite {what} at 0x{at:x}")));
    }
    Ok(value)
}

/// Whether `n` more bytes are left to read.
fn soft(r: &Reader<'_>, n: usize) -> bool {
    r.pos + n <= r.data.len()
}

fn u8(r: &mut Reader<'_>) -> Result<u8, Error> {
    Ok(r.bytes(1)?[0])
}

fn u16(r: &mut Reader<'_>) -> Result<u16, Error> {
    let bytes = r.bytes(2)?;
    Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
}

fn u64(r: &mut Reader<'_>) -> Result<u64, Error> {
    let lo = u64::from(r.u32()?);
    Ok(lo | u64::from(r.u32()?) << 32)
}

/// A u32 byte count and that many bytes.
fn blob<'a>(r: &mut Reader<'a>) -> Result<&'a [u8], Error> {
    let n = r.u32()? as usize;
    r.bytes(n)
}

/// A u32 count and that many u32 indices.
fn index_list(r: &mut Reader<'_>) -> Result<Vec<usize>, Error> {
    let n = r.u32()? as usize;
    if n > 65_536 {
        return Err(bad(format!("list of {n} indices")));
    }
    (0..n).map(|_| Ok(r.u32()? as usize)).collect()
}

fn bone_index(r: &mut Reader<'_>, bones: usize) -> Result<usize, Error> {
    let at = r.pos;
    let bone = r.u32()? as usize;
    if bone >= bones {
        return Err(bad(format!("bone {bone} at 0x{at:x}, but the skeleton has {bones}")));
    }
    Ok(bone)
}

fn digits(d: &[u8]) -> u32 {
    d.iter().fold(0, |n, &c| n * 10 + u32::from(c - b'0'))
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
        build_model(third_index, "", "")
    }

    /// A one-triangle model whose single bone has `bone_name` and `metadata`.
    fn build_model(third_index: u16, bone_name: &str, metadata: &str) -> Vec<u8> {
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

        // No second position set; one index range for bone 0; no clipping groups.
        buf.push(0);
        buf.push(1);
        for word in [16, 0, 0, 0, 3, 0] {
            push_u32(&mut buf, word);
        }

        let skeleton_at = buf.len();
        buf.extend_from_slice(b"MDLS0004\0");
        push_u32(&mut buf, 0);
        push_u32(&mut buf, 1);
        buf.extend_from_slice(bone_name.as_bytes());
        buf.push(0);
        push_u32(&mut buf, 1);
        push_u32(&mut buf, u32::MAX);
        push_u32(&mut buf, 64);
        push_matrix(&mut buf, [0.0, 0.0]);
        buf.extend_from_slice(metadata.as_bytes());
        buf.push(0);
        // An empty rig: no handles, rest matrices, constraints, lengths, chains, picking boxes or
        // draw orders.
        buf.extend_from_slice(&[0u8; 14]);

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
                bone: 0,
                order: 0,
            }
        );
        assert_eq!(model.bones.len(), 1);
        assert_eq!(model.bones[0].parent, None);
        assert_eq!(model.attachments.len(), 0);
        assert_eq!(model.animations.len(), 1);
        assert_eq!(model.animations[0].id, 100);
        assert_eq!(model.animations[0].tracks.len(), 1);
        assert_eq!(model.animations[0].tracks[0].keyframes.len(), 2);
    }

    #[test]
    fn a_bone_keeps_its_name_and_metadata() {
        let model =
            Puppet::parse(&build_model(2, "skirt", "{\"tm\":1}")).expect("named bone parses");
        assert_eq!(model.bones[0].name, "skirt");
        assert_eq!(model.bones[0].metadata.as_deref(), Some("{\"tm\":1}"));
        assert_eq!(model.animations.len(), 1);
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

    fn library() -> Option<std::path::PathBuf> {
        let home = std::env::var("HOME").ok()?;
        Some(std::path::Path::new(&home).join("Library/Application Support/WallpaperMage/Library"))
    }

    /// Every puppet of the local scene library parses, with index ranges that tile the index
    /// buffer and animations that cover every bone.
    #[test]
    #[ignore = "needs the local scene library"]
    fn parses_every_local_puppet() {
        let Some(library) = library().filter(|l| l.exists()) else {
            return;
        };
        let mut models = 0;
        for entry in std::fs::read_dir(&library).expect("library") {
            let package = entry.expect("entry").path().join("scene.pkg");
            let Ok(package) = crate::vfs::Pkg::open(&package) else {
                continue;
            };
            let Ok(scene) = package.get("scene.json").map(|d| serde_json::from_slice::<serde_json::Value>(&d)).transpose() else {
                continue;
            };
            let mut names: Vec<String> = Vec::new();
            for object in scene.iter().flat_map(|s| s["objects"].as_array().cloned().unwrap_or_default()) {
                let Some(json) = object["image"].as_str().and_then(|m| package.get(m)) else {
                    continue;
                };
                let model: serde_json::Value = serde_json::from_slice(&json).unwrap_or_default();
                if let Some(puppet) = model["puppet"].as_str() {
                    names.push(puppet.to_string());
                }
            }
            names.sort();
            names.dedup();
            for name in names {
                let data = package.get(&name).expect("puppet file");
                let model = Puppet::parse(&data).unwrap_or_else(|e| panic!("{name}: {e}"));
                let mut covered = 0;
                for s in &model.segments {
                    assert_eq!(s.first_index, covered, "{name}");
                    covered += s.index_count;
                }
                assert!(model.segments.is_empty() || covered as usize == model.indices.len(), "{name}");
                for animation in &model.animations {
                    assert_eq!(animation.tracks.len(), model.bones.len(), "{name}");
                }
                models += 1;
            }
        }
        assert!(models > 0);
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
