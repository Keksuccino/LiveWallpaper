//! Small row-vector 4x4 helpers for puppet skinning.
//!
//! A point is transformed as `p' = p * M`, so a child's matrix is
//! `child_local * parent_world` and the translation lives in row 3.

pub type M4 = [[f32; 4]; 4];

pub const IDENTITY: M4 = [
    [1., 0., 0., 0.],
    [0., 1., 0., 0.],
    [0., 0., 1., 0.],
    [0., 0., 0., 1.],
];

pub fn mul(a: &M4, b: &M4) -> M4 {
    let mut out = [[0.0f32; 4]; 4];
    for (i, row) in out.iter_mut().enumerate() {
        for (j, cell) in row.iter_mut().enumerate() {
            *cell = (0..4).map(|k| a[i][k] * b[k][j]).sum();
        }
    }
    out
}

/// The local transform a bone track describes, in row-vector order: scale, then rotation about
/// x, y and z, then translation (`S * Rx * Ry * Rz * T`).
pub fn from_trs(t: [f32; 3], r: [f32; 3], s: [f32; 3]) -> M4 {
    let (sx, cx) = r[0].sin_cos();
    let (sy, cy) = r[1].sin_cos();
    let (sz, cz) = r[2].sin_cos();
    let rx = [[1., 0., 0., 0.], [0., cx, sx, 0.], [0., -sx, cx, 0.], [0., 0., 0., 1.]];
    let ry = [[cy, 0., -sy, 0.], [0., 1., 0., 0.], [sy, 0., cy, 0.], [0., 0., 0., 1.]];
    let rz = [[cz, sz, 0., 0.], [-sz, cz, 0., 0.], [0., 0., 1., 0.], [0., 0., 0., 1.]];
    let scale = [[s[0], 0., 0., 0.], [0., s[1], 0., 0.], [0., 0., s[2], 0.], [0., 0., 0., 1.]];
    let mut m = mul(&mul(&mul(&mul(&scale, &rx), &ry), &rz), &IDENTITY);
    m[3] = [t[0], t[1], t[2], 1.0];
    m
}

/// Translation (row 3), Euler angles (as `from_trs` applies them) and scale of an affine matrix.
pub fn decompose(m: &M4) -> ([f32; 3], [f32; 3], [f32; 3]) {
    let len = |row: &[f32; 4]| (row[0] * row[0] + row[1] * row[1] + row[2] * row[2]).sqrt();
    let (sx, sy, sz) = (len(&m[0]), len(&m[1]), len(&m[2]));
    let (sx, sy, sz) = (sx.max(1e-6), sy.max(1e-6), sz.max(1e-6));
    let r = [
        [m[0][0] / sx, m[0][1] / sx, m[0][2] / sx],
        [m[1][0] / sy, m[1][1] / sy, m[1][2] / sy],
        [m[2][0] / sz, m[2][1] / sz, m[2][2] / sz],
    ];
    let ry = (-r[0][2]).asin();
    let (rx, rz) = if ry.cos().abs() > 1e-6 {
        (
            (r[1][2] / ry.cos()).atan2(r[2][2] / ry.cos()),
            (r[0][1] / ry.cos()).atan2(r[0][0] / ry.cos()),
        )
    } else {
        ((r[2][1]).atan2(r[1][1]), 0.0)
    };
    ([m[3][0], m[3][1], m[3][2]], [rx, ry, rz], [sx, sy, sz])
}

/// General inverse. Bones are rigid, so this is only slightly more work than an affine inverse
/// and cannot divide by a zero scale.
pub fn invert(m: &M4) -> M4 {
    let mut a = *m;
    let mut inv = IDENTITY;
    for col in 0..4 {
        let mut pivot = col;
        for row in (col + 1)..4 {
            if a[row][col].abs() > a[pivot][col].abs() {
                pivot = row;
            }
        }
        a.swap(col, pivot);
        inv.swap(col, pivot);
        let d = a[col][col];
        if d.abs() < 1e-12 {
            return IDENTITY;
        }
        for k in 0..4 {
            a[col][k] /= d;
            inv[col][k] /= d;
        }
        for row in 0..4 {
            if row == col {
                continue;
            }
            let f = a[row][col];
            if f == 0.0 {
                continue;
            }
            for k in 0..4 {
                a[row][k] -= f * a[col][k];
                inv[row][k] -= f * inv[col][k];
            }
        }
    }
    inv
}

pub fn point(m: &M4, p: [f32; 3]) -> [f32; 3] {
    [
        p[0] * m[0][0] + p[1] * m[1][0] + p[2] * m[2][0] + m[3][0],
        p[0] * m[0][1] + p[1] * m[1][1] + p[2] * m[2][1] + m[3][1],
        p[0] * m[0][2] + p[1] * m[1][2] + p[2] * m[2][2] + m[3][2],
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-4
    }

    #[test]
    fn trs_translates_rotates_and_scales() {
        let m = from_trs([10.0, 20.0, 0.0], [0.0, 0.0, std::f32::consts::FRAC_PI_2], [2.0, 3.0, 1.0]);
        let p = point(&m, [1.0, 0.0, 0.0]);
        assert!(close(p[0], 10.0), "{p:?}");
        assert!(close(p[1], 22.0), "{p:?}");
    }

    #[test]
    fn decompose_round_trips() {
        let t = [3.0, -4.0, 0.5];
        let r = [0.1, -0.2, 0.7];
        let s = [2.0, 0.5, 1.5];
        let (t2, r2, s2) = decompose(&from_trs(t, r, s));
        assert!(close(t2[0], t[0]) && close(t2[1], t[1]), "{t2:?}");
        assert!(close(r2[2], r[2]), "{r2:?}");
        assert!(close(s2[0], s[0]) && close(s2[1], s[1]), "{s2:?}");
    }

    #[test]
    fn inverse_undoes_the_transform() {
        let m = from_trs([5.0, 6.0, 0.0], [0.3, 0.0, 1.1], [2.0, 2.0, 1.0]);
        let p = point(&mul(&m, &invert(&m)), [7.0, -9.0, 0.0]);
        assert!(close(p[0], 7.0) && close(p[1], -9.0), "{p:?}");
    }
}
