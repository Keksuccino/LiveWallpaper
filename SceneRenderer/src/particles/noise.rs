//! Simplex noise in one, two and three dimensions, the smooth randomness turbulence and noise
//! transforms draw from. Each function returns roughly -1..1 and is 0 on the lattice points.
//!
//! The lattice hash is a permutation of 0..256 shuffled once from a fixed seed; the gradient sets
//! are the usual ones for each dimension (the twelve cube edges in 3D).

use std::sync::OnceLock;

/// The permutation the lattice hash reads.
fn perm() -> &'static [u8; 256] {
    static TABLE: OnceLock<[u8; 256]> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut p: [u8; 256] = std::array::from_fn(|i| i as u8);
        // Fisher-Yates with a splitmix64 stream: any fixed permutation gives the same quality.
        let mut state = 0x5EED_0F70_15E5_u64;
        for i in (1..256).rev() {
            state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = state;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^= z >> 31;
            p.swap(i, (z % (i as u64 + 1)) as usize);
        }
        p
    })
}

/// The lattice hash of `i` (wrapped into the table).
fn hash(table: &[u8; 256], i: i32) -> usize {
    table[(i & 255) as usize] as usize
}

fn fast_floor(x: f32) -> i32 {
    let i = x as i32;
    if (i as f32) > x {
        i - 1
    } else {
        i
    }
}

/// 1D simplex noise.
pub fn noise1(x: f32) -> f32 {
    let p = perm();
    let i0 = fast_floor(x);
    let x0 = x - i0 as f32;
    let x1 = x0 - 1.0;
    let corner = |h: usize, d: f32| {
        let t = 1.0 - d * d;
        // Gradients 1..8, either sign.
        let g = (1 + (h & 7)) as f32;
        let g = if h & 8 != 0 { -g } else { g };
        t * t * t * t * g * d
    };
    0.395 * (corner(hash(p, i0), x0) + corner(hash(p, i0 + 1), x1))
}

/// 2D simplex noise.
pub fn noise2(x: f32, y: f32) -> f32 {
    const F2: f32 = 0.366_025_4;
    const G2: f32 = 0.211_324_87;
    let p = perm();
    let s = (x + y) * F2;
    let i = fast_floor(x + s);
    let j = fast_floor(y + s);
    let t = (i + j) as f32 * G2;
    let x0 = x - (i as f32 - t);
    let y0 = y - (j as f32 - t);
    let (i1, j1) = if x0 > y0 { (1, 0) } else { (0, 1) };
    let x1 = x0 - i1 as f32 + G2;
    let y1 = y0 - j1 as f32 + G2;
    let x2 = x0 - 1.0 + 2.0 * G2;
    let y2 = y0 - 1.0 + 2.0 * G2;
    let corner = |h: usize, dx: f32, dy: f32| {
        let t = 0.5 - dx * dx - dy * dy;
        if t < 0.0 {
            return 0.0;
        }
        // Eight gradients: the axes and the diagonals, the axis ones twice as long.
        let (u, v) = if h & 4 == 0 { (dx, dy) } else { (dy, dx) };
        let u = if h & 1 != 0 { -u } else { u };
        let v = if h & 2 != 0 { -v } else { v };
        let t2 = t * t;
        t2 * t2 * (u + 2.0 * v)
    };
    let n = corner(hash(p, i + hash(p, j) as i32), x0, y0)
        + corner(hash(p, i + i1 + hash(p, j + j1) as i32), x1, y1)
        + corner(hash(p, i + 1 + hash(p, j + 1) as i32), x2, y2);
    45.23 * n
}

