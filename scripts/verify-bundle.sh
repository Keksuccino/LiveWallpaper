#!/usr/bin/env bash
# Checks the layout of an assembled LiveWallpaper.app: three bundles, executables, ids, matching versions, ad-hoc
# signatures that verify. Used by build.yml and release.yml.
#   scripts/verify-bundle.sh [path/to/LiveWallpaper.app] [expected-version]
set -euo pipefail
APP="${1:-build/LiveWallpaper.app}"
EXPECTED_VERSION="${2:-}"
AGENT="$APP/Contents/Library/LoginItems/LiveWallpaperAgent.app"
HOST="$APP/Contents/Library/LoginItems/LiveWallpaperSceneHost.app"

fail() { echo "error: $*" >&2; exit 1; }

test -x "$APP/Contents/MacOS/LiveWallpaper" || fail "missing Settings executable"
test -x "$AGENT/Contents/MacOS/LiveWallpaperAgent" || fail "missing agent executable"
test -x "$HOST/Contents/MacOS/LiveWallpaperSceneHost" || fail "missing scene host executable"

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

[[ "$(plist "$APP" CFBundleIdentifier)" == "com.noob3301.LiveWallpaper" ]] || fail "Settings bundle id"
[[ "$(plist "$AGENT" CFBundleIdentifier)" == "com.noob3301.LiveWallpaper.agent" ]] || fail "agent bundle id"
[[ "$(plist "$HOST" CFBundleIdentifier)" == "com.noob3301.LiveWallpaper.scenehost" ]] || fail "scene host bundle id"
[[ "$(plist "$APP" LWRole)" == "settings" ]] || fail "Settings LWRole"
[[ "$(plist "$AGENT" LWRole)" == "agent" ]] || fail "agent LWRole"
[[ "$(plist "$HOST" LWRole)" == "scenehost" ]] || fail "scene host LWRole"

V_APP="$(plist "$APP" CFBundleShortVersionString)"
[[ "$(plist "$AGENT" CFBundleShortVersionString)" == "$V_APP" ]] || fail "agent version differs from the app"
[[ "$(plist "$HOST" CFBundleShortVersionString)" == "$V_APP" ]] || fail "scene host version differs from the app"
if [[ -n "$EXPECTED_VERSION" && "$V_APP" != "$EXPECTED_VERSION" ]]; then
  fail "version is $V_APP, expected $EXPECTED_VERSION"
fi

codesign --verify --strict --deep "$APP" || fail "codesign verify (app)"
codesign --verify --strict "$AGENT" || fail "codesign verify (agent)"
codesign --verify --strict "$HOST" || fail "codesign verify (scene host)"

echo "--- version $V_APP ---"
for bin in "$APP/Contents/MacOS/LiveWallpaper" "$AGENT/Contents/MacOS/LiveWallpaperAgent" "$HOST/Contents/MacOS/LiveWallpaperSceneHost"; do
  echo "$(basename "$bin"): $(lipo -archs "$bin")  $(du -h "$bin" | cut -f1)"
done
echo "--- libraries linked by the agent (must not include SwiftUI or Metal) ---"
otool -L "$AGENT/Contents/MacOS/LiveWallpaperAgent"
echo "--- libraries linked by the scene host ---"
otool -L "$HOST/Contents/MacOS/LiveWallpaperSceneHost"
echo "bundle layout OK"
