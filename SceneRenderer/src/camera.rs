//! The scene camera: how a 3D scene is projected, camera paths that move it, and camera shake.
//!
//! Matrices are column-major `[f32; 16]` for column vectors, the layout the engine hands to
//! shaders. World space is right-handed and y up, as the scene files store it; clip space is
//! Metal's (y up, depth 0 at the near plane and 1 at the far plane).
//!
//! What follows Wallpaper Engine: a scene without a sized or automatic
//! `general.orthogonalprojection` is seen through a perspective camera with a vertical field of view of `general.fov` degrees (default 50, clamped
//! to 0.1...179.9), planes at `nearz` (0.1) and `farz` (10000) and the target's aspect ratio, so
//! the alignment options do not apply; the view is a right-handed look-at from `camera.eye` to
//! `camera.center` with `camera.up`. Camera path keyframes, their timing and the way paths hand
//! over to each other, and the shake's motion, were read from how the engine updates its camera.

use serde_json::Value;

use crate::scene::floats;
use crate::vfs::Vfs;

pub type Mat4 = [f32; 16];
type V3 = [f32; 3];

/// One keyframe of a camera path: when, and where the camera is.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Key {
    /// Seconds from the start of the path.
    pub time: f32,
    pub pose: Pose,
}

/// Where the camera is and where it looks.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pose {
    pub eye: V3,
    pub center: V3,
    pub up: V3,
    pub zoom: f32,
}

/// A camera path (`scripts/camera_XX.json`): keyframes in time order and the path's duration.
#[derive(Debug, Clone, PartialEq)]
pub struct Path {
    pub duration: f32,
    pub keys: Vec<Key>,
}

impl Path {
    /// When the camera moves on to the next path, in seconds from this one's start: at the first
    /// later keyframe at or past the duration; otherwise once the time is past both the last
    /// keyframe and the duration minus the last keyframe's time. The second rule is the engine's:
    /// a path whose last keyframe is at 40 s of 300 holds that keyframe until 260 s.
    pub fn length(&self) -> f32 {
        let Some(last) = self.keys.last() else {
            return 0.0;
        };
        self.keys[1..]
            .iter()
            .find(|k| k.time >= self.duration)
            .map_or(last.time.max(self.duration - last.time), |k| k.time)
    }

    /// The pose `t` seconds into the path: the keyframe before `t` eased into the next one. The
    /// ease is a cubic Hermite curve whose two tangents are both half the step between the
    /// keyframes; before the first keyframe and after the last the camera holds still.
    pub fn pose_at(&self, t: f32) -> Option<Pose> {
        let first = self.keys.first()?;
        let k = self.keys.iter().rposition(|k| k.time <= t);
        let (a, b) = match k {
            None => return Some(first.pose),
            Some(k) if k + 1 == self.keys.len() => return Some(self.keys[k].pose),
            Some(k) => (&self.keys[k], &self.keys[k + 1]),
        };
        let span = b.time - a.time;
        let s = if span > 0.0 {
            ((t - a.time) / span).clamp(0.0, 1.0)
        } else {
            1.0
        };
        // h01 + (h10 + h11) / 2 of the Hermite basis: 0 at s = 0, 1 at s = 1, slope 1/2 at both.
        let w = s * (0.5 + s * (1.5 - s));
        let mix = |p: V3, q: V3| [0, 1, 2].map(|i| p[i] + (q[i] - p[i]) * w);
        Some(Pose {
            eye: mix(a.pose.eye, b.pose.eye),
            center: mix(a.pose.center, b.pose.center),
            up: mix(a.pose.up, b.pose.up),
            zoom: a.pose.zoom + (b.pose.zoom - a.pose.zoom) * w,
        })
    }

    fn parse(json: &Value) -> Option<Self> {
        if json["disabled"].as_bool() == Some(true) {
            return None;
        }
        let duration = json["duration"].as_f64().unwrap_or(0.0) as f32;
        let transforms = json["transforms"].as_array().filter(|t| !t.is_empty())?;
        let n = transforms.len();
        let keys = transforms
            .iter()
            .enumerate()
            .filter(|(_, t)| t["disabled"].as_bool() != Some(true))
            .map(|(i, t)| Key {
                // Without a timestamp the keyframes spread evenly over the duration.
                time: t["timestamp"].as_f64().map_or_else(
                    || {
                        if n > 1 {
                            i as f32 / (n - 1) as f32 * duration
                        } else {
                            0.0
                        }
                    },
                    |v| v as f32,
                ),
                pose: Pose {
                    eye: vec3(&t["eye"], [0.0; 3]),
                    center: vec3(&t["center"], [0.0; 3]),
                    up: vec3(&t["up"], [0.0; 3]),
                    zoom: t["zoom"].as_f64().map_or(1.0, |z| z as f32),
                },
            })
            .collect::<Vec<_>>();
        (!keys.is_empty()).then_some(Self { duration, keys })
    }
}

