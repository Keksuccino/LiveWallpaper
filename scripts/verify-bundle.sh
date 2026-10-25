#!/usr/bin/env bash
# Checks the layout of an assembled WallpaperMage.app: the settings app and its background service, executables,
# ids, matching versions, the compiled String Catalogs in both, the executables' minimum system version and SDK,
# ad-hoc signatures that verify, the linked scene renderer and no Homebrew load paths.
# Used by build.yml and release.yml.
#   scripts/verify-bundle.sh [path/to/WallpaperMage.app] [expected-version]
set -euo pipefail
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  trap 'echo "::error::verify-bundle.sh failed at line $LINENO: $BASH_COMMAND"' ERR
fi
APP="${1:-build/WallpaperMage.app}"
EXPECTED_VERSION="${2:-}"
SERVICE="$APP/Contents/Library/LoginItems/WallpaperMageService.app"

fail() { echo "::error::$*"; echo "error: $*" >&2; exit 1; }

test -x "$APP/Contents/MacOS/WallpaperMage" || fail "missing Settings executable"
test -x "$SERVICE/Contents/MacOS/WallpaperMageService" || fail "missing service executable"

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

[[ "$(plist "$APP" CFBundleIdentifier)" == "com.noob3301.WallpaperMage" ]] || fail "Settings bundle id"
[[ "$(plist "$SERVICE" CFBundleIdentifier)" == "com.noob3301.WallpaperMage.service" ]] || fail "service bundle id"
[[ "$(plist "$APP" WMRole)" == "settings" ]] || fail "Settings WMRole"
[[ "$(plist "$SERVICE" WMRole)" == "service" ]] || fail "service WMRole"
[[ -n "$(plist "$APP" NSAudioCaptureUsageDescription 2>/dev/null || true)" ]] || fail "Settings Info.plist is missing NSAudioCaptureUsageDescription"
[[ -n "$(plist "$SERVICE" NSAudioCaptureUsageDescription 2>/dev/null || true)" ]] || fail "service Info.plist is missing NSAudioCaptureUsageDescription"

# Both apps look their text up in their own bundle, in every language their Info.plist lists. Even the English tables
# hold what a key alone cannot give: the plural forms, the names of Wallpaper Engine's properties (looked up by their
# `ui_` keys) and the permission prompts.
for bundle in "$APP" "$SERVICE"; do
  languages="$(/usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" "$bundle/Contents/Info.plist" | sed -n 's/^ *//; /^[a-z][A-Za-z-]*$/p')"
  [[ -n "$languages" ]] || fail "$(basename "$bundle") lists no CFBundleLocalizations"
  for language in $languages; do
    for table in Localizable.strings Localizable.stringsdict InfoPlist.strings; do
      test -f "$bundle/Contents/Resources/$language.lproj/$table" || fail "$(basename "$bundle") has no $language.lproj/$table"
    done
  done
done

V_APP="$(plist "$APP" CFBundleShortVersionString)"
[[ "$(plist "$SERVICE" CFBundleShortVersionString)" == "$V_APP" ]] || fail "service version differs from the app"
if [[ -n "$EXPECTED_VERSION" && "$V_APP" != "$EXPECTED_VERSION" ]]; then
  fail "version is $V_APP, expected $EXPECTED_VERSION"
fi

# Every architecture of both executables is built for the plists' minimum system version, against an SDK of that
# macOS version (the SDK decides which AppKit and SwiftUI behaviours the app gets).
MIN_OS="$(plist "$APP" LSMinimumSystemVersion)"
[[ "$(plist "$SERVICE" LSMinimumSystemVersion)" == "$MIN_OS" ]] || fail "service LSMinimumSystemVersion differs from the app"
for bin in "$APP/Contents/MacOS/WallpaperMage" "$SERVICE/Contents/MacOS/WallpaperMageService"; do
  BUILDS="$(vtool -show-build "$bin" | awk '$1 == "minos" { minos = $2 } $1 == "sdk" { print minos, $2 }')"
  [[ -n "$BUILDS" ]] || fail "$(basename "$bin") has no build version"
  while read -r minos sdk; do
    [[ "$minos" == "$MIN_OS" ]] || fail "$(basename "$bin") is built for macOS $minos, Info.plist says $MIN_OS"
    [[ "${sdk%%.*}" == "${MIN_OS%%.*}" ]] || fail "$(basename "$bin") is built with the macOS $sdk SDK, not macOS ${MIN_OS%%.*}"
  done <<<"$BUILDS"
done
echo "--- built for macOS $MIN_OS ---"

codesign --verify --strict --deep "$APP" || fail "codesign verify (app)"
codesign --verify --strict "$SERVICE" || fail "codesign verify (service)"

# Anything loaded from Homebrew would only run on a Mac that happens to have it.
if otool -L "$SERVICE/Contents/MacOS/WallpaperMageService" | grep -Eq '/opt/homebrew|/usr/local/(opt|Cellar)'; then
  otool -L "$SERVICE/Contents/MacOS/WallpaperMageService" | grep -E '/opt/homebrew|/usr/local/(opt|Cellar)' >&2
  fail "the service still loads dylibs from Homebrew (not distributable)"
fi

# The scene renderer (SceneRenderer/) is a static library, so it leaves no dylib to check. Its UniFFI
# entry points are prefixed; release builds may strip the symbol table, so fall back to strings.
SERVICE_BIN="$SERVICE/Contents/MacOS/WallpaperMageService"
# grep -c reads to the end: with pipefail, grep -q would stop early and fail the pipe with SIGPIPE.
if ! nm "$SERVICE_BIN" 2>/dev/null | grep -c 'uniffi_scene_renderer' >/dev/null; then
  if ! strings -a "$SERVICE_BIN" | grep -c 'uniffi_scene_renderer' >/dev/null; then
    fail "the service does not contain SceneRenderer (no uniffi_scene_renderer symbols)"
  fi
fi
echo "--- SceneRenderer linked into the service ---"

echo "--- version $V_APP ---"
for bin in "$APP/Contents/MacOS/WallpaperMage" "$SERVICE/Contents/MacOS/WallpaperMageService"; do
  echo "$(basename "$bin"): $(lipo -archs "$bin")  $(du -h "$bin" | cut -f1)"
done
echo "--- libraries linked by the service ---"
otool -L "$SERVICE/Contents/MacOS/WallpaperMageService"
echo "bundle layout OK"
