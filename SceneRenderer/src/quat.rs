//! Rotations and small vectors with the semantics of GLM, the maths library Wallpaper Engine's
//! puppet code uses: its slerp, its rotation between two vectors, its matrix casts and Euler
//! extraction. Following them exactly keeps physics and inverse kinematics within rounding of
//! Wallpaper Engine.
//!
//! Matrices are row-vector style (`v' = v * M`), as in `mat`. A GLM matrix read from the same
//! memory is the same array: GLM's columns are our rows, so GLM's `A * B` is our `B * A`.

/// A unit quaternion: x, y, z, w.
pub type Quat = [f32; 4];
pub type V3 = [f32; 3];
/// A 3x3 matrix, row-vector style.
pub type M3 = [[f32; 3]; 3];

pub const IDENTITY: Quat = [0.0, 0.0, 0.0, 1.0];
/// GLM's `epsilon<float>()`.
const EPSILON: f32 = f32::EPSILON;

/// Hamilton product `a * b`: `b`'s rotation first, then `a`'s.
pub fn mul(a: Quat, b: Quat) -> Quat {
    [
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    ]
}

pub fn conj(q: Quat) -> Quat {
    [-q[0], -q[1], -q[2], q[3]]
}

pub fn dot4(a: Quat, b: Quat) -> f32 {
    (0..4).map(|k| a[k] * b[k]).sum()
}

/// GLM's normalize: a zero quaternion becomes the identity.
pub fn normalize(q: Quat) -> Quat {
    let len = dot4(q, q).sqrt();
    if len <= 0.0 || !len.is_finite() {
        return IDENTITY;
    }
    q.map(|v| v / len)
}

/// GLM's slerp: along the shorter way, and a plain (unnormalised) lerp when the two are within
/// `1 - epsilon` of each other.
pub fn slerp(x: Quat, y: Quat, a: f32) -> Quat {
    let mut cos = dot4(x, y);
    let mut z = y;
    if cos < 0.0 {
        z = y.map(|v| -v);
        cos = -cos;
    }
    if cos > 1.0 - EPSILON {
        return std::array::from_fn(|k| x[k] + (z[k] - x[k]) * a);
    }
    let angle = cos.acos();
    let (s0, s1, s) = (((1.0 - a) * angle).sin(), (a * angle).sin(), angle.sin());
    std::array::from_fn(|k| (s0 * x[k] + s1 * z[k]) / s)
}

/// GLM's `rotation(from, to)` for unit vectors: the shortest turn taking `from` to `to`; half a
/// turn about an axis across `from` when they are opposite.
pub fn rotation(from: V3, to: V3) -> Quat {
    let cos = dot(from, to);
    if cos >= 1.0 - EPSILON || cos.is_nan() {
        return IDENTITY;
    }
    if cos < -1.0 + EPSILON {
        let mut axis = cross([0.0, 0.0, 1.0], from);
        if dot(axis, axis) < EPSILON {
            axis = cross([1.0, 0.0, 0.0], from);
        }
        let axis = normalize3(axis);
        let (s, c) = std::f32::consts::FRAC_PI_2.sin_cos();
        return [axis[0] * s, axis[1] * s, axis[2] * s, c];
    }
    let axis = cross(from, to);
    let s = ((1.0 + cos) * 2.0).sqrt();
    [axis[0] / s, axis[1] / s, axis[2] / s, s * 0.5]
}

/// The rotation of Euler angles (radians) applied about x, then y, then z: `qz * qy * qx`.
pub fn from_euler(r: V3) -> Quat {
    let (sx, cx) = (r[0] * 0.5).sin_cos();
    let (sy, cy) = (r[1] * 0.5).sin_cos();
    let (sz, cz) = (r[2] * 0.5).sin_cos();
    mul(mul([0.0, 0.0, sz, cz], [0.0, sy, 0.0, cy]), [sx, 0.0, 0.0, cx])
}

/// The rotation matrix of `q` (GLM's `mat3_cast`).
pub fn matrix(q: Quat) -> M3 {
    let [x, y, z, w] = q;
    [
        [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y + z * w), 2.0 * (x * z - y * w)],
        [2.0 * (x * y - z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z + x * w)],
        [2.0 * (x * z + y * w), 2.0 * (y * z - x * w), 1.0 - 2.0 * (x * x + y * y)],
    ]
}

/// The quaternion of a rotation matrix (GLM's `quat_cast`).
pub fn from_matrix(m: &M3) -> Quat {
    let four_x = m[0][0] - m[1][1] - m[2][2];
    let four_y = m[1][1] - m[0][0] - m[2][2];
    let four_z = m[2][2] - m[0][0] - m[1][1];
    let four_w = m[0][0] + m[1][1] + m[2][2];
    let mut biggest = 0;
    let mut four = four_w;
    for (i, v) in [four_x, four_y, four_z].into_iter().enumerate() {
        if v > four {
            four = v;
            biggest = i + 1;
        }
    }
    let big = (four + 1.0).sqrt() * 0.5;
    let k = 0.25 / big;
    match biggest {
        0 => [(m[1][2] - m[2][1]) * k, (m[2][0] - m[0][2]) * k, (m[0][1] - m[1][0]) * k, big],
        1 => [big, (m[0][1] + m[1][0]) * k, (m[2][0] + m[0][2]) * k, (m[1][2] - m[2][1]) * k],
        2 => [(m[0][1] + m[1][0]) * k, big, (m[1][2] + m[2][1]) * k, (m[2][0] - m[0][2]) * k],
        _ => [(m[2][0] + m[0][2]) * k, (m[1][2] + m[2][1]) * k, big, (m[0][1] - m[1][0]) * k],
    }
}

