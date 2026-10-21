#!/usr/bin/env bash
# Builds build/LiveWallpaper.app (the UI) with the background service nested inside it at
#   Contents/Library/LoginItems/LiveWallpaperService.app   (plays wallpapers, menu bar item, Unix socket server;
#                                                           launched by the UI, optionally an SMAppService login item)
# and signs everything ad hoc, inner bundles first. The old agent and scene host targets still compile but are
# no longer bundled.
#   CONFIG=debug ./build.sh      debug build (default: release)
#   UNIVERSAL=1 ./build.sh       arm64 + x86_64 binaries
#   VERSION=1.2.3 ./build.sh     writes the version into both Info.plists (digits and dots only; default: as in the plists)
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
SERVICE="$HELPERS/LiveWallpaperService.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# The expansion form keeps an empty array safe under `set -u` on macOS's bash 3.2.
# Only the two bundled products, so targets that are not bundled never break the bundle build.
for product in LiveWallpaper LiveWallpaperService; do
  swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product "$product"
done
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$SERVICE/Contents/MacOS" "$SERVICE/Contents/Resources"

cp "$BIN_DIR/LiveWallpaper" "$APP/Contents/MacOS/LiveWallpaper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp "$BIN_DIR/LiveWallpaperService" "$SERVICE/Contents/MacOS/LiveWallpaperService"
cp Resources/Service-Info.plist "$SERVICE/Contents/Info.plist"
printf 'APPL????' > "$SERVICE/Contents/PkgInfo"

# Version injection: the same version in both bundles (the UI can compare the running service's version with its own).
if [[ -n "${VERSION:-}" ]]; then
  for plist in "$APP/Contents/Info.plist" "$SERVICE/Contents/Info.plist"; do
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
    plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-$VERSION}" "$plist"
  done
fi

plutil -lint "$APP/Contents/Info.plist" "$SERVICE/Contents/Info.plist"

# Guards. Executable targets link their library targets statically, so a library is detected by the module name
# that Swift embeds in symbol names ("<length><name>", e.g. 11SceneEngine). The service may use Metal (scenes via
# RenderBridge), so only SwiftUI and the old Swift scene engine are checked.
SERVICE_BIN="$SERVICE/Contents/MacOS/LiveWallpaperService"
SERVICE_LIBS="$(otool -L "$SERVICE_BIN")"
echo "--- libraries linked by the service ---"
echo "$SERVICE_LIBS"
if grep -q "SwiftUI" <<<"$SERVICE_LIBS"; then
  echo "::error::LiveWallpaperService links SwiftUI; the service must stay AppKit only."
  exit 1
fi
if grep -Eq "11SceneEngine|11SceneFormat" <<<"$(strings -a "$SERVICE_BIN")"; then
  echo "::error::LiveWallpaperService contains SceneEngine or SceneFormat code; scenes go through RenderBridge."
  exit 1
fi
SETTINGS_BIN="$APP/Contents/MacOS/LiveWallpaper"
if grep -q "11SceneEngine" <<<"$(strings -a "$SETTINGS_BIN")"; then
  echo "::error::the Settings app contains SceneEngine code; it may use SceneFormat (parsing) but never the renderer."
  exit 1
fi

# Sign the nested helpers first, then the outer app. No --deep: each bundle is signed on its own.
codesign --force --sign - "$SERVICE"
codesign --force --sign - "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP (with $SERVICE)"
echo "Run it with: open $APP"
