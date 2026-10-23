#!/usr/bin/env bash
# Builds the scene renderer (SceneRenderer/, our own Rust + Metal renderer) and regenerates the
# Swift bindings in Sources/SceneBridge. Idempotent: cargo and bindgen only redo what changed.
# Works from any directory. Needs: rustup (~/.cargo/bin) with the stable toolchain.
#   OFFLINE=1 scripts/build-scene-renderer.sh   build from the local cargo cache only
#   UNIVERSAL=1 scripts/build-scene-renderer.sh  arm64 + x86_64 static library (needs both rustup targets)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDERER="$ROOT/SceneRenderer"
OUT="$ROOT/Sources/SceneBridge"
FFI="$OUT/FFI"
BINDGEN="$RENDERER/target/release/uniffi-bindgen"

# rustup installs into ~/.cargo/bin; put it first so a Homebrew cargo does not win. GitHub's macOS
# runners ship cargo/rustup on PATH already.
export PATH="$HOME/.cargo/bin:$PATH"
# The app's own target is macOS 15, so the library is built for the same one.
export MACOSX_DEPLOYMENT_TARGET=15.0

# Respect an explicit CARGO override; otherwise find cargo (PATH first, then rustup's default).
if [[ -n "${CARGO:-}" ]]; then
  CARGO_BIN="$CARGO"
  USE_RUSTUP=0
else
  CARGO_BIN="$(command -v cargo || true)"
  [[ -n "$CARGO_BIN" ]] || CARGO_BIN="$HOME/.cargo/bin/cargo"
  USE_RUSTUP=1
fi
[ -x "$CARGO_BIN" ] || {
  echo "error: cargo not found; install rustup or set CARGO=/path/to/cargo." >&2
  exit 1
}

# SceneRenderer/rust-toolchain.toml pins stable, so ask rustup for it explicitly when available.
CARGO_CMD=("$CARGO_BIN")
if [[ "$USE_RUSTUP" == "1" ]] && command -v rustup >/dev/null 2>&1; then
  CARGO_CMD+=("+stable")
fi

CARGO_FLAGS=(build --release)
if [[ "${OFFLINE:-0}" == "1" ]]; then
  CARGO_FLAGS+=(--offline)
fi

cd "$RENDERER"

echo "--- building SceneRenderer ---"
"${CARGO_CMD[@]}" "${CARGO_FLAGS[@]}" --package scene_renderer

# The bindgen binary is a separate workspace member. If it cannot be built but the bindings are
# already checked in, keep them: the library above is still usable and a warning is clearer than a
# hard failure (for example when the cargo cache lacks the bindgen-only crates).
BINDINGS_PRESENT=0
if [[ -f "$OUT/SceneRenderer.swift" && -f "$FFI/scene_rendererFFI.h" && -f "$FFI/module.modulemap" ]]; then
  BINDINGS_PRESENT=1
fi

BINDGEN_OK=1
if ! "${CARGO_CMD[@]}" "${CARGO_FLAGS[@]}" --package uniffi-bindgen; then
  BINDGEN_OK=0
fi
if [[ "$BINDGEN_OK" == "1" && ! -x "$BINDGEN" ]]; then
  BINDGEN_OK=0
fi

if [[ "$BINDGEN_OK" != "1" ]]; then
  if [[ "$BINDINGS_PRESENT" == "1" ]]; then
    echo "warning: uniffi-bindgen is unavailable; keeping the checked-in bindings in $OUT." >&2
    echo "warning: rerun this script where uniffi-bindgen builds to regenerate them." >&2
    exit 0
  fi
  echo "error: uniffi-bindgen is unavailable and $OUT has no checked-in bindings to use." >&2
  exit 1
fi

mkdir -p "$FFI"
GEN="$(mktemp -d)"; trap 'rm -rf "$GEN"' EXIT
"$BINDGEN" generate --library "$RENDERER/target/release/libscene_renderer.a" \
  --language swift --no-format --out-dir "$GEN"
# SwiftPM layout: the Swift file is target SceneBridge; header + module map form the
# system-library target SceneRendererFFI (SwiftPM wants the name module.modulemap).
cp "$GEN/scene_renderer.swift" "$OUT/SceneRenderer.swift"
cp "$GEN/scene_rendererFFI.h" "$FFI/scene_rendererFFI.h"
cp "$GEN/scene_rendererFFI.modulemap" "$FFI/module.modulemap"
# Swift module names have to start with an upper-case letter, so the generated import and the
# module map are renamed to match the system-library target.
sed -i '' 's/scene_rendererFFI/SceneRendererFFI/g' "$OUT/SceneRenderer.swift"
sed -i '' 's/^module scene_rendererFFI/module SceneRendererFFI/' "$FFI/module.modulemap"
echo "Scene renderer built; bindings in $OUT"

# A universal app needs a universal static library: build the other architecture too and merge them
# into the path Package.swift links from.
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  LIB="$RENDERER/target/release/libscene_renderer.a"
  SLICES=()
  for triple in aarch64-apple-darwin x86_64-apple-darwin; do
    "${CARGO_CMD[@]}" "${CARGO_FLAGS[@]}" --package scene_renderer --target "$triple"
    SLICES+=("$RENDERER/target/$triple/release/libscene_renderer.a")
  done
  lipo -create "${SLICES[@]}" -output "$LIB"
  echo "Universal library: $(lipo -archs "$LIB")"
fi
