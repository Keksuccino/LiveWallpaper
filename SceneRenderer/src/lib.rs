//! Lean Metal renderer for Wallpaper Engine scenes, exposed to Swift through UniFFI.

#![deny(unsafe_op_in_unsafe_fn)]

pub mod api;
pub mod camera;
pub mod engine;
pub mod gpu;
pub mod light;
pub mod mat;
pub mod model;
pub mod particles;
pub mod pose;
pub mod puppet;
pub mod scene;
pub mod script;
pub mod shader;
pub mod sound;
pub mod tex;
pub mod text;
pub mod timeline;
pub mod vfs;

#[derive(Debug, Clone, PartialEq, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum Error {
    #[error("i/o: {0}")]
    Io(String),
    #[error("bad file: {0}")]
    Format(String),
    #[error("missing file: {0}")]
    Missing(String),
    #[error("unsupported: {0}")]
    Unsupported(String),
    #[error("shader: {0}")]
    Shader(String),
    #[error("metal: {0}")]
    Metal(String),
}

pub use api::{lookup_table, LookupTable, RenderStats, Renderer, SceneProperty};
pub use engine::{framing_view, Alignment, ColorGrade, Framing};

uniffi::setup_scaffolding!();
