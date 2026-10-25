//! Static meshes of model objects (`.mdl`), packed into one vertex layout for the GPU.
//!
//! # Layout
//!
//! Read from the eight static models of the default 3D scenes (`demon_core`, `dna_fragment`,
//! `arsenal`, `neon_sunset`, `retro`), whose `.fbx`/`.obj` sources ship next to them, and checked
//! against the puppet meshes `puppet.rs` documents. All integers are little-endian.
//!
//! ```text
//! 0x00  8   tag "MDLV" + four version digits ("0004" and "0014" in the static models)
//! 0x08  1   0
//! 0x09  4   vertex attribute mask (see `puppet::Attributes`)
//! 0x0d  4   1 in every file
//! 0x11  4   submesh count (6 in `pistols.mdl`, one per material)
//!       per submesh:
//!         NUL-terminated material path
//!         versions before 15: u32 0
//!         later versions: 28 bytes (zero in most files), u32 attribute mask of this submesh
//!         u32 vertex bytes, then the vertices
//!         u32 index bytes, then u16 triangle indices into this submesh's vertices
//! ```
//!
//! The puppet meshes (versions 17 to 23) have the same header with one submesh; versions 15 and 16
//! were not seen and are read like the later ones. Chunks after the mesh (skeleton, animations) are
//! not read: a skinned model draws in its bind pose. Triangles are counter-clockwise seen from the
//! side their normals point to (every triangle of the five meshes that store normals).

use std::ffi::c_void;
use std::ptr::NonNull;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_metal::{MTLBuffer, MTLDevice, MTLResourceOptions, MTLVertexFormat};

use crate::puppet::{self, Attributes};
use crate::vfs::Reader;
use crate::Error;

/// Floats per packed vertex: position xyz, normal xyz, tangent xyzw, uv, second uv.
pub const VERTEX_FLOATS: usize = 14;
pub const VERTEX_STRIDE: usize = VERTEX_FLOATS * 4;

/// More submeshes than any file plausibly has; guards against a corrupt count.
const MAX_SUBMESHES: usize = 4096;

/// A parsed mesh: the vertices and indices of all submeshes, one after the other.
#[derive(Debug, Clone, PartialEq)]
pub struct Mesh {
    /// `VERTEX_FLOATS` per vertex.
    pub vertices: Vec<f32>,
    pub indices: Vec<u16>,
    pub submeshes: Vec<Submesh>,
}

/// One material's part of a mesh.
#[derive(Debug, Clone, PartialEq)]
pub struct Submesh {
    /// Material path, relative to the scene package.
    pub material: String,
    /// First vertex of the submesh; its indices count from there.
    pub first_vertex: usize,
    /// First index of the submesh. Always even, so its byte offset is a multiple of four, which
    /// Metal asks of an index buffer offset.
    pub first_index: usize,
    pub index_count: usize,
}

/// Parses the mesh chunk of a `.mdl` file.
pub fn parse(data: &[u8]) -> Result<Mesh, Error> {
    let mut r = Reader::new(data);
    puppet::read_chunk(&mut r, puppet::MESH_KIND, true)?;
    let version: u32 = std::str::from_utf8(&data[4..8])
        .ok()
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| puppet::bad("mesh version is not a number"))?;
    let header_flags = r.u32()?;
    let _ = r.u32()?;
    let count = r.u32()? as usize;
    if count == 0 || count > MAX_SUBMESHES {
        return Err(puppet::bad(format!(
            "submesh count {count} is out of range"
        )));
    }
    let mut mesh = Mesh {
        vertices: Vec::new(),
        indices: Vec::new(),
        submeshes: Vec::with_capacity(count),
    };
    for _ in 0..count {
        let material = String::from_utf8_lossy(puppet::cstring(
            &mut r,
            puppet::MAX_STRING,
            "material path",
        )?)
        .into_owned();
        let flags = if version < 15 {
            let _ = r.u32()?;
            header_flags
        } else {
            let _ = r.bytes(28)?;
            r.u32()?
        };
        let attributes = Attributes::from_flags(flags)?;
        let stride = attributes.stride();
        let vertex_bytes = r.u32()? as usize;
        if !vertex_bytes.is_multiple_of(stride) {
            return Err(puppet::bad(format!(
                "vertex byte count {vertex_bytes} is not a multiple of {stride}"
            )));
        }
        let vertex_count = vertex_bytes / stride;
        let first_vertex = mesh.vertices.len() / VERTEX_FLOATS;
        if first_vertex + vertex_count > puppet::MAX_VERTICES {
            return Err(puppet::bad(format!(
                "vertex count {vertex_count} is too large"
            )));
        }
        mesh.vertices.reserve(vertex_count * VERTEX_FLOATS);
        for _ in 0..vertex_count {
            read_vertex(&mut r, attributes, &mut mesh.vertices)?;
        }
        let index_bytes = r.u32()? as usize;
        if !index_bytes.is_multiple_of(2) || index_bytes / 2 > puppet::MAX_INDICES {
            return Err(puppet::bad(format!(
                "index byte count {index_bytes} is invalid"
            )));
        }
        let raw = r.bytes(index_bytes)?;
        // Keeps every submesh's first index even (see `Submesh::first_index`).
        if !mesh.indices.len().is_multiple_of(2) {
            mesh.indices.push(0);
        }
        let first_index = mesh.indices.len();
        for (i, b) in raw.as_chunks::<2>().0.iter().enumerate() {
            let index = u16::from_le_bytes(*b);
            if usize::from(index) >= vertex_count {
                return Err(puppet::bad(format!(
                    "index {i} points at vertex {index}, but the submesh has {vertex_count}"
                )));
            }
            mesh.indices.push(index);
        }
        mesh.submeshes.push(Submesh {
            material,
            first_vertex,
            first_index,
            index_count: index_bytes / 2,
        });
    }
    Ok(mesh)
}

