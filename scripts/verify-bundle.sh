#!/usr/bin/env bash
# Checks the layout of an assembled LiveWallpaper.app: the settings app and its background service, executables,
# ids, matching versions, ad-hoc signatures that verify. Used by build.yml and release.yml.
#   scripts/verify-bundle.sh [path/to/LiveWallpaper.app] [expected-version]
set -euo pipefail
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  trap 'echo "::error::verify-bundle.sh failed at line $LINENO: $BASH_COMMAND"' ERR
fi
APP="${1:-build/LiveWallpaper.app}"
EXPECTED_VERSION="${2:-}"
SERVICE="$APP/Contents/Library/LoginItems/LiveWallpaperService.app"

fail() { echo "::error::$*"; echo "error: $*" >&2; exit 1; }

test -x "$APP/Contents/MacOS/LiveWallpaper" || fail "missing Settings executable"
test -x "$SERVICE/Contents/MacOS/LiveWallpaperService" || fail "missing service executable"

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

[[ "$(plist "$APP" CFBundleIdentifier)" == "com.noob3301.LiveWallpaper" ]] || fail "Settings bundle id"
[[ "$(plist "$SERVICE" CFBundleIdentifier)" == "com.noob3301.LiveWallpaper.service" ]] || fail "service bundle id"
[[ "$(plist "$APP" LWRole)" == "settings" ]] || fail "Settings LWRole"
[[ "$(plist "$SERVICE" LWRole)" == "service" ]] || fail "service LWRole"

V_APP="$(plist "$APP" CFBundleShortVersionString)"
[[ "$(plist "$SERVICE" CFBundleShortVersionString)" == "$V_APP" ]] || fail "service version differs from the app"
if [[ -n "$EXPECTED_VERSION" && "$V_APP" != "$EXPECTED_VERSION" ]]; then
  fail "version is $V_APP, expected $EXPECTED_VERSION"
fi

codesign --verify --strict --deep "$APP" || fail "codesign verify (app)"
codesign --verify --strict "$SERVICE" || fail "codesign verify (service)"

echo "--- version $V_APP ---"
for bin in "$APP/Contents/MacOS/LiveWallpaper" "$SERVICE/Contents/MacOS/LiveWallpaperService"; do
  echo "$(basename "$bin"): $(lipo -archs "$bin")  $(du -h "$bin" | cut -f1)"
done
echo "--- libraries linked by the service ---"
otool -L "$SERVICE/Contents/MacOS/LiveWallpaperService"
echo "bundle layout OK"
