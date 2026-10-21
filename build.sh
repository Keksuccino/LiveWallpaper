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

# On GitHub Actions a failing command becomes a visible annotation (the raw log is not always reachable).
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  trap 'echo "::error::build.sh failed at line $LINENO: $BASH_COMMAND"' ERR
fi

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
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp "$BIN_DIR/LiveWallpaperAgent" "$AGENT/Contents/MacOS/LiveWallpaperAgent"
cp Resources/Agent-Info.plist "$AGENT/Contents/Info.plist"
printf 'APPL????' > "$AGENT/Contents/PkgInfo"

cp "$BIN_DIR/LiveWallpaperSceneHost" "$HOST/Contents/MacOS/LiveWallpaperSceneHost"
cp Resources/SceneHost-Info.plist "$HOST/Contents/Info.plist"
printf 'APPL????' > "$HOST/Contents/PkgInfo"

# The ported scene renderer (scripts/build-wpengine.sh). Optional: without it the host falls back to its own Metal path.
WPENGINE_BIN="${WPENGINE_BIN:-$HOME/Library/Application Support/LiveWallpaper/bin/wpengine}"
if [[ -x "$WPENGINE_BIN" ]]; then
  cp "$WPENGINE_BIN" "$HOST/Contents/MacOS/wpengine"
  python3 scripts/bundle-dylibs.py "$HOST/Contents/MacOS/wpengine" "$HOST/Contents/Frameworks"
else
  echo "warning: no wpengine binary at $WPENGINE_BIN (run scripts/build-wpengine.sh); scenes will use the basic renderer."
fi

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
# detected by the module name that Swift embeds in symbol names ("<length><name>", e.g. 11SceneEngine). The Metal
# framework itself is NOT a usable signal: the AppKit Swift overlays pull Metal into every AppKit app, so the check
# looks for Metal API use by our code (mangled module name 5Metal, MTL/CAMetalLayer symbols) and for MetalKit.
AGENT_BIN="$AGENT/Contents/MacOS/LiveWallpaperAgent"
AGENT_LIBS="$(otool -L "$AGENT_BIN")"
AGENT_STRINGS="$(strings -a "$AGENT_BIN")"
echo "--- libraries linked by the agent ---"
echo "$AGENT_LIBS"
if grep -q "SwiftUI" <<<"$AGENT_LIBS"; then
  echo "::error::LiveWallpaperAgent links SwiftUI; the agent must stay AppKit only."
  exit 1
fi
if grep -q "MetalKit" <<<"$AGENT_LIBS" || grep -Eq "5Metal[A-Z]|MTLCreateSystemDefaultDevice|CAMetalLayer" <<<"$AGENT_STRINGS"; then
  echo "::error::LiveWallpaperAgent uses Metal; scenes belong in LiveWallpaperSceneHost."
  exit 1
fi
if grep -Eq "11SceneEngine|11SceneFormat" <<<"$AGENT_STRINGS"; then
  echo "::error::LiveWallpaperAgent contains SceneEngine or SceneFormat code; it must only depend on Core."
  exit 1
fi
if grep -q "Combine" <<<"$AGENT_LIBS"; then
  echo "warning: LiveWallpaperAgent links Combine; something imports it (check Core and the agent files)."
fi
SETTINGS_BIN="$APP/Contents/MacOS/LiveWallpaper"
if grep -q "11SceneEngine" <<<"$(strings -a "$SETTINGS_BIN")"; then
  echo "::error::the Settings app contains SceneEngine code; it may use SceneFormat (parsing) but never the renderer."
  exit 1
fi
HOST_BIN="$HOST/Contents/MacOS/LiveWallpaperSceneHost"
if ! grep -q "11SceneEngine" <<<"$(strings -a "$HOST_BIN")"; then
  echo "warning: LiveWallpaperSceneHost does not contain SceneEngine code (is the target wired up?)."
fi
if grep -q "SwiftUI" <<<"$(otool -L "$HOST_BIN")"; then
  echo "warning: LiveWallpaperSceneHost links SwiftUI; the host has no UI, keep it AppKit + Metal."
fi

# Sign the nested helpers first, then the outer app. No --deep: each bundle is signed on its own.
codesign --force --sign - "$HOST"
codesign --force --sign - "$AGENT"
codesign --force --sign - "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP (with $AGENT and $HOST)"
echo "Run it with: open $APP"