/// The rotation of Euler angles applied about x, then y, then z, as a matrix (`mat::from_trs`).
pub fn euler_matrix(e: V3) -> M3 {
    let (sx, cx) = e[0].sin_cos();
    let (sy, cy) = e[1].sin_cos();
    let (sz, cz) = e[2].sin_cos();
    [
        [cy * cz, cy * sz, -sy],
        [sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy],
        [cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy],
    ]
}

/// The Euler angles (x, y, z) of a rotation matrix: GLM's `extractEulerAngleZYX` on the same
/// memory, the inverse of `euler_matrix`.
pub fn extract_euler(m: &M3) -> V3 {
    let z = m[0][1].atan2(m[0][0]);
    let y = (-m[0][2]).atan2((m[1][2] * m[1][2] + m[2][2] * m[2][2]).sqrt());
    let (sz, cz) = z.sin_cos();
    let x = (sz * m[2][0] - cz * m[2][1]).atan2(cz * m[1][1] - sz * m[1][0]);
    [x, y, z]
}

/// `a * b`, row-vector style: `a` first.
pub fn mul3(a: &M3, b: &M3) -> M3 {
    std::array::from_fn(|i| std::array::from_fn(|j| (0..3).map(|k| a[i][k] * b[k][j]).sum()))
}

/// `v * m`.
pub fn apply(v: V3, m: &M3) -> V3 {
    std::array::from_fn(|j| v[0] * m[0][j] + v[1] * m[1][j] + v[2] * m[2][j])
}

/// The inverse of a 3x3 matrix (zero when it is singular).
pub fn inverse3(m: &M3) -> M3 {
    let c = |r: usize, s: usize, t: usize, u: usize| m[r][s] * m[t][u] - m[r][u] * m[t][s];
    let cof = [
        [c(1, 1, 2, 2), -c(1, 0, 2, 2), c(1, 0, 2, 1)],
        [-c(0, 1, 2, 2), c(0, 0, 2, 2), -c(0, 0, 2, 1)],
        [c(0, 1, 1, 2), -c(0, 0, 1, 2), c(0, 0, 1, 1)],
    ];
    let det = m[0][0] * cof[0][0] + m[0][1] * cof[0][1] + m[0][2] * cof[0][2];
    if det == 0.0 || !det.is_finite() {
        return [[0.0; 3]; 3];
    }
    // The inverse is the transposed cofactor matrix over the determinant.
    std::array::from_fn(|i| std::array::from_fn(|j| cof[j][i] / det))
}

pub fn add(a: V3, b: V3) -> V3 {
    std::array::from_fn(|k| a[k] + b[k])
}

pub fn sub(a: V3, b: V3) -> V3 {
    std::array::from_fn(|k| a[k] - b[k])
}

pub fn scale(a: V3, s: f32) -> V3 {
    a.map(|v| v * s)
}

pub fn lerp(a: V3, b: V3, t: f32) -> V3 {
    std::array::from_fn(|k| a[k] + (b[k] - a[k]) * t)
}

pub fn dot(a: V3, b: V3) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

pub fn cross(a: V3, b: V3) -> V3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

pub fn length(a: V3) -> f32 {
    dot(a, a).sqrt()
}

/// GLM's normalize: divides by the length, so a zero vector gives NaN like Wallpaper Engine.
pub fn normalize3(a: V3) -> V3 {
    scale(a, 1.0 / length(a))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: &[f32], b: &[f32]) -> bool {
        a.iter().zip(b).all(|(a, b)| (a - b).abs() < 1e-4)
    }

    #[test]
    fn euler_matrices_round_trip() {
        let e = [0.3, -0.6, 2.1];
        assert!(close(&extract_euler(&euler_matrix(e)), &e));
        assert!(close(matrix(from_euler(e)).as_flattened(), euler_matrix(e).as_flattened()));
    }

    #[test]
    fn matrices_and_quaternions_round_trip() {
        for e in [[0.3, -0.6, 2.1], [3.0, 0.1, -0.2], [0.0, 3.1, 0.0]] {
            let q = from_euler(e);
            let back = from_matrix(&matrix(q));
            let back = if dot4(q, back) < 0.0 { back.map(|v| -v) } else { back };
            assert!(close(&back, &q), "{q:?} {back:?}");
        }
    }

    #[test]
    fn rotation_takes_one_vector_to_the_other() {
        let (from, to) = (normalize3([1.0, 2.0, 0.5]), normalize3([-0.3, 0.4, 1.0]));
        assert!(close(&apply(from, &matrix(rotation(from, to))), &to));
        let back = apply(from, &matrix(rotation(from, scale(from, -1.0))));
        assert!(close(&back, &scale(from, -1.0)), "{back:?}");
    }

    #[test]
    fn inverse3_undoes_a_matrix() {
        let m = mul3(&euler_matrix([0.2, 0.4, -1.0]), &[[2.0, 0.0, 0.0], [0.0, 3.0, 0.0], [0.0, 0.0, 0.5]]);
        let id = mul3(&m, &inverse3(&m));
        assert!(close(id.as_flattened(), &[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]));
    }
}
