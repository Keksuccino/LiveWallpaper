//! A puppet's mesh in its current pose, computed on the CPU the way Wallpaper Engine's puppet
//! vertex shader (`genericimage4.vert`) computes it on the GPU.
//!
//! Morph targets move each vertex in bind space before skinning: Wallpaper Engine packs the
//! targets' SNORM16 deltas into a texture (texel 0 holds no delta, texel `1 + target * V + vertex`
//! the target's delta and alpha) and each vertex reads at its morph index (its fourth position
//! float) plus each active target's offset. Up to eleven targets apply, the first ones switched
//! on, heaviest first. A target may be faded in by a bone's distance from the vertex. The deltas
//! move the position by `scale * delta * weight`; the alphas fade the vertex by
//! `alpha * weight + 1 - weight`. The texture is only filled when the targets carry alphas
//! (mesh flag `MORPH_ALPHA`): without them Wallpaper Engine's targets move nothing.
//!
//! Bone alphas fade each vertex by the weighted sum of its bones' alphas, clamped to 0...1.

use crate::mat::{self, M4};
use crate::pose::Extras;
use crate::puppet::{Morphs, Puppet, MORPH_ALPHA};

/// Wallpaper Engine's limit of morph targets on at once.
const MAX_MORPHS: usize = 11;

/// One switched-on morph target.
struct Active<'a> {
    /// The target's first texel minus one (`target * V`).
    offset: usize,
    weight: f32,
    /// Inverse world matrix of the bone that fades the target in, its measure and edges.
    bone: Option<(M4, bool, [f32; 2])>,
    morphs: &'a Morphs,
}

/// The vertex stream the puppet pipeline draws: per vertex x, y, u, v, r, g, b, a as f32.
/// `bones` are the skinning matrices, `world` the bones' world matrices.
pub fn vertices(
    model: &Puppet,
    bones: &[M4],
    world: &[M4],
    extras: &Extras,
    uv_scale: [f32; 2],
    color: [f32; 3],
    alpha: f32,
) -> Vec<u8> {
    let active = active_morphs(model, world, extras);
    let mut out = Vec::with_capacity(model.vertices.len() * 32);
    for v in &model.vertices {
        let skin = |p: [f32; 3]| {
            let mut out = [0.0f32; 3];
            for k in 0..4 {
                let w = v.bone_weights[k];
                if w <= 0.0 {
                    continue;
                }
                let m = bones.get(v.bone_indices[k] as usize).copied().unwrap_or(mat::IDENTITY);
                let q = mat::point(&m, p);
                for (o, q) in out.iter_mut().zip(q) {
                    *o += q * w;
                }
            }
            out
        };
        let mut position = v.position;
        let mut a = alpha;
        if !active.is_empty() {
            let skinned = active.iter().any(|m| m.bone.is_some()).then(|| skin(v.position));
            for m in &active {
                let amount = match (m.bone, skinned) {
                    (Some((inverse, along_x, [e0, e1])), Some(p)) => {
                        let l = mat::point(&inverse, p);
                        let x = if along_x { l[0] } else { (l[0] * l[0] + l[1] * l[1]).sqrt() };
                        smoothstep(e0, e1, x)
                    }
                    _ => 1.0,
                };
                let w = amount * m.weight;
                let c = texel(m.morphs, v.morph as usize + m.offset);
                for k in 0..3 {
                    position[k] += m.morphs.scale * c[k] * w;
                }
                a *= c[3] * w + 1.0 - w;
            }
        }
        if !extras.alpha.is_empty() {
            let sum: f32 = (0..4)
                .map(|k| extras.alpha.get(v.bone_indices[k] as usize).copied().unwrap_or(1.0) * v.bone_weights[k])
                .sum();
            a *= sum.clamp(0.0, 1.0);
        }
        let pos = skin(position);
        // Model-space position; the draw's matrix carries the layer transform.
        for f in [pos[0], pos[1], v.uv[0] * uv_scale[0], v.uv[1] * uv_scale[1], color[0], color[1], color[2], a] {
            out.extend_from_slice(&f.to_le_bytes());
        }
    }
    out
}

