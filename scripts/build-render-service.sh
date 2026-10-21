#!/bin/bash
# Builds RenderService (WallpaperMachine's Rust/C++ renderer) and regenerates the
# Swift bindings in Sources/RenderBridge. Mirrors WallpaperMachine's scripts/build.py
# (cargo stage + bindgen stage). Idempotent: cargo and bindgen only redo what changed.
# Needs: rustup (~/.cargo/bin), Homebrew deps listed in RenderService/SOURCE.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDERER="$ROOT/RenderService"
OUT="$ROOT/Sources/RenderBridge"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
PREFIX="$(brew --prefix)"

[ -f "$PREFIX/opt/mwe-ffmpeg/lib/pkgconfig/libavcodec.pc" ] || {
  echo "Missing mwe-ffmpeg (LGPL FFmpeg). Install it from RenderService's upstream Formula/mwe-ffmpeg.rb; see RenderService/SOURCE.txt." >&2
  exit 1
}

PACKAGES=(quickjs-ng glslang mwe-ffmpeg freetype lz4 vulkan-loader vulkan-headers molten-vk eigen nlohmann-json argparse shaderc spirv-tools glm)
cmake_roots=""; pkg_paths=""; lib_paths=""
for p in "${PACKAGES[@]}"; do
  cmake_roots+="$PREFIX/opt/$p;"; pkg_paths+="$PREFIX/opt/$p/lib/pkgconfig:"; lib_paths+="$PREFIX/opt/$p/lib:"
done

# Same environment build.py sets. The deployment target goes in under OWE_* only:
# a pinned MACOSX_DEPLOYMENT_TARGET breaks cargo's host proc-macro dylibs.
export PATH="$PREFIX/bin:$HOME/.cargo/bin:$PATH"
export CMAKE_PREFIX_PATH="${cmake_roots}$PREFIX"
export PKG_CONFIG_PATH="${pkg_paths%:}"
export OWE_NIX_LIBRARY_PATH="${lib_paths}$PREFIX/lib"
DEV="$(xcode-select -p)"
if [ -d "$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib" ]; then
  export LIBCLANG_PATH="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib"
else
  export LIBCLANG_PATH="$DEV/usr/lib"  # Command Line Tools only (no Xcode.app)
fi
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC=/usr/bin/clang CXX=/usr/bin/clang++
export OWE_MACOSX_DEPLOYMENT_TARGET=15.0
export GIT_SHORT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
unset MACOSX_DEPLOYMENT_TARGET

cd "$RENDERER"
"$CARGO" build --workspace --release

FFI="$OUT/FFI"
mkdir -p "$FFI"
GEN="$(mktemp -d)"; trap 'rm -rf "$GEN"' EXIT
"$RENDERER/target/release/uniffi-bindgen" generate --library "$RENDERER/target/release/libwallpaper_bridge.a" \
  --language swift --no-format --out-dir "$GEN"
# SwiftPM layout: the Swift file is target RenderBridge; header + module map form the
# system-library target WallpaperBridgeFFI (SwiftPM wants the name module.modulemap).
cp "$GEN/WallpaperBridge.swift" "$OUT/WallpaperBridge.swift"
cp "$GEN/WallpaperBridgeFFI.h" "$FFI/WallpaperBridgeFFI.h"
cp "$GEN/WallpaperBridgeFFI.modulemap" "$FFI/module.modulemap"
echo "RenderService built; bindings in $OUT"
