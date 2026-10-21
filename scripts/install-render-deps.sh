#!/usr/bin/env bash
# Installs the Homebrew packages RenderService/ needs to build (see RenderService/SOURCE.txt), including the
# keg-only LGPL FFmpeg that is not in Homebrew core: its formula lives in this repo (scripts/homebrew/mwe-ffmpeg.rb)
# and is installed through a local tap, so CI does not depend on a third-party tap or a separately published bottle.
# Used by build.yml and release.yml. Linux is not supported (Metal/Vulkan via MoltenVK).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  trap 'echo "::error::install-render-deps.sh failed at line $LINENO: $BASH_COMMAND"' ERR
fi

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

PREFIX="$(brew --prefix)"

# Everything Package.swift links (-lvulkan, -llz4, -lfreetype, -lav*, -lqjs, -lglslang, -lSPIRV) plus the
# cmake/pkgconf/ninja toolchain build.rs needs.
PACKAGES=(
  cmake pkgconf ninja
  quickjs-ng glslang freetype lz4
  vulkan-loader vulkan-headers molten-vk
  eigen nlohmann-json argparse shaderc spirv-tools glm
  dav1d
)

echo "--- installing renderer dependencies ---"
brew install "${PACKAGES[@]}"

# mwe-ffmpeg: keg-only, project-specific LGPL FFmpeg 8.1.2 (libav* only). Regular Homebrew ffmpeg is GPL-3.0
# and cannot be linked into this GPL-2.0-only app, so it is never used.
TAP_DIR="$(brew --repository)/Library/Taps/wallpapermachine/homebrew-local"
if [[ ! -d "$TAP_DIR" ]]; then
  brew tap-new --no-git wallpapermachine/local >/dev/null
fi
mkdir -p "$TAP_DIR/Formula"
cp "$ROOT/scripts/homebrew/mwe-ffmpeg.rb" "$TAP_DIR/Formula/mwe-ffmpeg.rb"
if ! brew list --versions mwe-ffmpeg >/dev/null 2>&1; then
  echo "--- installing mwe-ffmpeg (LGPL FFmpeg) from the vendored formula ---"
  brew install wallpapermachine/local/mwe-ffmpeg
fi

# Preflights: fail here with an annotation instead of deep inside the cargo/cmake log.
[[ -f "$PREFIX/opt/mwe-ffmpeg/lib/pkgconfig/libavcodec.pc" ]] || {
  echo "::error::mwe-ffmpeg did not install libavcodec.pc (see RenderService/SOURCE.txt)"
  exit 1
}
command -v cargo >/dev/null 2>&1 || {
  echo "::error::cargo not found; rustup is required (GitHub's Apple-silicon runners ship it preinstalled)"
  exit 1
}
# RenderService/rust-toolchain.toml pins nightly + aarch64-apple-darwin + rust-src. Install it here so a broken
# rustup fails with this annotation instead of deep inside cargo.
TOOLCHAIN="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$ROOT/RenderService/rust-toolchain.toml")"
if ! rustup toolchain list 2>/dev/null | grep -q "^${TOOLCHAIN}-"; then
  echo "--- installing Rust toolchain $TOOLCHAIN ---"
  rustup toolchain install "$TOOLCHAIN" --profile minimal --component rust-src --target aarch64-apple-darwin
fi
echo "cargo: $(command -v cargo) ($(cargo --version))"
echo "pkg-config: $PREFIX/bin/pkg-config ($("$PREFIX/bin/pkg-config" --version 2>/dev/null || true))"
