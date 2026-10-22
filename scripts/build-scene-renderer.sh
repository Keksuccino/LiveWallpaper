#!/bin/bash
# Builds the scene renderer (SceneRenderer/, our own Rust + Metal renderer) and regenerates the
# Swift bindings in Sources/SceneBridge. Idempotent: cargo and bindgen only redo what changed.
# Needs: rustup (~/.cargo/bin) with the stable toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDERER="$ROOT/SceneRenderer"
OUT="$ROOT/Sources/SceneBridge"
# rustup installs into ~/.cargo/bin, but GitHub's macOS runners also ship cargo/rustup in Homebrew's
# bin, so resolve it from PATH when the user-local copy is absent.
CARGO="${CARGO:-$(command -v cargo || echo "$HOME/.cargo/bin/cargo")}"
[ -x "$CARGO" ] || { echo "cargo not found (set CARGO=/path/to/cargo); rustup is required." >&2; exit 1; }

export PATH="$HOME/.cargo/bin:$PATH"
# The app's own target is macOS 15, so the library is built for the same one.
export MACOSX_DEPLOYMENT_TARGET=15.0

cd "$RENDERER"
"$CARGO" build --release --package scene_renderer
"$CARGO" build --release --package uniffi-bindgen

FFI="$OUT/FFI"
mkdir -p "$FFI"
GEN="$(mktemp -d)"; trap 'rm -rf "$GEN"' EXIT
"$RENDERER/target/release/uniffi-bindgen" generate --library "$RENDERER/target/release/libscene_renderer.a" \
  --language swift --no-format --out-dir "$GEN"
# SwiftPM layout: the Swift file is target SceneBridge; header + module map form the
# system-library target SceneRendererFFI (SwiftPM wants the name module.modulemap).
cp "$GEN/scene_renderer.swift" "$OUT/SceneRenderer.swift"
cp "$GEN/scene_rendererFFI.h" "$FFI/scene_rendererFFI.h"
cp "$GEN/scene_rendererFFI.modulemap" "$FFI/module.modulemap"
# Swift module names have to start with an upper-case letter, so the generated import and the
# module map are renamed to match the system-library target.
sed -i '' 's/scene_rendererFFI/SceneRendererFFI/g' "$OUT/SceneRenderer.swift" "$FFI/module.modulemap"
echo "Scene renderer built; bindings in $OUT"
