#!/bin/bash
# Builds the macOS port of linux-wallpaperengine (the scene renderer: effects, particles, puppet warp) and installs
# it where the scene host looks for it. Needs: brew install cmake pkg-config glfw glm glew mpv ffmpeg lz4 freetype sdl2-compat
# Usage: scripts/build-wpengine.sh [output-dir]    (default output: ~/Library/Application Support/LiveWallpaper/bin)
set -euo pipefail

PINNED=b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d          # upstream commit the patch was made against
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WPENGINE_WORK:-$ROOT/.build/wpengine-src}"
OUT="${1:-$HOME/Library/Application Support/LiveWallpaper/bin}"

if [ ! -d "$WORK/.git" ]; then
  git clone https://github.com/Almamu/linux-wallpaperengine.git "$WORK"
fi
cd "$WORK"
git fetch --quiet origin "$PINNED" 2>/dev/null || true
git checkout --quiet -f "$PINNED"
git submodule update --init --depth 1 --quiet
git checkout --quiet -- .          # drop a previous patch so it applies cleanly
git apply "$ROOT/ThirdParty/wpengine/macos.patch"

mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > /dev/null
make -j"$(sysctl -n hw.ncpu)"

mkdir -p "$OUT"
cp wpengine "$OUT/wpengine"
echo "installed $OUT/wpengine"