/// The targets that apply this frame: the first eleven switched on, heaviest first.
fn active_morphs<'a>(model: &'a Puppet, world: &[M4], extras: &Extras) -> Vec<Active<'a>> {
    let Some(morphs) = model.morphs.as_ref().filter(|_| model.mesh_flags & MORPH_ALPHA != 0) else {
        return Vec::new();
    };
    let mut active: Vec<Active<'a>> = extras
        .morphs
        .iter()
        .enumerate()
        .filter(|(i, (_, on))| *on && *i < morphs.targets.len())
        .take(MAX_MORPHS)
        .map(|(i, &(weight, _))| Active {
            offset: i * morphs.vertices,
            weight,
            bone: morphs.targets[i].bone.map(|b| {
                let inverse = mat::invert(world.get(b.bone).unwrap_or(&mat::IDENTITY));
                (inverse, b.flags & 2 != 0, b.edges)
            }),
            morphs,
        })
        .collect();
    active.sort_by(|a, b| b.weight.total_cmp(&a.weight));
    active
}

/// The morph texture's texel `i`: delta xyz and alpha.
fn texel(morphs: &Morphs, i: usize) -> [f32; 4] {
    if i == 0 {
        return [0.0, 0.0, 0.0, 1.0];
    }
    let (target, vertex) = ((i - 1) / morphs.vertices.max(1), (i - 1) % morphs.vertices.max(1));
    let Some(t) = morphs.targets.get(target) else { return [0.0; 4] };
    let snorm = |v: Option<&i16>| v.map_or(0.0, |&v| (f32::from(v) / 32767.0).max(-1.0));
    [
        snorm(t.deltas.get(3 * vertex)),
        snorm(t.deltas.get(3 * vertex + 1)),
        snorm(t.deltas.get(3 * vertex + 2)),
        snorm(t.alphas.get(vertex)),
    ]
}

fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::puppet::{Bone, MorphTarget, Vertex};

    fn read(stream: &[u8]) -> Vec<f32> {
        stream.as_chunks::<4>().0.iter().map(|b| f32::from_le_bytes(*b)).collect()
    }

    fn model(flags: u32) -> Puppet {
        let vertex = |x: f32, morph: u32| Vertex {
            position: [x, 0.0, 0.0],
            bone_weights: [1.0, 0.0, 0.0, 0.0],
            morph,
            ..Vertex::default()
        };
        Puppet {
            mesh_flags: flags,
            vertices: vec![vertex(0.0, 1), vertex(10.0, 2)],
            bones: vec![Bone { local: mat::IDENTITY, ..Bone::default() }],
            morphs: Some(Morphs {
                scale: 4.0,
                vertices: 2,
                targets: vec![MorphTarget {
                    deltas: vec![0, 32767, 0, 0, -32767, 0],
                    alphas: vec![32767, 0],
                    ..MorphTarget::default()
                }],
            }),
            ..Puppet::default()
        }
    }

    #[test]
    fn a_morph_target_moves_and_fades_vertices_by_its_weight() {
        let model = model(MORPH_ALPHA);
        let extras = Extras { morphs: vec![(0.5, true)], ..Extras::default() };
        let v = read(&vertices(&model, &[mat::IDENTITY], &[mat::IDENTITY], &extras, [1.0; 2], [1.0; 3], 1.0));
        // Vertex 0 moves up by scale * 1 * 0.5 and keeps its alpha (delta alpha 1).
        assert!((v[1] - 2.0).abs() < 1e-4 && (v[7] - 1.0).abs() < 1e-4, "{v:?}");
        // Vertex 1 moves down and fades to 0 * 0.5 + 1 - 0.5.
        assert!((v[9] + 2.0).abs() < 1e-4 && (v[15] - 0.5).abs() < 1e-4, "{v:?}");
    }

    #[test]
    fn targets_without_alphas_move_nothing() {
        let model = model(0);
        let extras = Extras { morphs: vec![(1.0, true)], ..Extras::default() };
        let v = read(&vertices(&model, &[mat::IDENTITY], &[mat::IDENTITY], &extras, [1.0; 2], [1.0; 3], 1.0));
        assert_eq!(v[1], 0.0);
    }

    #[test]
    fn bone_alpha_fades_the_vertices_of_the_bone() {
        let model = model(0);
        let extras = Extras { alpha: vec![0.25], ..Extras::default() };
        let v = read(&vertices(&model, &[mat::IDENTITY], &[mat::IDENTITY], &extras, [1.0; 2], [1.0; 3], 0.8));
        assert!((v[7] - 0.2).abs() < 1e-6, "{v:?}");
    }
}