/// Reads one vertex of the given attributes and appends it in the packed layout. Attributes the
/// file lacks get neutral values: normal +z, tangent +x, the second uv equal to the first.
fn read_vertex(r: &mut Reader<'_>, a: Attributes, out: &mut Vec<f32>) -> Result<(), Error> {
    let position = puppet::read_vec3(r, "vertex position")?;
    if a.has(puppet::ATTR_POSITION4) {
        let _ = puppet::finite_f32(r, "vertex position w")?;
    }
    let normal = if a.has(puppet::ATTR_NORMAL) {
        puppet::read_vec3(r, "vertex normal")?
    } else {
        [0.0, 0.0, 1.0]
    };
    let tangent = if a.has(puppet::ATTR_TANGENT) {
        puppet::read_vec4(r, "vertex tangent")?
    } else {
        [1.0, 0.0, 0.0, 1.0]
    };
    if a.skinned() {
        // Bone indices and weights; the bind pose needs neither.
        let _ = r.bytes(32)?;
    }
    let mut uv = [0.0, 0.0, 0.0, 0.0];
    if a.has(puppet::ATTR_UV) {
        let [u, v] = puppet::read_vec2(r, "vertex uv")?;
        uv = [u, v, u, v];
    }
    if a.has(puppet::ATTR_UV_PAIR) {
        let pair = puppet::read_vec4(r, "vertex uv pair")?;
        if a.has(puppet::ATTR_UV) {
            uv[2..].copy_from_slice(&pair[..2]);
        } else {
            uv = pair;
        }
    }
    out.extend_from_slice(&position);
    out.extend_from_slice(&normal);
    out.extend_from_slice(&tangent);
    out.extend_from_slice(&uv);
    Ok(())
}

/// Where a material's vertex input reads from in a packed vertex: its format and byte offset, by
/// the attribute names the engine's shaders use. `None` for inputs a static mesh has no data for
/// (vertex colour, bone indices and weights, particle inputs); those read a constant instead.
pub fn attribute(name: &str) -> Option<(MTLVertexFormat, usize)> {
    Some(match name {
        "a_Position" | "a_PositionVec4" => (MTLVertexFormat::Float3, 0),
        "a_Normal" => (MTLVertexFormat::Float3, 12),
        "a_Tangent4" => (MTLVertexFormat::Float4, 24),
        "a_TexCoord" => (MTLVertexFormat::Float2, 40),
        // The uv and the second (lightmap) uv: `generic` reads the lightmap from `.zw`.
        "a_TexCoordVec4" => (MTLVertexFormat::Float4, 40),
        _ => return None,
    })
}

/// The format of an input with no mesh data, read from the constant buffer (see
/// `CONSTANT_ATTRIBUTES`): bone indices are the only integer input of the engine's shaders.
pub fn constant_attribute(name: &str) -> (MTLVertexFormat, usize) {
    if name == "a_BlendIndices" {
        (MTLVertexFormat::UInt4, 16)
    } else {
        (MTLVertexFormat::Float4, 0)
    }
}

/// The values inputs without mesh data read, as bytes: four 1.0 floats (white vertex colour) and
/// four zero integers (bone 0).
pub const CONSTANT_ATTRIBUTES: [u8; 32] = {
    let one = 1.0f32.to_bits().to_le_bytes();
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 16 {
        out[i] = one[i % 4];
        i += 1;
    }
    out
};

/// A mesh on the GPU: one vertex and one index buffer for all submeshes, uploaded once.
#[derive(Debug)]
pub struct Buffers {
    pub vertices: Retained<ProtocolObject<dyn MTLBuffer>>,
    pub indices: Retained<ProtocolObject<dyn MTLBuffer>>,
    pub submeshes: Vec<Submesh>,
}

