//! Lean Metal renderer for Wallpaper Engine scenes, exposed to Swift through UniFFI.

pub mod api;
pub mod engine;
pub mod gpu;
pub mod scene;
pub mod shader;
pub mod tex;
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

pub use api::{RenderStats, Renderer, SceneProperty};

uniffi::setup_scaffolding!();