/// The scene camera as `scene.json` describes it.
#[derive(Debug, Clone, PartialEq)]
pub struct Camera {
    /// No `general.orthogonalprojection`: the scene is seen through a perspective camera.
    pub perspective: bool,
    pub pose: Pose,
    /// Vertical field of view in degrees.
    pub fov: f32,
    pub near: f32,
    pub far: f32,
    /// Played one after the other, in a loop; empty when the camera stands still.
    pub paths: Vec<Path>,
}

impl Camera {
    /// The camera of a scene file, with the paths its `camera.paths` files hold.
    pub fn load(vfs: &Vfs, scene: &Value, warnings: &mut Vec<String>) -> Self {
        let general = &scene["general"];
        let camera = &scene["camera"];
        let num = |key: &str, default: f32| general[key].as_f64().map_or(default, |v| v as f32);
        let mut paths = Vec::new();
        for file in camera["paths"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            match vfs.json(file) {
                Ok(json) => paths.extend(
                    json["paths"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(Path::parse),
                ),
                Err(e) => warnings.push(format!("camera path {file}: {e}")),
            }
        }
        // Orthographic when the projection is automatic or has a size, as the engine decides it.
        let ortho = &general["orthogonalprojection"];
        let sized = |key: &str| ortho[key].as_f64().is_some_and(|v| v != 0.0);
        let orthographic = ortho.is_object()
            && (ortho["auto"].as_bool() == Some(true) || (sized("width") && sized("height")));
        Self {
            perspective: !orthographic,
            // The engine's camera before a scene sets one.
            pose: Pose {
                eye: vec3(&camera["eye"], [2.0, 2.0, 2.0]),
                center: vec3(&camera["center"], [0.0; 3]),
                up: vec3(&camera["up"], [0.0, 1.0, 0.0]),
                zoom: 1.0,
            },
            fov: num("fov", 50.0).clamp(0.1, 179.9),
            near: num("nearz", 0.1),
            far: num("farz", 10_000.0),
            paths,
        }
    }

    /// Where the camera is `time` seconds into the scene: on its paths, which loop, or standing.
    /// A path that ends as it starts takes no time.
    pub fn pose_at(&self, time: f32) -> Pose {
        let total: f32 = self
            .paths
            .iter()
            .map(Path::length)
            .filter(|l| *l > 0.0)
            .sum();
        if total <= 0.0 {
            return self
                .paths
                .first()
                .and_then(|p| p.pose_at(0.0))
                .unwrap_or(self.pose);
        }
        let mut t = time.rem_euclid(total);
        for path in &self.paths {
            let length = path.length();
            if length <= 0.0 {
                continue;
            }
            if t < length {
                return path.pose_at(t).unwrap_or(self.pose);
            }
            t -= length;
        }
        self.pose
    }

    /// Whether the paths move the camera at all.
    pub fn moves(&self) -> bool {
        self.paths.len() > 1
            || self
                .paths
                .iter()
                .any(|p| p.keys.windows(2).any(|w| w[0].pose != w[1].pose))
    }
}

fn vec3(v: &Value, default: V3) -> V3 {
    let f = floats(v);
    if f.len() < 3 {
        return default;
    }
    [f[0], f[1], f[2]]
}

fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn dot(a: V3, b: V3) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn cross(a: V3, b: V3) -> V3 {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

fn normalize(v: V3) -> Option<V3> {
    let len = dot(v, v).sqrt();
    (len > 1e-12).then(|| v.map(|c| c / len))
}

/// The right-handed view matrix of a camera at `eye` looking at `center`: the camera looks down
/// its own -z with `up` (projected) as +y. An `up` along the view direction is replaced by the
/// world axis least aligned with it.
pub fn look_at(eye: V3, center: V3, up: V3) -> Mat4 {
    let f = normalize(sub(center, eye)).unwrap_or([0.0, 0.0, -1.0]);
    let s = normalize(cross(f, up)).unwrap_or_else(|| {
        let axis = if f[1].abs() < 0.9 {
            [0.0, 1.0, 0.0]
        } else {
            [1.0, 0.0, 0.0]
        };
        normalize(cross(f, axis)).unwrap_or([1.0, 0.0, 0.0])
    });
    let u = cross(s, f);
    // One column per line.
    #[rustfmt::skip]
    let view = [
        s[0], u[0], -f[0], 0.0,
        s[1], u[1], -f[1], 0.0,
        s[2], u[2], -f[2], 0.0,
        -dot(s, eye), -dot(u, eye), dot(f, eye), 1.0,
    ];
    view
}

/// A right-handed perspective projection to Metal clip space: `fov` is the vertical field of view
/// in degrees, depth runs from 0 at `near` to 1 at `far`. `mirror` flips it left to right.
pub fn perspective(fov: f32, aspect: f32, near: f32, far: f32, mirror: bool) -> Mat4 {
    let f = 1.0 / (fov.to_radians() * 0.5).tan();
    let depth = far / (near - far);
    let sx = f / aspect.max(1e-6) * if mirror { -1.0 } else { 1.0 };
    // One column per line.
    #[rustfmt::skip]
    let projection = [
        sx, 0.0, 0.0, 0.0,
        0.0, f, 0.0, 0.0,
        0.0, 0.0, depth, -1.0,
        0.0, 0.0, near * depth, 0.0,
    ];
    projection
}

/// The projection of an orthographic (2D) scene for objects placed in 3D. The scene files are y up
/// from the design's bottom-left corner; `view` is the visible part of the design in the 2D
/// renderer's terms (left, right, top, bottom, y down from the top-left), and `height` the
/// design's height. Depth covers -2000...2000 along z, the engine's range for these scenes: 0 in
/// front at z = 2000, 0.5 at z = 0 where the 2D layers lie.
pub fn orthographic(view: [f32; 4], height: f32) -> Mat4 {
    let [l, r, t, b] = view;
    let mut m = [0.0; 16];
    m[0] = 2.0 / (r - l);
    m[5] = 2.0 / (b - t);
    m[10] = -1.0 / 4000.0;
    m[12] = -(r + l) / (r - l);
    m[13] = (2.0 * height - t - b) / (t - b);
    m[14] = 0.5;
    m[15] = 1.0;
    m
}

/// How far the shake moves the camera at `time`, in world units: a loop through
/// `(cos p, sin 1.333p, sin p)` with `p = speed² · time`, scaled by a tenth of the amplitude.
/// Roughness above 0.1 bends the loop: its length is raised to the roughness cubed.
pub fn shake([amplitude, roughness, speed]: [f32; 3], time: f32) -> V3 {
    let p = speed * speed * time;
    let mut v = [p.cos(), (p * 1.333).sin(), p.sin()];
    let power = roughness.powi(3);
    if power > 0.001 && power != 1.0 {
        let len = dot(v, v).sqrt();
        if len > 1e-6 {
            let k = len.powf(power) / len;
            v = v.map(|c| c * k);
        }
    }
    v.map(|c| c * amplitude * 0.1)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Transforms a point with a column-major matrix, then divides by w.
    fn project(m: &Mat4, p: V3) -> V3 {
        let c = |r: usize| m[r] * p[0] + m[4 + r] * p[1] + m[8 + r] * p[2] + m[12 + r];
        let w = c(3);
        [c(0) / w, c(1) / w, c(2) / w]
    }

    fn close(a: V3, b: V3) -> bool {
        a.iter().zip(b).all(|(a, b)| (a - b).abs() < 1e-4)
    }

    fn key(time: f32, x: f32) -> Key {
        Key {
            time,
            pose: Pose {
                eye: [x, 0.0, 0.0],
                center: [x, 0.0, -1.0],
                up: [0.0, 1.0, 0.0],
                zoom: 1.0,
            },
        }
    }

    #[test]
    fn the_view_puts_the_eye_at_the_origin_looking_down_minus_z() {
        let view = look_at([1.0, 2.0, 3.0], [1.0, 2.0, 0.0], [0.0, 1.0, 0.0]);
        assert!(close(project(&view, [1.0, 2.0, 3.0]), [0.0, 0.0, 0.0]));
        assert!(close(project(&view, [1.0, 2.0, 0.0]), [0.0, 0.0, -3.0]));
        // World +x stays on the right, +y up.
        assert!(close(project(&view, [2.0, 3.0, 3.0]), [1.0, 1.0, 0.0]));
        // An up along the view direction still gives a valid view.
        let down = look_at([0.0, 5.0, 0.0], [0.0, 0.0, 0.0], [0.0, 1.0, 0.0]);
        assert!(down.iter().all(|v| v.is_finite()));
    }

    #[test]
    fn the_projection_maps_the_planes_to_metal_depth() {
        let p = perspective(90.0, 2.0, 0.5, 100.0, false);
        assert!(close(project(&p, [0.0, 0.0, -0.5]), [0.0, 0.0, 0.0]));
        assert!(close(project(&p, [0.0, 0.0, -100.0]), [0.0, 0.0, 1.0]));
        // A 90 degree vertical field of view: y = -z reaches the top edge; x is squeezed by the
        // aspect ratio.
        assert!(close(
            project(&p, [2.0, 1.0, -1.0]),
            [1.0, 1.0, project(&p, [0.0, 0.0, -1.0])[2]]
        ));
        let mirrored = perspective(90.0, 2.0, 0.5, 100.0, true);
        assert!((project(&mirrored, [2.0, 0.0, -1.0])[0] + 1.0).abs() < 1e-4);
    }

    #[test]
    fn the_orthographic_projection_matches_the_2d_view() {
        // A 1920x1080 design shown whole: file y up, so the design's top-left (0, 1080) is the
        // clip space top-left.
        let m = orthographic([0.0, 1920.0, 0.0, 1080.0], 1080.0);
        assert!(close(project(&m, [0.0, 1080.0, 0.0]), [-1.0, 1.0, 0.5]));
        assert!(close(project(&m, [1920.0, 0.0, 2000.0]), [1.0, -1.0, 0.0]));
        assert!(close(project(&m, [960.0, 540.0, -2000.0]), [0.0, 0.0, 1.0]));
    }

    #[test]
    fn a_path_eases_between_keyframes_and_holds_at_the_ends() {
        let path = Path {
            duration: 10.0,
            keys: vec![key(2.0, 0.0), key(6.0, 4.0)],
        };
        assert_eq!(path.pose_at(0.0).unwrap().eye[0], 0.0);
        assert_eq!(path.pose_at(9.0).unwrap().eye[0], 4.0);
        // Halfway in time is halfway in place; a quarter in is less than a quarter of the way.
        assert!((path.pose_at(4.0).unwrap().eye[0] - 2.0).abs() < 1e-5);
        let quarter = path.pose_at(3.0).unwrap().eye[0];
        assert!(quarter > 0.0 && quarter < 1.0, "{quarter}");
    }

    #[test]
    fn paths_hand_over_by_the_engines_rules() {
        // The last keyframe at or past the duration ends the path there.
        assert_eq!(
            Path {
                duration: 30.0,
                keys: vec![key(0.0, 0.0), key(30.0, 1.0)]
            }
            .length(),
            30.0
        );
        // A keyframe before the duration: held until duration minus its time.
        assert_eq!(
            Path {
                duration: 300.0,
                keys: vec![key(0.0, 0.0), key(40.0, 1.0)]
            }
            .length(),
            260.0
        );
        assert_eq!(
            Path {
                duration: 50.0,
                keys: vec![key(0.0, 0.0), key(40.0, 1.0)]
            }
            .length(),
            40.0
        );
        // A later keyframe past the duration ends it even when more follow.
        let early = Path {
            duration: 15.0,
            keys: vec![
                key(0.0, 0.0),
                key(10.0, 1.0),
                key(20.0, 2.0),
                key(30.0, 3.0),
            ],
        };
        assert_eq!(early.length(), 20.0);
        let camera = Camera {
            perspective: true,
            pose: key(0.0, 9.0).pose,
            fov: 50.0,
            near: 0.1,
            far: 100.0,
            paths: vec![
                Path {
                    duration: 10.0,
                    keys: vec![key(0.0, 0.0), key(10.0, 1.0)],
                },
                Path {
                    duration: 5.0,
                    keys: vec![key(0.0, 5.0)],
                },
            ],
        };
        // The second path starts after the first one's 10 seconds; then the first one loops.
        assert_eq!(camera.pose_at(12.0).eye[0], 5.0);
        assert!((camera.pose_at(15.0 + 5.0).eye[0] - 0.5).abs() < 1e-5);
        assert!(camera.moves());
    }

    #[test]
    fn keyframes_without_timestamps_spread_over_the_duration() {
        let json = serde_json::json!({
            "duration": 8.0,
            "transforms": [
                {"eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"},
                {"eye": "1 0 0", "center": "1 0 -1", "up": "0 1 0", "disabled": true},
                {"eye": "2 0 0", "center": "2 0 -1", "up": "0 1 0", "zoom": 2.0},
            ]
        });
        let path = Path::parse(&json).expect("a path");
        assert_eq!(
            path.keys.iter().map(|k| k.time).collect::<Vec<_>>(),
            vec![0.0, 8.0]
        );
        assert_eq!(path.keys[1].pose.zoom, 2.0);
    }

    #[test]
    fn the_shake_is_a_tenth_of_the_amplitude_and_bent_by_roughness() {
        let v = shake([0.5, 1.0, 3.0], 0.0);
        assert!(close(v, [0.05, 0.0, 0.0]));
        let t = 0.37;
        let plain = shake([1.0, 1.0, 2.0], t);
        let rough = shake([1.0, 2.0, 2.0], t);
        let len = |v: V3| dot(v, v).sqrt();
        // Same direction, the length raised to the eighth power (roughness 2 cubed).
        assert!(close(normalize(plain).unwrap(), normalize(rough).unwrap()));
        assert!((len(rough) - (len(plain) * 10.0).powf(8.0) * 0.1).abs() < 1e-4);
    }
}
