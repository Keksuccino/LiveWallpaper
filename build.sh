#!/usr/bin/env bash
# Builds build/LiveWallpaper.app (the Settings app) with the two helper apps nested inside it at
#   Contents/Library/LoginItems/LiveWallpaperAgent.app        (plays videos, menu bar item; AppKit only)
#   Contents/Library/LoginItems/LiveWallpaperSceneHost.app    (plays scenes, renders lock screen loops; Metal)
# and signs everything ad hoc, inner bundles first.
#   CONFIG=debug ./build.sh      debug build (default: release)
#   UNIVERSAL=1 ./build.sh       arm64 + x86_64 binaries
#   VERSION=1.2.3 ./build.sh     writes the version into all three Info.plists (digits and dots only; default: as in the plists)
#   BUILD_NUMBER=45 ./build.sh   CFBundleVersion used with VERSION (default: VERSION itself)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="build/LiveWallpaper.app"
HELPERS="$APP/Contents/Library/LoginItems"
AGENT="$HELPERS/LiveWallpaperAgent.app"
HOST="$HELPERS/LiveWallpaperSceneHost.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# The expansion form keeps an empty array safe under `set -u` on macOS's bash 3.2.
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$AGENT/Contents/MacOS" "$AGENT/Contents/Resources" \
         "$HOST/Contents/MacOS" "$HOST/Contents/Resources"

cp "$BIN_DIR/LiveWallpaper" "$APP/Contents/MacOS/LiveWallpaper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp "$BIN_DIR/LiveWallpaperAgent" "$AGENT/Contents/MacOS/LiveWallpaperAgent"
cp Resources/Agent-Info.plist "$AGENT/Contents/Info.plist"
printf 'APPL????' > "$AGENT/Contents/PkgInfo"

cp "$BIN_DIR/LiveWallpaperSceneHost" "$HOST/Contents/MacOS/LiveWallpaperSceneHost"
cp Resources/SceneHost-Info.plist "$HOST/Contents/Info.plist"
printf 'APPL????' > "$HOST/Contents/PkgInfo"

# Version injection: the same version in all three bundles (the Settings app compares the running agent's version
# with its own to detect an agent left over from an older build).
if [[ -n "${VERSION:-}" ]]; then
  for plist in "$APP/Contents/Info.plist" "$AGENT/Contents/Info.plist" "$HOST/Contents/Info.plist"; do
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
    plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-$VERSION}" "$plist"
  done
fi

plutil -lint "$APP/Contents/Info.plist" "$AGENT/Contents/Info.plist" "$HOST/Contents/Info.plist"

# Guards (RAM plan, SPEC3.md section 8). Executable targets link their library targets statically, so a library is
# detected by the module name that Swift embeds in symbol names ("<length><name>", e.g. 11SceneEngine).
AGENT_BIN="$AGENT/Contents/MacOS/LiveWallpaperAgent"
AGENT_LIBS="$(otool -L "$AGENT_BIN")"
if grep -q "SwiftUI" <<<"$AGENT_LIBS"; then
  echo "error: LiveWallpaperAgent links SwiftUI; the agent must stay AppKit only." >&2
  exit 1
fi
if grep -Eq "Metal|MetalKit" <<<"$AGENT_LIBS"; then
  echo "error: LiveWallpaperAgent links Metal; scenes belong in LiveWallpaperSceneHost." >&2
  exit 1
fi
if strings -a "$AGENT_BIN" | grep -Eq "11SceneEngine|11SceneFormat"; then
  echo "error: LiveWallpaperAgent contains SceneEngine or SceneFormat code; it must only depend on Core." >&2
  exit 1
fi
if grep -q "Combine" <<<"$AGENT_LIBS"; then
  echo "warning: LiveWallpaperAgent links Combine; something imports it (check Core and the agent files)." >&2
fi
SETTINGS_BIN="$APP/Contents/MacOS/LiveWallpaper"
if strings -a "$SETTINGS_BIN" | grep -q "11SceneEngine"; then
  echo "error: the Settings app contains SceneEngine code; it may use SceneFormat (parsing) but never the renderer." >&2
  exit 1
fi
HOST_BIN="$HOST/Contents/MacOS/LiveWallpaperSceneHost"
if ! strings -a "$HOST_BIN" | grep -q "11SceneEngine"; then
  echo "warning: LiveWallpaperSceneHost does not contain SceneEngine code (is the target wired up?)." >&2
fi
if grep -q "SwiftUI" <<<"$(otool -L "$HOST_BIN")"; then
  echo "warning: LiveWallpaperSceneHost links SwiftUI; the host has no UI, keep it AppKit + Metal." >&2
fi

# Sign the nested helpers first, then the outer app. No --deep: each bundle is signed on its own.
codesign --force --sign - "$HOST"
codesign --force --sign - "$AGENT"
codesign --force --sign - "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP (with $AGENT and $HOST)"
echo "Run it with: open $APP"