impl Buffers {
    pub fn upload(device: &ProtocolObject<dyn MTLDevice>, mesh: Mesh) -> Result<Self, Error> {
        let buffer = |ptr: *const c_void, len: usize, what: &str| {
            let ptr = NonNull::new(ptr as *mut c_void)
                .ok_or_else(|| Error::Format(format!("model has no {what}")))?;
            // SAFETY: the buffer copies `len` bytes from a live slice at once.
            unsafe {
                device.newBufferWithBytes_length_options(
                    ptr,
                    len,
                    MTLResourceOptions::StorageModeShared,
                )
            }
            .ok_or_else(|| Error::Metal(format!("model {what} buffer")))
        };
        Ok(Self {
            vertices: buffer(
                mesh.vertices.as_ptr().cast(),
                mesh.vertices.len() * 4,
                "vertices",
            )?,
            indices: buffer(
                mesh.indices.as_ptr().cast(),
                mesh.indices.len() * 2,
                "indices",
            )?,
            submeshes: mesh.submeshes,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One submesh of a synthetic file: its attribute mask, its vertices (floats in file order)
    /// and its indices.
    struct Part<'a> {
        flags: u32,
        vertices: &'a [&'a [f32]],
        indices: &'a [u16],
    }

    /// A `.mdl` mesh chunk of `version`, written in the layout the module notes describe.
    fn file(version: &str, parts: &[Part<'_>]) -> Vec<u8> {
        let mut buf = format!("MDLV{version}\0").into_bytes();
        let push = |buf: &mut Vec<u8>, v: u32| buf.extend_from_slice(&v.to_le_bytes());
        push(&mut buf, parts[0].flags);
        push(&mut buf, 1);
        push(&mut buf, parts.len() as u32);
        for (i, part) in parts.iter().enumerate() {
            buf.extend_from_slice(format!("materials/{i}.json\0").as_bytes());
            if version < "0015" {
                push(&mut buf, 0);
            } else {
                buf.extend_from_slice(&[0u8; 28]);
                push(&mut buf, part.flags);
            }
            let floats: Vec<f32> = part
                .vertices
                .iter()
                .flat_map(|v| v.iter().copied())
                .collect();
            push(&mut buf, (floats.len() * 4) as u32);
            for f in floats {
                buf.extend_from_slice(&f.to_le_bytes());
            }
            push(&mut buf, (part.indices.len() * 2) as u32);
            for i in part.indices {
                buf.extend_from_slice(&i.to_le_bytes());
            }
        }
        buf
    }

    const UV_TRIANGLE: [&[f32]; 3] = [
        &[0.0, 0.0, 0.0, 0.5, 0.25],
        &[1.0, 0.0, 0.0, 1.0, 0.0],
        &[0.0, 1.0, 0.0, 0.0, 1.0],
    ];

    #[test]
    fn an_old_mesh_with_two_submeshes_shares_one_attribute_mask() {
        let part = Part {
            flags: 0x9,
            vertices: &UV_TRIANGLE,
            indices: &[0, 1, 2],
        };
        let mesh = parse(&file(
            "0014",
            &[
                part,
                Part {
                    flags: 0x9,
                    vertices: &UV_TRIANGLE,
                    indices: &[2, 1, 0],
                },
            ],
        ))
        .expect("parses");
        assert_eq!(mesh.submeshes.len(), 2);
        assert_eq!(mesh.submeshes[1].material, "materials/1.json");
        // Position, the neutral normal and tangent, the uv twice.
        assert_eq!(
            &mesh.vertices[..VERTEX_FLOATS],
            &[0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.5, 0.25, 0.5, 0.25]
        );
        // The second submesh follows the first one's three vertices and starts on an even index.
        let second = &mesh.submeshes[1];
        assert_eq!((second.first_vertex, second.index_count), (3, 3));
        assert_eq!(second.first_index % 2, 0);
        assert_eq!(&mesh.indices[second.first_index..], &[2, 1, 0]);
    }

    #[test]
    fn a_later_mesh_reads_its_own_mask_and_the_uv_pair() {
        let v: &[f32] = &[
            2.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.1, 0.2, 0.3, 0.4,
        ];
        let mesh = parse(&file(
            "0023",
            &[Part {
                flags: 0x27,
                vertices: &[v, v, v],
                indices: &[0, 1, 2],
            }],
        ))
        .expect("parses");
        assert_eq!(mesh.vertices.len(), 3 * VERTEX_FLOATS);
        assert_eq!(&mesh.vertices[..VERTEX_FLOATS], v);
    }

    #[test]
    fn an_index_past_its_submesh_is_rejected() {
        let bad = Part {
            flags: 0x9,
            vertices: &UV_TRIANGLE,
            indices: &[0, 1, 3],
        };
        assert!(parse(&file("0014", &[bad])).is_err());
        let truncated = file(
            "0004",
            &[Part {
                flags: 0x9,
                vertices: &UV_TRIANGLE,
                indices: &[0, 1, 2],
            }],
        );
        assert!(parse(&truncated[..truncated.len() - 1]).is_err());
    }

    #[test]
    fn attribute_names_map_into_the_packed_vertex() {
        assert_eq!(attribute("a_Normal"), Some((MTLVertexFormat::Float3, 12)));
        assert_eq!(
            attribute("a_TexCoordVec4"),
            Some((MTLVertexFormat::Float4, 40))
        );
        assert_eq!(attribute("a_Color"), None);
        assert_eq!(
            constant_attribute("a_BlendIndices").0,
            MTLVertexFormat::UInt4
        );
    }
}