/// 3D simplex noise.
pub fn noise3(x: f32, y: f32, z: f32) -> f32 {
    const F3: f32 = 1.0 / 3.0;
    const G3: f32 = 1.0 / 6.0;
    // The twelve edges of a cube, as gradient directions.
    const GRAD: [[f32; 3]; 12] = [
        [1.0, 1.0, 0.0],
        [-1.0, 1.0, 0.0],
        [1.0, -1.0, 0.0],
        [-1.0, -1.0, 0.0],
        [1.0, 0.0, 1.0],
        [-1.0, 0.0, 1.0],
        [1.0, 0.0, -1.0],
        [-1.0, 0.0, -1.0],
        [0.0, 1.0, 1.0],
        [0.0, -1.0, 1.0],
        [0.0, 1.0, -1.0],
        [0.0, -1.0, -1.0],
    ];
    let p = perm();
    let s = (x + y + z) * F3;
    let i = fast_floor(x + s);
    let j = fast_floor(y + s);
    let k = fast_floor(z + s);
    let t = (i + j + k) as f32 * G3;
    let (x0, y0, z0) = (x - (i as f32 - t), y - (j as f32 - t), z - (k as f32 - t));
    // Which of the six tetrahedra of the skewed cube the point is in.
    let (o1, o2) = if x0 >= y0 {
        if y0 >= z0 {
            ([1, 0, 0], [1, 1, 0])
        } else if x0 >= z0 {
            ([1, 0, 0], [1, 0, 1])
        } else {
            ([0, 0, 1], [1, 0, 1])
        }
    } else if y0 < z0 {
        ([0, 0, 1], [0, 1, 1])
    } else if x0 < z0 {
        ([0, 1, 0], [0, 1, 1])
    } else {
        ([0, 1, 0], [1, 1, 0])
    };
    let corner = |di: i32, dj: i32, dk: i32, dx: f32, dy: f32, dz: f32| {
        let t = 0.6 - dx * dx - dy * dy - dz * dz;
        if t < 0.0 {
            return 0.0;
        }
        let h = hash(p, i + di + hash(p, j + dj + hash(p, k + dk) as i32) as i32) % 12;
        let g = GRAD[h];
        let t2 = t * t;
        t2 * t2 * (g[0] * dx + g[1] * dy + g[2] * dz)
    };
    let n = corner(0, 0, 0, x0, y0, z0)
        + corner(
            o1[0],
            o1[1],
            o1[2],
            x0 - o1[0] as f32 + G3,
            y0 - o1[1] as f32 + G3,
            z0 - o1[2] as f32 + G3,
        )
        + corner(
            o2[0],
            o2[1],
            o2[2],
            x0 - o2[0] as f32 + 2.0 * G3,
            y0 - o2[1] as f32 + 2.0 * G3,
            z0 - o2[2] as f32 + 2.0 * G3,
        )
        + corner(1, 1, 1, x0 - 0.5, y0 - 0.5, z0 - 0.5);
    32.0 * n
}

/// Octaves of 2D noise, each at twice the frequency and half the weight of the one before,
/// normalised back to -1..1.
pub fn fbm2(x: f32, y: f32, octaves: u32) -> f32 {
    let (mut sum, mut weight, mut total, mut freq) = (0.0, 1.0, 0.0, 1.0);
    for _ in 0..octaves.max(1) {
        sum += weight * noise2(x * freq, y * freq);
        total += weight;
        weight *= 0.5;
        freq *= 2.0;
    }
    sum / total
}

/// 2D noise decorrelated by `seed`: each seed reads a different, far-apart part of the plane.
pub fn noise2_seeded(seed: u32, x: f32, y: f32) -> f32 {
    let (ox, oy) = seed_offset(seed);
    noise2(x + ox, y + oy)
}

/// `fbm2` over a seeded plane; each octave moves to the next seed.
pub fn fbm2_seeded(seed: u32, x: f32, y: f32, octaves: u32) -> f32 {
    let (mut sum, mut weight, mut total, mut freq) = (0.0, 1.0, 0.0, 1.0);
    for octave in 0..octaves.max(1) {
        sum += weight * noise2_seeded(seed.wrapping_add(octave), x * freq, y * freq);
        total += weight;
        weight *= 0.5;
        freq *= 2.0;
    }
    sum / total
}

fn seed_offset(seed: u32) -> (f32, f32) {
    let h = (seed as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    // Offsets below 2^12 keep the lattice coordinates exact in f32.
    (((h >> 40) & 0xfff) as f32, ((h >> 20) & 0xfff) as f32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noise_is_bounded_and_zero_on_the_lattice() {
        let mut max: f32 = 0.0;
        for i in 0..2000 {
            let x = i as f32 * 0.137 - 50.0;
            let y = i as f32 * 0.071 + 3.0;
            for v in [
                noise1(x),
                noise2(x, y),
                noise3(x, y, x * 0.5),
                fbm2(x, y, 4),
            ] {
                assert!(v.is_finite());
                max = max.max(v.abs());
            }
        }
        assert!(max <= 1.2, "noise range {max}");
        assert!(max > 0.5, "noise too flat {max}");
        assert_eq!(noise1(3.0), 0.0);
        assert!(noise2(0.0, 0.0).abs() < 1.0e-6);
    }

    #[test]
    fn seeds_decorrelate() {
        let a: Vec<f32> = (0..32)
            .map(|i| noise2_seeded(1, i as f32 * 0.3, 0.0))
            .collect();
        let b: Vec<f32> = (0..32)
            .map(|i| noise2_seeded(2, i as f32 * 0.3, 0.0))
            .collect();
        assert_ne!(a, b);
    }
}
