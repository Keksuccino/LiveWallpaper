#!/bin/bash
# Builds the macOS port of linux-wallpaperengine (the scene renderer: effects, particles, puppet warp) and installs
# it where the scene host looks for it. Needs: brew install cmake pkg-config glfw glm glew mpv ffmpeg lz4 freetype sdl2-compat
# Usage: scripts/build-wpengine.sh [output-dir]    (default output: ~/Library/Application Support/LiveWallpaper/bin)
set -euo pipefail

FORK=https://github.com/NOOB-3301/linux-wallpaperengine.git   # our fork: the macOS port lives on its mac-port branch
BRANCH=mac-port                                          # upstream commit b016d7d1 plus the port; see ThirdParty/wpengine
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WPENGINE_WORK:-$ROOT/.build/wpengine-src}"
OUT="${1:-$HOME/Library/Application Support/LiveWallpaper/bin}"

if [ ! -d "$WORK/.git" ]; then
  git clone --branch "$BRANCH" "$FORK" "$WORK"
fi
cd "$WORK"
git remote set-url origin "$FORK"
git fetch --quiet origin "$BRANCH"
git checkout --quiet -f -B "$BRANCH" "origin/$BRANCH"
git submodule update --init --depth 1 --quiet

mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > /dev/null
make -j"$(sysctl -n hw.ncpu)"

mkdir -p "$OUT"
cp wpengine "$OUT/wpengine"
echo "installed $OUT/wpengine"
